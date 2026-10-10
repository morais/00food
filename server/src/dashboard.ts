import { appName, type Env } from "./api";
import { base64url, constantTimeEqual, decodeBase64url, publicOrigin, sha256Hex } from "./auth";
import { reviewTenantForAccessCode } from "./oauth";
import { tenantAllowed, tooManyRequests } from "./rateLimit";

const cookieName = "fd_dashboard_session";
const lifetime = 86400;
type Session = { tenantId: string; reviewCodeHash: string; exp: number };

function configured(env: Env): boolean {
  return Boolean(env.REVIEW_TENANT_IDS?.trim() && env.OAUTH_SIGNING_SECRET && env.OAUTH_SIGNING_SECRET.length >= 32);
}
const escapeHtml = (value: unknown): string => String(value ?? "").replace(/[&<>"']/g,
  c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);

function page(env: Env, body: string, status = 200): Response {
  return new Response(`<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${escapeHtml(appName(env))} · Reviewer dashboard</title><style>
    :root{color-scheme:light dark;--bg:#fbf8f6;--fg:#242220;--card:#fff;--line:#e5ded8;--muted:#71665e;--accent:#994719}
    @media(prefers-color-scheme:dark){:root{--bg:#211b17;--fg:#fff8f1;--card:#2c241e;--line:#574336;--muted:#d4baa7;--accent:#ffb67c}}
    *{box-sizing:border-box}body{font:16px system-ui,sans-serif;line-height:1.5;max-width:900px;margin:auto;padding:24px;background:var(--bg);color:var(--fg)}
    header{font-size:24px;font-weight:750;margin-bottom:24px}main,article{border:1px solid var(--line);border-radius:16px;padding:24px;background:var(--card)}article{margin:12px 0;padding:16px}
    h1{font-size:24px}h2{font-size:21px;margin-top:32px}h3{font-size:18px;margin:0}p{margin:8px 0}small,.muted{color:var(--muted)}.text{white-space:pre-wrap;overflow-wrap:anywhere}code{overflow-wrap:anywhere}
    a{color:var(--accent)}input,button{font:inherit;padding:10px;border-radius:8px}input{width:100%;max-width:580px;border:1px solid var(--line);background:var(--bg);color:var(--fg)}button{margin-top:12px;border:1px solid var(--accent);background:var(--bg);color:var(--accent);cursor:pointer}
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
const sessionCookie = (value: string, age = lifetime) =>
  `${cookieName}=${value}; Path=/dashboard; Max-Age=${age}; HttpOnly; Secure; SameSite=Lax`;
async function signature(env: Env, payload: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(env.OAUTH_SIGNING_SECRET!),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return base64url(new Uint8Array(await crypto.subtle.sign("HMAC", key,
    new TextEncoder().encode(`food-review-dashboard:${payload}`))));
}
async function currentSession(req: Request, env: Env): Promise<Session | null> {
  if (!configured(env)) return null;
  const raw = req.headers.get("cookie")?.split(";").map(p => p.trim())
    .find(p => p.startsWith(`${cookieName}=`))?.slice(cookieName.length + 1);
  if (!raw || raw.length > 2048) return null;
  const [payload, mac, extra] = raw.split(".");
  if (!payload || !mac || extra || !constantTimeEqual(mac, await signature(env, payload))) return null;
  let session: Session;
  try { session = JSON.parse(new TextDecoder().decode(decodeBase64url(payload))) as Session; }
  catch { return null; }
  if (!session || !Number.isFinite(session.exp) || session.exp <= Date.now() / 1000
    || typeof session.tenantId !== "string" || !/^[a-f0-9-]{36}$/.test(session.tenantId)
    || !/^[a-f0-9]{64}$/.test(session.reviewCodeHash)
    || !env.REVIEW_TENANT_IDS!.split(",").map(id => id.trim()).includes(session.tenantId)) return null;
  const valid = await env.DB.prepare(`SELECT tenant_id FROM review_credentials
    WHERE token_hash = ? AND tenant_id = ? AND revoked_at IS NULL AND expires_at > ?`)
    .bind(session.reviewCodeHash, session.tenantId, new Date().toISOString()).first();
  return valid ? session : null;
}
export function dashboardLogin(env: Env): Response {
  if (!configured(env)) return page(env, "<h1>Not found</h1>", 404);
  return page(env, `<h1>Reviewer access</h1><p>Use the dedicated demo account's access code from the secure reviewer instructions.</p>
    <form method="post" action="/dashboard/login/review"><label for="code">Review access code</label><br>
    <input id="code" type="password" name="accessCode" autocomplete="off" required maxlength="128"><br><button>Sign in as reviewer</button></form>`);
}
export async function dashboardReviewLogin(req: Request, env: Env): Promise<Response> {
  if (!configured(env)) return page(env, "<h1>Not found</h1>", 404);
  if (req.headers.get("origin") !== publicOrigin(env)) return page(env, "<h1>Invalid request origin</h1>", 403);
  if (Number(req.headers.get("content-length") ?? 0) > 1024) return page(env, "<h1>Invalid request</h1>", 400);
  const body = await req.text();
  if (body.length > 1024) return page(env, "<h1>Invalid request</h1>", 400);
  const code = new URLSearchParams(body).get("accessCode") ?? "";
  const tenantId = await reviewTenantForAccessCode(env, code);
  if (!tenantId) return page(env, '<h1>Invalid or expired review access</h1><p><a href="/dashboard/login">Try again</a>.</p>', 401);
  const session: Session = { tenantId, reviewCodeHash: await sha256Hex(code), exp: Math.floor(Date.now() / 1000) + lifetime };
  const payload = base64url(new TextEncoder().encode(JSON.stringify(session)));
  const response = redirect(env, "/dashboard");
  response.headers.set("set-cookie", sessionCookie(`${payload}.${await signature(env, payload)}`));
  return response;
}
export function dashboardLogout(req: Request, env: Env): Response {
  if (req.headers.get("origin") !== publicOrigin(env)) return page(env, "<h1>Invalid request origin</h1>", 403);
  const response = redirect(env, "/dashboard/login");
  response.headers.set("set-cookie", sessionCookie("", 0));
  return response;
}
export async function dashboard(req: Request, env: Env): Promise<Response> {
  if (!configured(env)) return page(env, "<h1>Not found</h1>", 404);
  const session = await currentSession(req, env);
  if (!session) return redirect(env, "/dashboard/login");
  if (!await tenantAllowed(env, session.tenantId)) return tooManyRequests();
  const [foods, logs, pending, daily] = await Promise.all([
    env.DB.prepare("SELECT name, serving, kcal, fruit_veg_portions FROM foods WHERE tenant_id = ? ORDER BY name LIMIT 100").bind(session.tenantId).all(),
    env.DB.prepare("SELECT food_name, quantity, kcal, fruit_veg_portions, local_date FROM food_logs WHERE tenant_id = ? ORDER BY local_date DESC, logged_at DESC LIMIT 100").bind(session.tenantId).all(),
    env.DB.prepare("SELECT id, description, state, proposed_name, proposed_serving, proposed_kcal, proposed_fruit_veg_portions, agent_reasoning, user_clarification FROM pending_estimations WHERE tenant_id = ? ORDER BY created_at DESC LIMIT 100").bind(session.tenantId).all(),
    env.DB.prepare("SELECT id, local_date, state, feedback_text FROM daily_feedback_requests WHERE tenant_id = ? ORDER BY local_date DESC LIMIT 30").bind(session.tenantId).all(),
  ]);
  const table = (heads: string[], rows: unknown[][]) => rows.length ? `<div class="table"><table><thead><tr>${heads.map(h => `<th>${h}</th>`).join("")}</tr></thead><tbody>${rows.map(r => `<tr>${r.map(v => `<td>${escapeHtml(v)}</td>`).join("")}</tr>`).join("")}</tbody></table></div>` : '<p class="muted">None.</p>';
  return page(env, `<h1>Dedicated demo account</h1><p class="muted">Synthetic sample data only. This page is read-only. Refresh to see proposals and daily reflections saved by the connected agent. Food proposals still need approval in the iPhone app before they become logged meals.</p>
    <p><a href="/dashboard">Refresh results</a></p><form method="post" action="/dashboard/logout"><button>Sign out</button></form>
    <h2>Food estimates</h2>${pending.results.map(r => `<article><h3>${escapeHtml(r.description)}</h3><small>${escapeHtml(r.state)} · ${escapeHtml(r.id)}</small>
      ${r.user_clarification ? `<p class="text">Clarification: ${escapeHtml(r.user_clarification)}</p>` : ""}
      ${r.state === "proposed" ? `<p>${escapeHtml(r.proposed_name)} · ${escapeHtml(r.proposed_serving)} · ${escapeHtml(r.proposed_kcal)} kcal · ${escapeHtml(r.proposed_fruit_veg_portions)} produce portions</p><p class="text">${escapeHtml(r.agent_reasoning)}</p>` : ""}</article>`).join("") || '<p class="muted">None.</p>'}
    <h2>Saved food library</h2>${table(["Food", "Serving", "kcal", "Produce portions"], foods.results.map(r => [r.name, r.serving, r.kcal, r.fruit_veg_portions]))}
    <h2>Food logs</h2>${table(["Day", "Food", "Quantity", "kcal", "Produce portions"], logs.results.map(r => [r.local_date, r.food_name, r.quantity, r.kcal, r.fruit_veg_portions]))}
    <h2>Daily reflections</h2>${daily.results.map(r => `<article><h3>${escapeHtml(r.local_date)}</h3><small>${escapeHtml(r.state)} · ${escapeHtml(r.id)}</small><p class="text">${escapeHtml(r.feedback_text || "Awaiting a reflection.")}</p></article>`).join("") || '<p class="muted">None.</p>'}`);
}
