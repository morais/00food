import { appleEmail, exchangeAppleCode, verifyAppleIdToken } from "./apple";
import {
  audience, base64url, constantTimeEqual, decodeBase64url, findOrCreateTenant,
  issueCredential, publicOrigin, randomToken, sha256Base64url, sha256Hex,
  type Scope,
} from "./auth";
import { appName, json, type Env } from "./api";

const scopes: Scope[] = ["food:read", "food:write", "daily:read", "daily:write"];
const flowLifetimeMs = 10 * 60000;
const codeLifetimeMs = 5 * 60000;

type Client = { name: string; redirects: string[]; issuedAt: number };
type Flow = {
  id_hash: string; client_id: string; client_name: string; redirect_uri: string;
  code_challenge: string; client_state: string | null; resource: string; scopes: string;
  apple_nonce: string; tenant_id: string | null; consent_hash: string | null;
  expires_at: string;
};
type Code = {
  code_hash: string; tenant_id: string; client_id: string; redirect_uri: string;
  code_challenge: string; resource: string; scopes: string; expires_at: string; redeemed_at: string | null;
};
type ReviewCredential = { tenant_id: string; expires_at: string; revoked_at: string | null };

function reviewTenantIds(env: Env): Set<string> {
  return new Set((env.REVIEW_TENANT_IDS ?? "").split(",").map((id) => id.trim()).filter(Boolean));
}

export async function reviewTenantForAccessCode(env: Env, accessCode: string): Promise<string | null> {
  const allowed = reviewTenantIds(env);
  if (!allowed.size || !/^fd_review_[A-Za-z0-9_-]{43}$/.test(accessCode)) return null;
  const credential = await env.DB.prepare(`SELECT tenant_id, expires_at, revoked_at
    FROM review_credentials WHERE token_hash = ?`)
    .bind(await sha256Hex(accessCode)).first<ReviewCredential>();
  return credential && !credential.revoked_at && credential.expires_at > new Date().toISOString()
    && allowed.has(credential.tenant_id) ? credential.tenant_id : null;
}

function configured(env: Env): boolean {
  return Boolean(env.OAUTH_SIGNING_SECRET && env.OAUTH_SIGNING_SECRET.length >= 32
    && env.APPLE_WEB_CLIENT_ID && env.APPLE_WEB_REDIRECT_URI && env.APPLE_PRIVATE_KEY);
}

function metadata(value: unknown): Response {
  return Response.json(value, { headers: { "content-type": "application/json; charset=utf-8", "cache-control": "public, max-age=300" } });
}

export function protectedResourceMetadata(env: Env): Response {
  const origin = publicOrigin(env);
  return metadata({
    resource: audience(env, "mcp"), authorization_servers: [origin],
    scopes_supported: scopes, bearer_methods_supported: ["header"], resource_name: appName(env),
  });
}

export function authorizationServerMetadata(env: Env): Response {
  const origin = publicOrigin(env);
  return metadata({
    issuer: origin,
    authorization_endpoint: `${origin}/oauth/authorize`,
    token_endpoint: `${origin}/oauth/token`,
    registration_endpoint: `${origin}/oauth/register`,
    response_types_supported: ["code"], grant_types_supported: ["authorization_code"],
    code_challenge_methods_supported: ["S256"], token_endpoint_auth_methods_supported: ["none"],
    scopes_supported: scopes, authorization_response_iss_parameter_supported: true,
  });
}

export function authChallenge(env: Env, status = 401, scope: Scope[] = scopes): Response {
  const origin = publicOrigin(env);
  const error = status === 403 ? ', error="insufficient_scope"' : '';
  return new Response(JSON.stringify({ error: status === 403 ? "insufficient_scope" : "Unauthorized" }), {
    status, headers: {
      "content-type": "application/json; charset=utf-8", "cache-control": "no-store",
      "WWW-Authenticate": `Bearer resource_metadata="${origin}/.well-known/oauth-protected-resource", scope="${scope.join(" ")}"${error}`,
    },
  });
}

function b64text(value: string): string {
  return new TextDecoder().decode(decodeBase64url(value));
}

async function clientSignature(env: Env, body: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(env.OAUTH_SIGNING_SECRET!),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return base64url(new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`client:${body}`))));
}

function allowedRedirect(raw: string): boolean {
  if (raw.length > 512) return false;
  try {
    const url = new URL(raw);
    if (url.hash || url.username || url.password) return false;
    if (url.protocol === "https:") return true;
    return url.protocol === "http:" && ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
  } catch { return false; }
}

async function verifyClient(env: Env, id: string): Promise<Client | null> {
  if (!configured(env) || id.length > 4096 || !id.startsWith("fdc_")) return null;
  const [body, signature] = id.slice(4).split(".");
  if (!body || !signature || !constantTimeEqual(signature, await clientSignature(env, body))) return null;
  try {
    const client = JSON.parse(b64text(body)) as Client;
    if (!client || typeof client.name !== "string" || client.name.length > 120
      || !Array.isArray(client.redirects) || client.redirects.length < 1 || client.redirects.length > 5
      || !client.redirects.every((uri) => typeof uri === "string" && allowedRedirect(uri))) return null;
    return client;
  } catch { return null; }
}

async function textBody(req: Request, limit = 8192): Promise<string> {
  if (Number(req.headers.get("content-length") ?? 0) > limit) throw new Error("Request too large");
  const text = await req.text();
  if (text.length > limit) throw new Error("Request too large");
  return text;
}

export async function registerClient(req: Request, env: Env): Promise<Response> {
  if (!configured(env)) return json({ error: "MCP sign-in is not configured" }, 503);
  let body: Record<string, unknown>;
  try { body = JSON.parse(await textBody(req)) as Record<string, unknown>; }
  catch { return json({ error: "invalid_client_metadata" }, 400); }
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return json({ error: "invalid_client_metadata" }, 400);
  }
  const redirectUris = body.redirect_uris;
  if (!Array.isArray(redirectUris) || redirectUris.length < 1 || redirectUris.length > 5
    || !redirectUris.every((uri) => typeof uri === "string" && allowedRedirect(uri))) {
    return json({ error: "invalid_redirect_uri", error_description: "Register 1–5 HTTPS or loopback redirect URIs" }, 400);
  }
  // RFC 7591 makes client_name optional and permits an authorization server to
  // replace requested metadata with values it supports. MCP clients commonly
  // request refresh_token even though this server only issues access tokens.
  const suppliedName = typeof body.client_name === "string" ? body.client_name.trim() : "";
  const name = suppliedName ? suppliedName.slice(0, 120) : "MCP client";
  const client: Client = { name: name.trim(), redirects: redirectUris, issuedAt: Math.floor(Date.now() / 1000) };
  const encoded = base64url(new TextEncoder().encode(JSON.stringify(client)));
  const clientId = `fdc_${encoded}.${await clientSignature(env, encoded)}`;
  return json({
    client_id: clientId, client_id_issued_at: client.issuedAt, client_name: client.name,
    redirect_uris: client.redirects, grant_types: ["authorization_code"], response_types: ["code"],
    token_endpoint_auth_method: "none", scope: scopes.join(" "),
  }, 201);
}

/// Returns the server-owned display name for an exact, verified HTTPS
/// callback. Dynamic registration metadata is self-asserted; neither
/// `client_name` nor a lookalike or prefix URL can earn this result.
///
/// Invalid configuration fails closed to "unverified" so a typo can never
/// confer trust. The registry is read at consent and token exchange rather
/// than baked into the signed client id, so removing an entry takes effect
/// immediately.
export function verifiedClientName(env: Env, redirectUri: string): string | undefined {
  const raw = env.MCP_VERIFIED_CLIENTS?.trim();
  if (!raw) return undefined;
  let registry: unknown;
  try { registry = JSON.parse(raw); } catch { return undefined; }
  if (!registry || typeof registry !== "object" || Array.isArray(registry)) return undefined;
  let redirect: URL;
  try { redirect = new URL(redirectUri); } catch { return undefined; }
  if (redirect.protocol !== "https:" || redirect.hash || redirect.username || redirect.password) return undefined;
  const name = (registry as Record<string, unknown>)[redirectUri];
  if (typeof name !== "string") return undefined;
  const canonical = name.trim();
  return canonical ? canonical.slice(0, 120) : undefined;
}

function requestedScopes(raw: string | null): Scope[] | null {
  if (!raw) return [...scopes];
  const values = [...new Set(raw.split(/\s+/).filter(Boolean))];
  return values.length && values.every((value) => scopes.includes(value as Scope)) ? values as Scope[] : null;
}

function htmlEscape(value: string): string {
  return value.replace(/[&<>"']/g, (character) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  })[character]!);
}

function html(env: Env, body: string, status = 200): Response {
  return new Response(`<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>${htmlEscape(appName(env))} · Connect</title><style>
    :root{color-scheme:light dark;--bg:#f8fbff;--fg:#06152a;--muted:#56657a;--line:#e2e7ee;--card:#fff;--detail:#eef2f7}
    @media(prefers-color-scheme:dark){:root{--bg:#06152a;--fg:#f8fbff;--muted:#98a8c0;--line:#1a2b48;--card:#0b1e38;--detail:#0c2340}}
    *{box-sizing:border-box}body{font:16px -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;background:var(--bg);color:var(--fg);max-width:620px;margin:0 auto;padding:24px;line-height:1.5}
    header{font-size:22px;font-weight:800;border-bottom:1px solid var(--line);padding-bottom:16px;margin-bottom:32px}
    main{border:1px solid var(--line);border-radius:18px;padding:28px;background:var(--card)}h1{font-size:23px;margin:0 0 12px}p{margin:12px 0;color:var(--muted)}
    button{font:inherit;font-weight:600;padding:10px 18px;margin:12px 8px 0 0;border:0;border-radius:6px;cursor:pointer;background:#0968e8;color:#fff}
    .apple-button{display:block;width:100%;margin:16px 0 0;background:var(--fg);color:var(--bg);text-align:center}
    details{margin-top:24px;color:var(--muted)}details summary{cursor:pointer}details input{font:inherit;padding:10px;border:1px solid var(--line);border-radius:6px;background:var(--bg);color:var(--fg);max-width:100%}
    code{overflow-wrap:anywhere}.status{display:inline-block;font-size:13px;font-weight:600;padding:2px 10px;border-radius:999px;margin-right:6px}.good{background:#dff5e6;color:#14532d}.warning{background:#fdecc8;color:#7a4b00}
    .detail{display:flex;flex-direction:column;gap:4px;padding:12px 14px;border-radius:12px;background:var(--detail)}.detail span{font-size:13px;color:var(--muted)}.detail code{font-size:15px;font-weight:600}
  </style><header>${htmlEscape(appName(env))}</header><main>${body}</main></html>`, {
    status, headers: {
      "content-type": "text/html; charset=utf-8", "cache-control": "no-store",
      "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self' https: http://localhost:* http://127.0.0.1:*; base-uri 'none'; frame-ancestors 'none'",
      "referrer-policy": "same-origin", "x-content-type-options": "nosniff",
    },
  });
}

function redirect(uri: string, params: Record<string, string | null>): Response {
  const url = new URL(uri);
  for (const [key, value] of Object.entries(params)) if (value !== null) url.searchParams.set(key, value);
  return new Response(null, { status: 303, headers: { Location: url.toString(), "cache-control": "no-store" } });
}

async function loadFlow(env: Env, flowId: string): Promise<Flow | null> {
  if (!/^[A-Za-z0-9_-]{32,64}$/.test(flowId)) return null;
  const flow = await env.DB.prepare("SELECT * FROM oauth_flows WHERE id_hash = ?")
    .bind(await sha256Hex(flowId)).first<Flow>();
  return flow && flow.expires_at > new Date().toISOString() ? flow : null;
}

export async function beginAuthorization(req: Request, env: Env): Promise<Response> {
  if (!configured(env)) return html(env, "<h1>Apple sign-in is not configured</h1>", 503);
  const url = new URL(req.url);
  const q = url.searchParams;
  const clientId = q.get("client_id") ?? "";
  const client = await verifyClient(env, clientId);
  const redirectUri = q.get("redirect_uri") ?? "";
  const challenge = q.get("code_challenge") ?? "";
  const requested = requestedScopes(q.get("scope"));
  if (!client || q.get("response_type") !== "code" || !client.redirects.includes(redirectUri)
    || q.get("code_challenge_method") !== "S256" || !/^[A-Za-z0-9_-]{43}$/.test(challenge)
    || !requested || q.get("resource") !== audience(env, "mcp")) {
    return html(env, "<h1>Invalid authorization request</h1><p>Check client registration, PKCE, scopes, and resource.</p>", 400);
  }
  const flowId = randomToken(24);
  const nonce = randomToken(24);
  const now = new Date();
  await env.DB.prepare(`INSERT INTO oauth_flows
    (id_hash, client_id, client_name, redirect_uri, code_challenge, client_state,
     resource, scopes, apple_nonce, created_at, expires_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`).bind(
    await sha256Hex(flowId), clientId, client.name, redirectUri, challenge,
    // OAuth state is opaque client data: changing even one byte makes the
    // client reject the callback before it can reach our token endpoint.
    q.get("state"), audience(env, "mcp"), requested.join(" "),
    nonce, now.toISOString(), new Date(now.getTime() + flowLifetimeMs).toISOString(),
  ).run();
  if (reviewTenantIds(env).size) {
    return html(env, `<h1>Sign in</h1>
      <p>Choose the account you use with ${htmlEscape(appName(env))} to connect ${htmlEscape(client.name)}.</p>
      <form method="get" action="/oauth/login">
        <input type="hidden" name="flow" value="${htmlEscape(flowId)}">
        <button class="apple-button">Sign in with Apple</button>
      </form>
      <details><summary>Reviewer access</summary>
        <p>For the dedicated review account only. Enter the access code supplied in the secure reviewer instructions.</p>
        <form method="post" action="/auth/review/callback">
          <input type="hidden" name="flow" value="${htmlEscape(flowId)}">
          <label for="access-code">Review access code</label><br>
          <input id="access-code" name="accessCode" type="password" autocomplete="off" required maxlength="128">
          <button>Continue as reviewer</button>
        </form>
      </details>`);
  }
  return appleAuthorize(env, flowId, nonce);
}

export function appleAuthorize(env: Env, flowId: string, nonce: string): Response {
  const apple = new URL("https://appleid.apple.com/auth/authorize");
  apple.search = new URLSearchParams({
    client_id: env.APPLE_WEB_CLIENT_ID!, redirect_uri: env.APPLE_WEB_REDIRECT_URI!,
    response_type: "code id_token", response_mode: "form_post", scope: "name email",
    state: flowId, nonce,
  }).toString();
  return new Response(null, { status: 302, headers: { Location: apple.toString(), "cache-control": "no-store" } });
}

export async function showReviewLogin(req: Request, env: Env): Promise<Response> {
  if (!reviewTenantIds(env).size) return html(env, "<h1>Not found</h1>", 404);
  const flowId = new URL(req.url).searchParams.get("flow") ?? "";
  const flow = await loadFlow(env, flowId);
  if (!flow || flow.tenant_id) return html(env, "<h1>Sign-in session expired</h1><p>Start the connection again.</p>", 400);
  return appleAuthorize(env, flowId, flow.apple_nonce);
}

export async function reviewCallback(req: Request, env: Env): Promise<Response> {
  const allowed = reviewTenantIds(env);
  if (!allowed.size) return html(env, "<h1>Not found</h1>", 404);
  if (req.headers.get("origin") !== publicOrigin(env)) return html(env, "<h1>Invalid request origin</h1>", 403);
  let form: URLSearchParams;
  try { form = new URLSearchParams(await textBody(req, 1024)); }
  catch { return html(env, "<h1>Invalid review sign-in</h1>", 400); }
  const flowId = form.get("flow") ?? "";
  const flow = await loadFlow(env, flowId);
  const accessCode = form.get("accessCode") ?? "";
  if (!flow || flow.tenant_id || !/^fd_review_[A-Za-z0-9_-]{43}$/.test(accessCode)) {
    return html(env, "<h1>Invalid or expired review access</h1>", 401);
  }
  const tenantId = await reviewTenantForAccessCode(env, accessCode);
  if (!tenantId) {
    return html(env, "<h1>Invalid or expired review access</h1>", 401);
  }
  const consentSecret = randomToken(24);
  const result = await env.DB.prepare(`UPDATE oauth_flows SET tenant_id = ?, consent_hash = ?
    WHERE id_hash = ? AND tenant_id IS NULL AND expires_at > ?`)
    .bind(tenantId, await sha256Hex(consentSecret), flow.id_hash, new Date().toISOString()).run();
  if (result.meta.changes !== 1) return html(env, "<h1>Sign-in was already used</h1>", 400);
  return consentRedirect(env, flowId, consentSecret);
}

function consentRedirect(env: Env, flowId: string, secret: string): Response {
  return new Response(null, { status: 303, headers: {
    Location: `${publicOrigin(env)}/oauth/consent?flow=${encodeURIComponent(flowId)}`,
    "set-cookie": `fd_consent=${flowId}.${secret}; Path=/oauth; Max-Age=600; HttpOnly; Secure; SameSite=Lax`,
    "cache-control": "no-store",
  } });
}

export async function appleCallback(req: Request, env: Env): Promise<Response> {
  if (!configured(env)) return html(env, "<h1>Apple sign-in is not configured</h1>", 503);
  let form: URLSearchParams;
  try { form = new URLSearchParams(await textBody(req, 16000)); }
  catch { return html(env, "<h1>Invalid Apple response</h1>", 400); }
  const flowId = form.get("state") ?? "";
  const flow = await loadFlow(env, flowId);
  if (!flow || flow.tenant_id) return html(env, "<h1>Sign-in session expired</h1><p>Start the connection again.</p>", 400);
  if (form.get("error")) return redirect(flow.redirect_uri, {
    error: "access_denied", state: flow.client_state, iss: publicOrigin(env),
  });
  const identityToken = form.get("id_token") ?? "";
  const code = form.get("code") ?? "";
  if (!identityToken || !code) return html(env, "<h1>Apple response was incomplete</h1>", 400);
  try {
    const claims = await verifyAppleIdToken(identityToken, env.APPLE_WEB_CLIENT_ID!, flow.apple_nonce);
    const exchanged = await exchangeAppleCode(env, code, env.APPLE_WEB_CLIENT_ID!, env.APPLE_WEB_REDIRECT_URI!);
    const exchangedClaims = await verifyAppleIdToken(exchanged.idToken, env.APPLE_WEB_CLIENT_ID!, flow.apple_nonce);
    if (!constantTimeEqual(claims.sub, exchangedClaims.sub)) throw new Error("Apple account changed");
    const tenant = await findOrCreateTenant(env, claims.sub, appleEmail(exchangedClaims));
    const consentSecret = randomToken(24);
    const result = await env.DB.prepare(`UPDATE oauth_flows SET tenant_id = ?, consent_hash = ?
      WHERE id_hash = ? AND tenant_id IS NULL`).bind(tenant.id, await sha256Hex(consentSecret), flow.id_hash).run();
    if (result.meta.changes !== 1) return html(env, "<h1>Sign-in was already used</h1>", 400);
    return consentRedirect(env, flowId, consentSecret);
  } catch (cause) {
    console.warn("Apple web sign-in failed", cause instanceof Error ? cause.message : "unknown error");
    return html(env, "<h1>Could not verify Apple sign-in</h1><p>Start the connection again.</p>", 401);
  }
}

function consentCookie(req: Request, flowId: string): string | null {
  const value = req.headers.get("cookie")?.split(";").map((part) => part.trim())
    .find((part) => part.startsWith("fd_consent="))?.slice("fd_consent=".length);
  if (!value || !value.startsWith(`${flowId}.`)) return null;
  return value.slice(flowId.length + 1);
}

async function authorizedConsent(req: Request, env: Env, flowId: string): Promise<{ flow: Flow; secret: string } | null> {
  const flow = await loadFlow(env, flowId);
  const secret = consentCookie(req, flowId);
  if (!flow || !flow.tenant_id || !flow.consent_hash || !secret ||
    !constantTimeEqual(await sha256Hex(secret), flow.consent_hash)) return null;
  return { flow, secret };
}

export async function showConsent(req: Request, env: Env): Promise<Response> {
  const flowId = new URL(req.url).searchParams.get("flow") ?? "";
  const authorized = await authorizedConsent(req, env, flowId);
  if (!authorized) return html(env, "<h1>Connection expired</h1><p>Start again in your MCP client.</p>", 401);
  const { flow, secret } = authorized;
  const verifiedName = verifiedClientName(env, flow.redirect_uri);
  // A self-asserted name never appears as the subject of the heading, so a
  // client registered as "ChatGPT" cannot borrow that name's trust.
  const heading = verifiedName
    ? `Connect ${htmlEscape(verifiedName)} to ${htmlEscape(appName(env))}?`
    : `Connect an unverified app to ${htmlEscape(appName(env))}?`;
  const trust = verifiedName
    ? `<p><span class="status good">Recognized callback</span> ${htmlEscape(appName(env))} recognizes this exact ${htmlEscape(verifiedName)} callback address.</p>`
    : `<p><span class="status warning">Unverified client</span> It calls itself “${htmlEscape(flow.client_name)}”, but ${htmlEscape(appName(env))} cannot confirm that. Approve only if you started this connection and recognize the site below.</p>
    <p class="detail"><span>Sends your access to</span><code>${htmlEscape(new URL(flow.redirect_uri).host)}</code></p>`;
  return html(env, `<h1>${heading}</h1>
    ${trust}
    <p class="detail">Requested permissions: <code>${htmlEscape(flow.scopes)}</code></p>
    <p>${flow.scopes.includes("food:read")
      ? `This client can read your saved foods, pending descriptions, and submitted food photos${flow.scopes.includes("food:write") ? ", and propose calorie estimates" : ""}. You review each food proposal before it is saved or logged.`
      : "This request does not grant access to saved foods or pending food photos."}</p>
    <p>${flow.scopes.includes("daily:read")
      ? "If you enable automatic Daily feedback or request missing days manually in the app, this client can read seven-day summaries of your food logs and Apple Health water, active and resting calories, weight, and body fat. These summaries are saved to your 00Food account."
      : "Apple Health data is not shared with this client."}
      ${flow.scopes.includes("daily:write") ? "This client can also write daily feedback for you to read in 00Food." : ""}</p>
    <p class="detail"><span>Redirects to</span><code>${htmlEscape(flow.redirect_uri)}</code></p>
    <form method="post" action="/oauth/consent">
      <input type="hidden" name="flow" value="${htmlEscape(flowId)}">
      <input type="hidden" name="csrf" value="${htmlEscape(secret)}">
      <button name="decision" value="deny">Deny</button>
      <button name="decision" value="approve">Approve</button>
    </form>`);
}

export async function decideConsent(req: Request, env: Env): Promise<Response> {
  let form: URLSearchParams;
  try { form = new URLSearchParams(await textBody(req)); }
  catch { return html(env, "<h1>Invalid consent response</h1>", 400); }
  const flowId = form.get("flow") ?? "";
  const authorized = await authorizedConsent(req, env, flowId);
  if (!authorized || !constantTimeEqual(form.get("csrf") ?? "", authorized.secret)) {
    return html(env, "<h1>Connection expired</h1><p>Start again in your MCP client.</p>", 401);
  }
  const { flow } = authorized;
  const removed = await env.DB.prepare("DELETE FROM oauth_flows WHERE id_hash = ? AND consent_hash = ?")
    .bind(flow.id_hash, flow.consent_hash).run();
  if (removed.meta.changes !== 1) return html(env, "<h1>Connection was already decided</h1>", 400);
  if (form.get("decision") !== "approve") return redirect(flow.redirect_uri, {
    error: "access_denied", state: flow.client_state, iss: publicOrigin(env),
  });
  const code = randomToken(32);
  await env.DB.prepare(`INSERT INTO oauth_codes
    (code_hash, tenant_id, client_id, redirect_uri, code_challenge, resource, scopes, expires_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)`).bind(
    await sha256Hex(code), flow.tenant_id, flow.client_id, flow.redirect_uri,
    flow.code_challenge, flow.resource, flow.scopes,
    new Date(Date.now() + codeLifetimeMs).toISOString(),
  ).run();
  return redirect(flow.redirect_uri, { code, state: flow.client_state, iss: publicOrigin(env) });
}

function oauthError(error: string, description: string): Response {
  return Response.json({ error, error_description: description }, {
    status: error === "invalid_client" ? 401 : 400,
    headers: { "cache-control": "no-store", pragma: "no-cache" },
  });
}

export async function exchangeCode(req: Request, env: Env): Promise<Response> {
  if (!configured(env)) return oauthError("server_error", "MCP sign-in is not configured");
  let form: URLSearchParams;
  try { form = new URLSearchParams(await textBody(req)); }
  catch { return oauthError("invalid_request", "Malformed form body"); }
  if (form.get("grant_type") !== "authorization_code") return oauthError("unsupported_grant_type", "Use authorization_code");
  const clientId = form.get("client_id") ?? "";
  const client = await verifyClient(env, clientId);
  if (!client) return oauthError("invalid_client", "Unknown client");
  const rawCode = form.get("code") ?? "";
  const verifier = form.get("code_verifier") ?? "";
  const redirectUri = form.get("redirect_uri") ?? "";
  const resource = form.get("resource") ?? "";
  if (!/^[A-Za-z0-9_-]{43,128}$/.test(verifier) || !/^[A-Za-z0-9_-]{43}$/.test(rawCode)
    || resource !== audience(env, "mcp")) return oauthError("invalid_request", "Invalid code, verifier, or resource");
  const hash = await sha256Hex(rawCode);
  const code = await env.DB.prepare("SELECT * FROM oauth_codes WHERE code_hash = ?").bind(hash).first<Code>();
  if (!code || code.redeemed_at || code.expires_at <= new Date().toISOString()
    || !constantTimeEqual(code.client_id, clientId) || code.redirect_uri !== redirectUri
    || code.resource !== resource || !constantTimeEqual(code.code_challenge, await sha256Base64url(verifier))) {
    return oauthError("invalid_grant", "Authorization code is invalid or expired");
  }
  const claimed = await env.DB.prepare(`UPDATE oauth_codes SET redeemed_at = ?
    WHERE code_hash = ? AND redeemed_at IS NULL AND expires_at > ?`).bind(
    new Date().toISOString(), hash, new Date().toISOString(),
  ).run();
  if (claimed.meta.changes !== 1) return oauthError("invalid_grant", "Authorization code already used");
  const granted = code.scopes.split(" ").filter((scope): scope is Scope => scopes.includes(scope as Scope));
  // A verified callback gets the server-owned name; the self-asserted
  // registration name is used only for unverified clients.
  const label = verifiedClientName(env, code.redirect_uri) ?? client.name;
  const credential = await issueCredential(env, code.tenant_id, "mcp", `MCP · ${label}`, granted);
  return Response.json({
    access_token: credential.token, token_type: "Bearer",
    expires_in: Math.max(1, Math.floor((Date.parse(credential.expiresAt) - Date.now()) / 1000)),
    scope: granted.join(" "),
  }, { headers: { "cache-control": "no-store", pragma: "no-cache" } });
}
