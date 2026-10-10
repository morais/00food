import { describe, expect, it } from "vitest";
import { authenticate, randomToken, sha256Base64url, sha256Hex } from "../src/auth";
import { beginAuthorization, decideConsent, exchangeCode, registerClient, reviewCallback,
  reviewTenantForAccessCode, showConsent } from "../src/oauth";
import { dashboard, dashboardLogin, dashboardLogout, dashboardReviewLogin } from "../src/dashboard";
import { reviewFixtureIds, reviewSeed } from "../src/reviewSeed";
import { routeMcp } from "../src/mcp";
import type { Env } from "../src/api";
import { migratedD1 } from "./d1";

const origin = "https://api.00food.com";
const code = "fd_review_" + "A".repeat(43);
const post = (path: string, body: Record<string, string>, headers: Record<string, string> = {}) =>
  new Request(origin + path, { method: "POST", headers: { origin, ...headers }, body: new URLSearchParams(body) });
async function fixture() {
  const { db, d1 } = migratedD1();
  const tenant = crypto.randomUUID();
  const ids = reviewFixtureIds();
  db.exec(reviewSeed(tenant, await sha256Hex(code), "2999-01-01", ids));
  const env = { DB: d1, PUBLIC_ORIGIN: origin, REVIEW_TENANT_IDS: tenant,
    OAUTH_SIGNING_SECRET: "a".repeat(32), APPLE_WEB_CLIENT_ID: "apple-client",
    APPLE_WEB_REDIRECT_URI: origin + "/auth/apple/callback", APPLE_PRIVATE_KEY: "unused" } as Env;
  return { db, env, tenant, ids };
}

describe("dedicated reviewer access", () => {
  it("requires an allowlisted, unrevoked, unexpired sign-in-only code", async () => {
    const { db, env, tenant } = await fixture();
    try {
      expect(await reviewTenantForAccessCode(env, code)).toBe(tenant);
      expect(await reviewTenantForAccessCode({ ...env, REVIEW_TENANT_IDS: "" }, code)).toBeNull();
      expect(await reviewTenantForAccessCode(env, "fd_review_" + "B".repeat(43))).toBeNull();
      for (const kind of ["app", "mcp"] as const) {
        expect(await authenticate(new Request(origin + "/mcp", { headers: { authorization: `Bearer ${code}` } }), env, kind)).toBeNull();
      }
      db.exec("UPDATE review_credentials SET expires_at = '2000-01-01'");
      expect(await reviewTenantForAccessCode(env, code)).toBeNull();
      db.exec("UPDATE review_credentials SET expires_at = '2999-01-01', revoked_at = '2026-01-01'");
      expect(await reviewTenantForAccessCode(env, code)).toBeNull();
    } finally { db.close(); }
  });

  it("completes consent and PKCE, preserves state, refuses replay and isolates MCP data", async () => {
    const { db, env, tenant, ids } = await fixture();
    try {
      const callback = "https://review.example/callback";
      const registration = await registerClient(new Request(origin + "/oauth/register", {
        method: "POST", body: JSON.stringify({ client_name: "Review test", redirect_uris: [callback] }),
      }), env);
      const { client_id: clientId } = await registration.json() as { client_id: string };
      const verifier = randomToken();
      const state = "opaque-state:" + "x".repeat(1000) + "+/%=";
      const url = new URL(origin + "/oauth/authorize");
      url.search = new URLSearchParams({ client_id: clientId, redirect_uri: callback, response_type: "code",
        code_challenge_method: "S256", code_challenge: await sha256Base64url(verifier),
        resource: origin + "/mcp", scope: "food:read food:write daily:read daily:write", state }).toString();
      const login = await beginAuthorization(new Request(url), env);
      const loginPage = await login.text();
      expect(loginPage).toContain("Reviewer access");
      expect(loginPage).toContain("Sign in with Apple");
      const flow = loginPage.match(/name="flow" value="([^"]+)"/)![1];
      const signIn = (accessCode = code, headers = {}) => reviewCallback(post("/auth/review/callback", { flow, accessCode }, headers), env);
      expect((await signIn(code, { origin: "https://evil.example" })).status).toBe(403);
      expect((await signIn("fd_review_" + "B".repeat(43))).status).toBe(401);
      const signedIn = await signIn();
      expect(signedIn.status).toBe(303);
      expect((await signIn()).status).toBe(401);
      const cookie = signedIn.headers.get("set-cookie")!.split(";")[0];
      const consent = await showConsent(new Request(signedIn.headers.get("location")!, { headers: { cookie } }), env);
      expect(consent.status).toBe(200);
      expect(await consent.text()).toContain("daily");
      const csrf = cookie.split(".")[1];
      const decision = await decideConsent(post("/oauth/consent", { flow, csrf, decision: "approve" }, { cookie }), env);
      const redirect = new URL(decision.headers.get("location")!);
      expect(redirect.searchParams.get("state")).toBe(state);
      const body = { grant_type: "authorization_code", client_id: clientId, redirect_uri: callback,
        code: redirect.searchParams.get("code")!, code_verifier: verifier, resource: origin + "/mcp" };
      expect((await exchangeCode(post("/oauth/token", { ...body, code_verifier: randomToken() }), env)).status).toBe(400);
      const tokenResponse = await exchangeCode(post("/oauth/token", body), env);
      expect(tokenResponse.status).toBe(200);
      const { access_token: token } = await tokenResponse.json() as { access_token: string };
      expect((await exchangeCode(post("/oauth/token", body), env)).status).toBe(400);
      const req = new Request(origin + "/mcp", { headers: { authorization: `Bearer ${token}` } });
      const principal = (await authenticate(req, env, "mcp"))!;
      expect(principal.tenantId).toBe(tenant);
      expect(principal.scopes).toEqual(["food:read", "food:write", "daily:read", "daily:write"]);
      const call = async (name: string, args = {}) => {
        const response = await routeMcp(new Request(origin + "/mcp", { method: "POST",
          body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: args } }) }), env, principal);
        return await response.json() as { result: { content: Array<{ text: string }>; isError?: boolean } };
      };
      expect(JSON.stringify(await call("list_known_foods"))).toContain("Banana oats");
      const context = await call("get_daily_feedback_request", { id: ids.daily });
      expect(JSON.stringify(context)).toContain("2250");
      const other = crypto.randomUUID();
      db.exec(reviewSeed(other, "b".repeat(64), "2999-01-01", reviewFixtureIds()));
      expect((await call("get_pending_food", { id: crypto.randomUUID() })).result.isError).toBe(true);
      await call("propose_food_estimate", { id: ids.estimate, name: "Yogurt bowl", serving: "one bowl", kcal: 320,
        fruitVegPortions: 1, reasoning: "Sample estimate from the described serving." });
      expect(db.prepare("SELECT state FROM pending_estimations WHERE id = ?").get(ids.estimate)?.state).toBe("proposed");
      expect(db.prepare("SELECT COUNT(*) AS n FROM food_logs WHERE tenant_id = ?").get(tenant)?.n).toBe(1);
      await call("set_food_fruit_veg_portions", { id: ids.soup, fruitVegPortions: 2 });
      expect(db.prepare("SELECT fruit_veg_portions FROM food_logs WHERE id = ?").get(ids.log)?.fruit_veg_portions).toBe(2);
      await call("submit_daily_feedback", { id: ids.daily, feedback: "Synthetic reflection; the log is incomplete." });
      expect(db.prepare("SELECT state FROM daily_feedback_requests WHERE id = ?").get(ids.daily)?.state).toBe("ready");
      db.exec(reviewSeed(tenant, await sha256Hex(code), "2999-01-01", ids, new Date(), true));
      expect(db.prepare("SELECT state FROM daily_feedback_requests WHERE id = ?").get(ids.daily)?.state).toBe("pending");
      expect(db.prepare("SELECT COUNT(*) AS n FROM tenants").get()?.n).toBe(2);
    } finally { db.close(); }
  });

  it("hides disabled reviewer login and rejects expired or consumed flows", async () => {
    const { db, env } = await fixture();
    try {
      expect(dashboardLogin({ ...env, REVIEW_TENANT_IDS: "" }).status).toBe(404);
      expect((await reviewCallback(post("/auth/review/callback", { flow: randomToken(24), accessCode: code }), env)).status).toBe(401);
      expect((await reviewCallback(post("/auth/review/callback", {}, { origin }), { ...env, REVIEW_TENANT_IDS: "" })).status).toBe(404);
    } finally { db.close(); }
  });
});

describe("read-only reviewer dashboard", () => {
  it("preserves same-origin form posts and rejects opaque or missing origins", async () => {
    const { db, env } = await fixture();
    try {
      expect(dashboardLogin(env).headers.get("referrer-policy")).toBe("same-origin");
      for (const originHeader of ["null", "https://evil.example", undefined]) {
        const req = new Request(origin + "/dashboard/login/review", {
          method: "POST", headers: originHeader ? { origin: originHeader } : {},
          body: new URLSearchParams({ accessCode: code }),
        });
        expect((await dashboardReviewLogin(req, env)).status).toBe(403);
        expect(dashboardLogout(req, env).status).toBe(403);
      }
    } finally { db.close(); }
  });

  it("scopes the signed session to demo data, escapes output, and rechecks revocation", async () => {
    const { db, env, ids } = await fixture();
    try {
      expect((await dashboard(new Request(origin + "/dashboard"), env)).status).toBe(303);
      expect((await dashboardReviewLogin(post("/dashboard/login/review", { accessCode: code }, { origin: "https://evil.example" }), env)).status).toBe(403);
      expect((await dashboardReviewLogin(post("/dashboard/login/review", { accessCode: "wrong" }), env)).status).toBe(401);
      const signedIn = await dashboardReviewLogin(post("/dashboard/login/review", { accessCode: code }), env);
      const cookie = signedIn.headers.get("set-cookie")!.split(";")[0];
      expect(cookie).not.toContain(code);
      expect(signedIn.headers.get("set-cookie")).toContain("HttpOnly; Secure; SameSite=Lax");
      const req = new Request(origin + "/dashboard", { headers: { cookie } });
      db.prepare("UPDATE pending_estimations SET description = ? WHERE id = ?").run("<script>private</script>", ids.estimate);
      const otherIds = reviewFixtureIds();
      db.exec(reviewSeed(crypto.randomUUID(), "b".repeat(64), "2999-01-01", otherIds));
      db.prepare("UPDATE foods SET name = 'Other tenant secret' WHERE id = ?").run(otherIds.oats);
      const response = await dashboard(req, env);
      expect(response.headers.get("cache-control")).toBe("no-store");
      expect(response.headers.get("referrer-policy")).toBe("same-origin");
      const html = await response.text();
      expect(html).toContain("Banana oats");
      expect(html).toContain("&lt;script&gt;private&lt;/script&gt;");
      expect(html).not.toContain("<script>");
      expect(html).not.toContain("Other tenant secret");
      expect((await dashboard(new Request(origin + "/dashboard", { headers: { cookie: cookie + "tampered" } }), env)).status).toBe(303);
      expect((await dashboard(req, { ...env, REVIEW_TENANT_IDS: crypto.randomUUID() })).status).toBe(303);
      db.exec("UPDATE review_credentials SET revoked_at = '2026-01-01'");
      expect((await dashboard(req, env)).status).toBe(303);
      expect(dashboardLogout(post("/dashboard/logout", {}), env).headers.get("set-cookie")).toContain("Max-Age=0");
    } finally { db.close(); }
  });
});
