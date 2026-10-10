#!/usr/bin/env node
// Exercise only the dedicated synthetic tenant. Never print codes or tokens.
import { createHash, randomBytes } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { reviewSeed } from "../src/reviewSeed.ts";

const server = dirname(dirname(fileURLToPath(import.meta.url)));
const saved = JSON.parse(readFileSync(join(server, ".review-access.json"), "utf8"));
const config = readFileSync(join(server, "wrangler.toml"), "utf8");
const origin = config.match(/^PUBLIC_ORIGIN\s*=\s*"([^"]+)"/m)?.[1];
if (!origin?.startsWith("https://") || !saved.provisioned) throw new Error("Provision the deployment's reviewer fixture first");
const callback = "https://review.example/callback";
const verifier = randomBytes(32).toString("base64url");
const hash = value => createHash("sha256").update(value).digest("hex");
const post = (path, body, extra = {}) => fetch(origin + path, { method: "POST", redirect: "manual",
  headers: { "content-type": "application/x-www-form-urlencoded", ...extra }, body: new URLSearchParams(body) });
const assert = (condition, message) => { if (!condition) throw new Error(message); };
const status = (response, expected, step) => assert(response.status === expected, `${step}: expected ${expected}, got ${response.status}`);
const hidden = (html, name) => {
  const value = html.match(new RegExp(`name="${name}" value="([^"]+)"`))?.[1];
  assert(value, `Missing ${name} in form`); return value;
};
const execute = sql => {
  const temporary = mkdtempSync(join(tmpdir(), "00food-review-smoke-"));
  try {
    const path = join(temporary, "cleanup.sql");
    writeFileSync(path, sql, { mode: 0o600 });
    execFileSync("npx", ["wrangler", "d1", "execute", "00food", "--remote", "--file", path], { cwd: server, stdio: "ignore" });
  } finally { rmSync(temporary, { recursive: true, force: true }); }
};
const reset = () => reviewSeed(saved.tenantId, hash(saved.accessCode), saved.expiresAt,
  saved.ids, new Date(saved.seededAt), true);
let tokenHash;
try {
  execute(reset());
  const registration = await fetch(origin + "/oauth/register", { method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ client_name: "Reviewer smoke test", redirect_uris: [callback] }) });
  status(registration, 201, "client registration");
  const { client_id: clientId } = await registration.json();
  const url = new URL(origin + "/oauth/authorize");
  url.search = new URLSearchParams({ client_id: clientId, redirect_uri: callback, response_type: "code",
    code_challenge_method: "S256", code_challenge: createHash("sha256").update(verifier).digest("base64url"),
    resource: origin + "/mcp", scope: "food:read food:write daily:read daily:write", state: "review-smoke" }).toString();
  const login = await fetch(url, { redirect: "manual" });
  status(login, 200, "review login");
  const flow = hidden(await login.text(), "flow");
  const signedIn = await post("/auth/review/callback", { flow, accessCode: saved.accessCode }, { origin });
  status(signedIn, 303, "review code exchange");
  const cookie = signedIn.headers.get("set-cookie")?.split(";", 1)[0];
  assert(cookie, "Missing consent cookie");
  const consent = await fetch(signedIn.headers.get("location"), { headers: { cookie } });
  status(consent, 200, "consent page");
  const csrf = hidden(await consent.text(), "csrf");
  const decision = await post("/oauth/consent", { flow, csrf, decision: "approve" }, { origin, cookie });
  status(decision, 303, "consent approval");
  const approved = new URL(decision.headers.get("location"));
  assert(approved.searchParams.get("state") === "review-smoke", "OAuth state changed");
  const exchanged = await post("/oauth/token", { grant_type: "authorization_code", client_id: clientId,
    redirect_uri: callback, code: approved.searchParams.get("code"), code_verifier: verifier, resource: origin + "/mcp" });
  status(exchanged, 200, "token exchange");
  const { access_token: token } = await exchanged.json();
  assert(typeof token === "string", "Missing access token");
  tokenHash = hash(token);
  const rpc = async (method, params) => {
    const response = await fetch(origin + "/mcp", { method: "POST", headers: {
      authorization: `Bearer ${token}`, "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) });
    status(response, 200, method);
    const value = await response.json();
    assert(!value.error && !value.result?.isError, `${method} returned an error`);
    return value.result;
  };
  const tools = (await rpc("tools/list", {})).tools;
  assert(tools.length === 10, "Unexpected tool catalog");
  assert(tools.every(t => ["readOnlyHint", "openWorldHint", "destructiveHint"].every(k => typeof t.annotations?.[k] === "boolean")), "Missing tool annotations");
  const call = async (name, args = {}) => JSON.parse((await rpc("tools/call", { name, arguments: args })).content[0].text);
  const pending = (await call("list_pending_foods")).foods;
  assert(pending.some(f => f.id === saved.ids.estimate && f.state === "pending"), "Pending fixture missing");
  assert((await call("get_pending_food", { id: saved.ids.estimate })).food.description.includes("Greek yogurt"), "Description missing");
  const known = (await call("list_known_foods")).foods;
  assert(known.length === 2 && known.some(f => f.name === "Banana oats"), "Library fixture missing");
  await call("propose_food_estimate", { id: saved.ids.estimate, name: "Yogurt bowl", serving: "one bowl", kcal: 320,
    fruitVegPortions: 1, reasoning: "Synthetic demo estimate from the described yogurt, banana, and oats." });
  assert((await call("get_pending_food", { id: saved.ids.estimate })).food.state === "proposed", "Proposal not persisted");
  assert((await call("set_food_fruit_veg_portions", { id: saved.ids.soup, fruitVegPortions: 2 })).food.fruitVegPortions === 2, "Produce correction failed");
  assert((await call("list_pending_daily_feedback")).requests.some(r => r.id === saved.ids.daily), "Daily fixture missing");
  const context = (await call("get_daily_feedback_request", { id: saved.ids.daily })).context;
  const day = context.days.at(-1);
  assert(day.foodKcal === 180 && day.fruitVegPortions === 2 && day.waterIntakeAtLeastMl === 2250, "Daily fixture totals differ");
  assert(context.currentPlanDeficitPercent === 15 && day.calorieBudget.allowanceKcal === 1700, "Percentage budget differs");
  await call("submit_daily_feedback", { id: saved.ids.daily, feedback: "Synthetic demo reflection. The food log is incomplete; recorded water meets the tracking goal." });
  const dashLogin = await post("/dashboard/login/review", { accessCode: saved.accessCode }, { origin });
  status(dashLogin, 303, "dashboard sign-in");
  const dashCookie = dashLogin.headers.get("set-cookie")?.split(";", 1)[0];
  const dash = await fetch(origin + "/dashboard", { headers: { cookie: dashCookie } });
  status(dash, 200, "dashboard");
  const html = await dash.text();
  assert(html.includes("Yogurt bowl") && html.includes("Synthetic demo reflection"), "Dashboard results missing");
  const logout = await post("/dashboard/logout", {}, { origin, cookie: dashCookie });
  status(logout, 303, "dashboard logout");
  console.log("Passed: reviewer OAuth/PKCE, ten annotated tools, pending foods, library, proposal, produce correction, daily context/reflection, read-only dashboard.");
} finally {
  execute(reset() + (tokenHash ? `\nUPDATE credentials SET revoked_at = '${new Date().toISOString()}' WHERE token_hash = '${tokenHash}' AND tenant_id = '${saved.tenantId}' AND kind = 'mcp';` : ""));
  console.log("Synthetic fixtures reset; temporary MCP grant revoked if issued.");
}
