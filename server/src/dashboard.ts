import { appleEmail, exchangeAppleCode, verifyAppleIdToken } from "./apple";
import { appName, type Env } from "./api";
import { base64url, constantTimeEqual, decodeBase64url, findOrCreateTenant, publicOrigin, randomToken, sha256Hex } from "./auth";
import { appleAuthorize, reviewTenantForAccessCode } from "./oauth";
import { tenantAllowed, tooManyRequests } from "./rateLimit";

const flowCookieName = "fd_dashboard_flow";
const sessionCookieName = "fd_dashboard_session";
const flowLifetimeSeconds = 600;
const sessionLifetimeSeconds = 86400;

type LoginFlow = { state: string; nonce: string; exp: number };
type Session = {
  kind: "apple" | "review"; tenantId: string; exp: number;
  appleSubject?: string; reviewCodeHash?: string;
};
function configured(env: Env): boolean {
  return Boolean(env.OAUTH_SIGNING_SECRET && env.OAUTH_SIGNING_SECRET.length >= 32);
}

function appleConfigured(env: Env): boolean {
  return configured(env) && Boolean(env.APPLE_WEB_CLIENT_ID && env.APPLE_WEB_REDIRECT_URI && env.APPLE_PRIVATE_KEY);
}

function reviewConfigured(env: Env): boolean {
  return configured(env) && Boolean(env.REVIEW_TENANT_IDS?.trim());
}

const escapeHtml = (value: unknown): string => String(value ?? "").replace(/[&<>"']/g,
  c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);

function page(env: Env, body: string, status = 200): Response {
  return new Response(`<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${escapeHtml(appName(env))} · Dashboard</title><style>
    :root{color-scheme:light dark;--bg:#fbf8f6;--fg:#242220;--card:#fff;--line:#e5ded8;--muted:#71665e;--accent:#994719}
    @media(prefers-color-scheme:dark){:root{--bg:#211b17;--fg:#fff8f1;--card:#2c241e;--line:#574336;--muted:#d4baa7;--accent:#ffb67c}}
    *{box-sizing:border-box}body{font:16px system-ui,sans-serif;line-height:1.5;max-width:900px;margin:auto;padding:24px;background:var(--bg);color:var(--fg)}
    header{font-size:24px;font-weight:750;margin-bottom:24px}main,article{border:1px solid var(--line);border-radius:16px;padding:24px;background:var(--card)}article{margin:12px 0;padding:16px}
    h1{font-size:24px}h2{font-size:21px;margin-top:32px}h3{font-size:18px;margin:0}p{margin:8px 0}small,.muted{color:var(--muted)}.text{white-space:pre-wrap;overflow-wrap:anywhere}code{overflow-wrap:anywhere}
    a{color:var(--accent)}.apple-button{display:block;max-width:580px;text-align:center;padding:10px 18px;border-radius:8px;background:var(--fg);color:var(--bg);font-weight:600;text-decoration:none}details{margin-top:24px}summary{cursor:pointer}input,button{font:inherit;padding:10px;border-radius:8px}input{width:100%;max-width:580px;border:1px solid var(--line);background:var(--bg);color:var(--fg)}button{margin-top:12px;border:1px solid var(--accent);background:var(--bg);color:var(--accent);cursor:pointer}
    table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:8px;border-bottom:1px solid var(--line)}.table{overflow-x:auto}
  </style><header>${escapeHtml(appName(env))}</header><main>${body}</main></html>`, { status, headers: {
    "content-type": "text/html; charset=utf-8", "cache-control": "no-store",
    "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
    // Form POSTs need their real Origin for the strict checks below. The
    // same-origin policy retains it without sending referrers to other sites.
    "referrer-policy": "same-origin", "x-content-type-options": "nosniff",
  } });
}
function redirect(env: Env, path: string): Response {
  return new Response(null, { status: 303, headers: { location: `${publicOrigin(env)}${path}`, "cache-control": "no-store" } });
}
function cookie(req: Request, name: string): string | null {
  return req.headers.get("cookie")?.split(";").map((part) => part.trim())
    .find((part) => part.startsWith(`${name}=`))?.slice(name.length + 1) ?? null;
}

async function hmac(env: Env, purpose: string, value: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(env.OAUTH_SIGNING_SECRET!),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return base64url(new Uint8Array(await crypto.subtle.sign("HMAC", key,
    new TextEncoder().encode(`dashboard:${purpose}:${value}`))));
}

async function signed<T>(env: Env, purpose: string, value: T): Promise<string> {
  const payload = base64url(new TextEncoder().encode(JSON.stringify(value)));
  return `${payload}.${await hmac(env, purpose, payload)}`;
}

async function verified<T>(env: Env, purpose: string, raw: string | null): Promise<T | null> {
  if (!configured(env) || !raw || raw.length > 2048) return null;
  const [payload, signature, extra] = raw.split(".");
  if (!payload || !signature || extra || !constantTimeEqual(signature, await hmac(env, purpose, payload))) return null;
  try { return JSON.parse(new TextDecoder().decode(decodeBase64url(payload))) as T; }
  catch { return null; }
}

function flowCookie(value: string): string {
  return `${flowCookieName}=${value}; Path=/auth/apple/callback; Max-Age=${flowLifetimeSeconds}; HttpOnly; Secure; SameSite=None`;
}

function clearFlowCookie(): string {
  return `${flowCookieName}=; Path=/auth/apple/callback; Max-Age=0; HttpOnly; Secure; SameSite=None`;
}

function sessionCookie(value: string): string {
  return `${sessionCookieName}=${value}; Path=/dashboard; Max-Age=${sessionLifetimeSeconds}; HttpOnly; Secure; SameSite=Lax`;
}

function clearSessionCookie(): string {
  return `${sessionCookieName}=; Path=/dashboard; Max-Age=0; HttpOnly; Secure; SameSite=Lax`;
}

async function currentSession(req: Request, env: Env): Promise<Session | null> {
  const session = await verified<Session>(env, "session", cookie(req, sessionCookieName));
  if (!session || !Number.isFinite(session.exp) || session.exp <= Date.now() / 1000
    || !/^[a-f0-9-]{36}$/.test(session.tenantId)) return null;
  if (session.kind === "apple" && typeof session.appleSubject === "string") {
    const tenant = await env.DB.prepare("SELECT id FROM tenants WHERE id = ? AND apple_subject = ?")
      .bind(session.tenantId, session.appleSubject).first();
    return tenant ? session : null;
  }
  if (session.kind === "review" && /^[a-f0-9]{64}$/.test(session.reviewCodeHash ?? "")) {
    const allowed = new Set((env.REVIEW_TENANT_IDS ?? "").split(",").map((id) => id.trim()));
    if (!allowed.has(session.tenantId)) return null;
    const credential = await env.DB.prepare(`SELECT tenant_id FROM review_credentials
      WHERE token_hash = ? AND tenant_id = ? AND revoked_at IS NULL AND expires_at > ?`)
      .bind(session.reviewCodeHash, session.tenantId, new Date().toISOString()).first();
    return credential ? session : null;
  }
  return null;
}

export async function dashboardLogin(req: Request, env: Env): Promise<Response> {
  if (await currentSession(req, env)) return redirect(env, "/dashboard");
  if (!appleConfigured(env) && !reviewConfigured(env)) return page(env, "<h1>Sign-in is not configured</h1>", 503);
  return page(env, `<h1>Sign in</h1><p>Use your ${escapeHtml(appName(env))} account to view your foods, food logs, estimate requests, and daily reflections.</p>
    ${appleConfigured(env) ? '<a class="apple-button" href="/dashboard/login/apple">Sign in with Apple</a>' : ""}
    ${reviewConfigured(env) ? `<details><summary>Reviewer access</summary><p>Use the access code supplied in the secure reviewer instructions.</p>
      <form method="post" action="/dashboard/login/review"><label for="access-code">Review access code</label>
      <input id="access-code" name="accessCode" type="password" autocomplete="off" required maxlength="128">
      <button>Sign in as reviewer</button></form></details>` : ""}`);
}

export async function dashboardAppleLogin(env: Env): Promise<Response> {
  if (!appleConfigured(env)) return page(env, "<h1>Apple sign-in is not configured</h1>", 503);
  const flow: LoginFlow = {
    state: `fddash_${randomToken(24)}`, nonce: randomToken(24),
    exp: Math.floor(Date.now() / 1000) + flowLifetimeSeconds,
  };
  const response = appleAuthorize(env, flow.state, flow.nonce);
  response.headers.set("set-cookie", flowCookie(await signed(env, "flow", flow)));
  return response;
}

export function isDashboardAppleState(state: string | null): boolean {
  return Boolean(state && /^fddash_[A-Za-z0-9_-]{32}$/.test(state));
}

export async function dashboardAppleCallback(req: Request, env: Env, form: URLSearchParams, ctx?: ExecutionContext): Promise<Response> {
  const flow = await verified<LoginFlow>(env, "flow", cookie(req, flowCookieName));
  const invalid = () => {
    const response = page(env, '<h1>Sign-in expired</h1><p>Please start again from <a href="/dashboard/login">the login page</a>.</p>', 401);
    response.headers.set("set-cookie", clearFlowCookie());
    return response;
  };
  if (!flow || !isDashboardAppleState(flow.state) || !Number.isFinite(flow.exp)
    || flow.exp <= Date.now() / 1000 || !constantTimeEqual(flow.state, form.get("state") ?? "")
    || !/^[A-Za-z0-9_-]{32}$/.test(flow.nonce)) return invalid();
  if (form.get("error")) return invalid();
  try {
    const identityToken = form.get("id_token") ?? "";
    const code = form.get("code") ?? "";
    const claims = await verifyAppleIdToken(identityToken, env.APPLE_WEB_CLIENT_ID!, flow.nonce);
    const exchanged = await exchangeAppleCode(env, code, env.APPLE_WEB_CLIENT_ID!, env.APPLE_WEB_REDIRECT_URI!);
    const verifiedClaims = await verifyAppleIdToken(exchanged.idToken, env.APPLE_WEB_CLIENT_ID!, flow.nonce);
    if (!constantTimeEqual(claims.sub, verifiedClaims.sub)) throw new Error("Apple account changed");
    const tenant = await findOrCreateTenant(env, claims.sub, appleEmail(verifiedClaims), { source: "dashboard", ctx });
    const session: Session = {
      kind: "apple", tenantId: tenant.id, appleSubject: claims.sub,
      exp: Math.floor(Date.now() / 1000) + sessionLifetimeSeconds,
    };
    const response = redirect(env, "/dashboard");
    response.headers.append("set-cookie", clearFlowCookie());
    response.headers.append("set-cookie", sessionCookie(await signed(env, "session", session)));
    return response;
  } catch (cause) {
    console.warn("Dashboard Apple sign-in failed", cause instanceof Error ? cause.message : "unknown error");
    return invalid();
  }
}

export async function dashboardReviewLogin(req: Request, env: Env): Promise<Response> {
  if (!reviewConfigured(env)) return page(env, "<h1>Not found</h1>", 404);
  if (req.headers.get("origin") !== publicOrigin(env)) return page(env, "<h1>Invalid request origin</h1>", 403);
  if (Number(req.headers.get("content-length") ?? 0) > 1024) return page(env, "<h1>Invalid request</h1>", 400);
  const raw = await req.text();
  if (raw.length > 1024) return page(env, "<h1>Invalid request</h1>", 400);
  const code = new URLSearchParams(raw).get("accessCode") ?? "";
  const tenantId = await reviewTenantForAccessCode(env, code);
  if (!tenantId) return page(env, '<h1>Invalid or expired reviewer code</h1><p><a href="/dashboard/login">Try again</a>.</p>', 401);
  const session: Session = {
    kind: "review", tenantId, reviewCodeHash: await sha256Hex(code),
    exp: Math.floor(Date.now() / 1000) + sessionLifetimeSeconds,
  };
  const response = redirect(env, "/dashboard");
  response.headers.set("set-cookie", sessionCookie(await signed(env, "session", session)));
  return response;
}

export function dashboardLogout(req: Request, env: Env): Response {
  if (req.headers.get("origin") !== publicOrigin(env)) return page(env, "<h1>Invalid request origin</h1>", 403);
  const response = redirect(env, "/dashboard/login");
  response.headers.set("set-cookie", clearSessionCookie());
  return response;
}
export async function dashboard(req: Request, env: Env): Promise<Response> {
  const session = await currentSession(req, env);
  if (!session) {
    const response = redirect(env, "/dashboard/login");
    response.headers.set("set-cookie", clearSessionCookie());
    return response;
  }
  if (!await tenantAllowed(env, session.tenantId)) return tooManyRequests();
  const [foods, logs, pending, daily] = await Promise.all([
    env.DB.prepare("SELECT name, serving, kcal, fruit_veg_portions FROM foods WHERE tenant_id = ? ORDER BY name LIMIT 100").bind(session.tenantId).all(),
    env.DB.prepare("SELECT food_name, quantity, kcal, fruit_veg_portions, local_date FROM food_logs WHERE tenant_id = ? ORDER BY local_date DESC, logged_at DESC LIMIT 100").bind(session.tenantId).all(),
    env.DB.prepare("SELECT id, description, state, proposed_name, proposed_serving, proposed_kcal, proposed_fruit_veg_portions, agent_reasoning, user_clarification FROM pending_estimations WHERE tenant_id = ? ORDER BY created_at DESC LIMIT 100").bind(session.tenantId).all(),
    env.DB.prepare("SELECT id, local_date, state, feedback_text FROM daily_feedback_requests WHERE tenant_id = ? ORDER BY local_date DESC LIMIT 30").bind(session.tenantId).all(),
  ]);
  const table = (heads: string[], rows: unknown[][]) => rows.length ? `<div class="table"><table><thead><tr>${heads.map(h => `<th>${h}</th>`).join("")}</tr></thead><tbody>${rows.map(r => `<tr>${r.map(v => `<td>${escapeHtml(v)}</td>`).join("")}</tr>`).join("")}</tbody></table></div>` : '<p class="muted">None.</p>';
  return page(env, `<h1>${session.kind === "review" ? "Dedicated demo account" : "Your food diary"}</h1><p class="muted">${session.kind === "review" ? "Synthetic sample data only. " : ""}This page is read-only. Refresh to see proposals and daily reflections saved by the connected agent. Food proposals still need approval in the iPhone app before they become logged meals.</p>
    <p><a href="/dashboard">Refresh results</a></p><form method="post" action="/dashboard/logout"><button>Sign out</button></form>
    <h2>Food estimates</h2>${pending.results.map(r => `<article><h3>${escapeHtml(r.description)}</h3><small>${escapeHtml(r.state)} · ${escapeHtml(r.id)}</small>
      ${r.user_clarification ? `<p class="text">Clarification: ${escapeHtml(r.user_clarification)}</p>` : ""}
      ${r.state === "proposed" ? `<p>${escapeHtml(r.proposed_name)} · ${escapeHtml(r.proposed_serving)} · ${escapeHtml(r.proposed_kcal)} kcal · ${escapeHtml(r.proposed_fruit_veg_portions)} produce portions</p><p class="text">${escapeHtml(r.agent_reasoning)}</p>` : ""}</article>`).join("") || '<p class="muted">None.</p>'}
    <h2>Saved food library</h2>${table(["Food", "Serving", "kcal", "Produce portions"], foods.results.map(r => [r.name, r.serving, r.kcal, r.fruit_veg_portions]))}
    <h2>Food logs</h2>${table(["Day", "Food", "Quantity", "kcal", "Produce portions"], logs.results.map(r => [r.local_date, r.food_name, r.quantity, r.kcal, r.fruit_veg_portions]))}
    <h2>Daily reflections</h2>${daily.results.map(r => `<article><h3>${escapeHtml(r.local_date)}</h3><small>${escapeHtml(r.state)} · ${escapeHtml(r.id)}</small><p class="text">${escapeHtml(r.feedback_text || "Awaiting a reflection.")}</p></article>`).join("") || '<p class="muted">None.</p>'}`);
}
