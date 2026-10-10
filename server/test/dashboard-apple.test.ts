import { afterEach, describe, expect, it, vi } from "vitest";
import handler from "../src/index";
import { base64url, authenticate } from "../src/auth";
import { resetAppleKeysForTest } from "../src/apple";
import { dashboardAppleCallback, dashboardAppleLogin, isDashboardAppleState } from "../src/dashboard";
import { reviewSeed, reviewFixtureIds } from "../src/reviewSeed";
import type { Env } from "../src/api";
import { migratedD1 } from "./d1";

vi.mock("../src/FoodEventStream", () => ({ FoodEventStream: class {} }));

const origin = "https://api.00food.com";
const ctx = { waitUntil: vi.fn() } as unknown as ExecutionContext;
const request = (path: string, env: Env, init?: RequestInit) =>
  handler.fetch(new Request(origin + path, init), env, ctx);
const cookieValue = (response: Response, name: string) =>
  response.headers.get("set-cookie")?.match(new RegExp(`${name}=[^;]+`))?.[0] ?? "";

function fixture() {
  const { db, d1 } = migratedD1();
  const tenantId = crypto.randomUUID();
  const ids = reviewFixtureIds();
  db.exec(reviewSeed(tenantId, "a".repeat(64), "2999-01-01", ids));
  db.prepare("UPDATE tenants SET apple_subject = 'alice' WHERE id = ?").run(tenantId);
  db.prepare("UPDATE foods SET name = 'Alice food' WHERE id = ?").run(ids.oats);
  db.prepare("UPDATE pending_estimations SET description = 'Alice estimate' WHERE id = ?").run(ids.estimate);
  db.prepare("UPDATE daily_feedback_requests SET feedback_text = 'Alice reflection' WHERE id = ?").run(ids.daily);
  const otherId = crypto.randomUUID();
  const other = reviewFixtureIds();
  db.exec(reviewSeed(otherId, "b".repeat(64), "2999-01-01", other));
  db.prepare("UPDATE foods SET name = 'Other private food' WHERE id = ?").run(other.oats);
  db.prepare("UPDATE food_logs SET food_name = 'Other private log' WHERE id = ?").run(other.log);
  db.prepare("UPDATE pending_estimations SET description = 'Other private estimate' WHERE id = ?").run(other.estimate);
  db.prepare("UPDATE daily_feedback_requests SET feedback_text = 'Other private reflection' WHERE id = ?").run(other.daily);
  const env = { DB: d1, PUBLIC_ORIGIN: origin, OAUTH_SIGNING_SECRET: "a".repeat(32),
    APPLE_WEB_CLIENT_ID: "food-web-client", APPLE_WEB_REDIRECT_URI: origin + "/auth/apple/callback",
    APPLE_PRIVATE_KEY: "configured", APPLE_TEAM_ID: "test-team", APPLE_KEY_ID: "test-key",
    SIGN_IN_LIMITER: { async limit() { return { success: true }; } }, REVIEW_TENANT_IDS: "",
  } as unknown as Env;
  return { db, env, tenantId };
}

async function appleFlow(env: Env, claims: Record<string, unknown> = {}, exchangedClaims?: Record<string, unknown>) {
  const login = await request("/dashboard/login/apple", env);
  expect(login.status).toBe(302);
  const url = new URL(login.headers.get("location")!);
  const state = url.searchParams.get("state")!;
  const nonce = url.searchParams.get("nonce")!;
  const flowCookie = cookieValue(login, "fd_dashboard_flow");
  const rsa = await crypto.subtle.generateKey({ name: "RSASSA-PKCS1-v1_5", modulusLength: 2048,
    publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" }, true, ["sign", "verify"]) as CryptoKeyPair;
  const ec = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true,
    ["sign", "verify"]) as CryptoKeyPair;
  const pem = new Uint8Array(await crypto.subtle.exportKey("pkcs8", ec.privateKey));
  env.APPLE_PRIVATE_KEY = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...pem))}\n-----END PRIVATE KEY-----`;
  const jwk = await crypto.subtle.exportKey("jwk", rsa.publicKey);
  const now = Math.floor(Date.now() / 1000);
  const token = async (overrides: Record<string, unknown>) => {
    const encode = (value: unknown) => base64url(new TextEncoder().encode(JSON.stringify(value)));
    const input = `${encode({ alg: "RS256", kid: "dashboard-test" })}.${encode({
      iss: "https://appleid.apple.com", aud: env.APPLE_WEB_CLIENT_ID, sub: "alice",
      iat: now, exp: now + 600, nonce, ...overrides,
    })}`;
    const signature = new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", rsa.privateKey,
      new TextEncoder().encode(input)));
    return `${input}.${base64url(signature)}`;
  };
  const identityToken = await token(claims);
  const exchangedToken = await token(exchangedClaims ?? claims);
  const fetchMock = vi.spyOn(globalThis, "fetch").mockImplementation(async input => {
    if (String(input).endsWith("/auth/keys")) return Response.json({ keys: [{ kty: "RSA", kid: "dashboard-test", n: jwk.n, e: jwk.e }] });
    if (String(input).endsWith("/auth/token")) return Response.json({ id_token: exchangedToken, access_token: "apple-test-token" });
    throw new Error("Unexpected Apple endpoint");
  });
  return { url, state, flowCookie, fetchMock,
    form: new URLSearchParams({ state, id_token: identityToken, code: "one-use-apple-code" }) };
}

afterEach(() => { vi.restoreAllMocks(); resetAppleKeysForTest(); });

describe("Apple dashboard sign-in", () => {
  it("offers Apple sign-in without reviewer configuration and handles missing configuration", async () => {
    const { db, env } = fixture();
    try {
      const response = await request("/dashboard/login", env);
      const html = await response.text();
      expect(response.status).toBe(200);
      expect(html).toContain("Sign in with Apple");
      expect(html).not.toContain("Reviewer access");
      expect((await request("/dashboard/login", { ...env, APPLE_PRIVATE_KEY: "" })).status).toBe(503);
      expect((await dashboardAppleLogin({ ...env, APPLE_PRIVATE_KEY: "" })).status).toBe(503);
      expect((await request("/dashboard/", env)).headers.get("location")).toBe(origin + "/dashboard/login");
      expect((await request("/dashboard/login/apple", { ...env, SIGN_IN_LIMITER: undefined })).status).toBe(429);
    } finally { db.close(); }
  });

  it("opens only the existing Apple account through the shared callback, without issuing app or MCP grants", async () => {
    const { db, env, tenantId } = fixture();
    try {
      const flow = await appleFlow(env);
      expect(flow.url.origin).toBe("https://appleid.apple.com");
      expect(flow.url.searchParams.get("client_id")).toBe(env.APPLE_WEB_CLIENT_ID);
      expect(flow.url.searchParams.get("redirect_uri")).toBe(env.APPLE_WEB_REDIRECT_URI);
      expect(flow.url.searchParams.get("response_mode")).toBe("form_post");
      expect(isDashboardAppleState(flow.state)).toBe(true);
      const callback = await request("/auth/apple/callback", env, { method: "POST",
        headers: { cookie: flow.flowCookie }, body: flow.form });
      expect(callback.status).toBe(303);
      expect(callback.headers.get("location")).toBe(origin + "/dashboard");
      expect(callback.headers.get("set-cookie")).toContain("fd_dashboard_flow=; Path=/auth/apple/callback; Max-Age=0");
      const cookie = cookieValue(callback, "fd_dashboard_session");
      expect(cookie).toBeTruthy();
      expect(callback.headers.get("set-cookie")).toContain("HttpOnly; Secure; SameSite=Lax");
      const view = await request("/dashboard", env, { headers: { cookie } });
      expect(view.status).toBe(200);
      const html = await view.text();
      expect(html).toContain("Your food diary");
      expect(html).toContain("Alice food");
      expect(html).toContain("Alice estimate");
      expect(html).toContain("Alice reflection");
      expect(html).not.toContain("Other private");
      expect(html).not.toContain("Synthetic sample data only");
      expect(db.prepare("SELECT COUNT(*) AS n FROM tenants").get()?.n).toBe(2);
      expect(db.prepare("SELECT COUNT(*) AS n FROM credentials").get()?.n).toBe(0);
      expect((await request("/dashboard/login", env, { headers: { cookie } })).status).toBe(303);
      expect(await authenticate(new Request(origin + "/mcp", { headers: { authorization: "Bearer " + cookie } }), env, "mcp")).toBeNull();
      expect((await request("/dashboard", env, { headers: { cookie: cookie + "tampered" } })).status).toBe(303);
      db.prepare("UPDATE tenants SET apple_subject = 'changed' WHERE id = ?").run(tenantId);
      expect((await request("/dashboard", env, { headers: { cookie } })).status).toBe(303);
    } finally { db.close(); }
  });

  it("creates an empty account for a new Apple identity and expires its browser session", async () => {
    const { db, env } = fixture();
    try {
      const flow = await appleFlow(env, { sub: "new-apple-user" });
      const callback = await request("/auth/apple/callback", env, { method: "POST", headers: { cookie: flow.flowCookie }, body: flow.form });
      expect(callback.status).toBe(303);
      const cookie = cookieValue(callback, "fd_dashboard_session");
      const view = await request("/dashboard", env, { headers: { cookie } });
      const html = await view.text();
      expect(view.status).toBe(200);
      expect(html).not.toContain("Alice food");
      expect(html).not.toContain("Other private");
      expect(db.prepare("SELECT COUNT(*) AS n FROM tenants").get()?.n).toBe(3);
      vi.spyOn(Date, "now").mockReturnValue(Date.now() + 86401000);
      expect((await request("/dashboard", env, { headers: { cookie } })).status).toBe(303);
    } finally { db.close(); }
  });

  it("binds the callback to the browser cookie, state, expiry, and Apple cancellation", async () => {
    const { db, env } = fixture();
    try {
      const flow = await appleFlow(env);
      for (const [cookie, state, error] of [
        ["", flow.state, ""], [flow.flowCookie + "tampered", flow.state, ""],
        [flow.flowCookie, "fddash_" + "B".repeat(32), ""], [flow.flowCookie, flow.state, "access_denied"],
      ]) {
        const response = await dashboardAppleCallback(new Request(origin + "/auth/apple/callback", { headers: { cookie } }),
          env, new URLSearchParams({ state, error }));
        expect(response.status).toBe(401);
        expect(response.headers.get("set-cookie")).toContain("Max-Age=0");
      }
      vi.spyOn(Date, "now").mockReturnValue(Date.now() + 601000);
      expect((await dashboardAppleCallback(new Request(origin + "/auth/apple/callback", { headers: { cookie: flow.flowCookie } }), env, flow.form)).status).toBe(401);
      expect(flow.fetchMock).not.toHaveBeenCalled();
    } finally { db.close(); }
  });

  it.each([
    [{ nonce: "wrong-nonce" }, undefined], [{ aud: "another-app" }, undefined],
    [{}, { sub: "different-apple-user" }],
  ])("rejects invalid Apple identity claims or an account changed during exchange", async (claims, exchanged) => {
    const { db, env } = fixture();
    try {
      const flow = await appleFlow(env, claims, exchanged);
      vi.spyOn(console, "warn").mockImplementation(() => {});
      const callback = await request("/auth/apple/callback", env, { method: "POST", headers: { cookie: flow.flowCookie }, body: flow.form });
      expect(callback.status).toBe(401);
      expect(cookieValue(callback, "fd_dashboard_session")).toBe("");
      expect(db.prepare("SELECT COUNT(*) AS n FROM tenants").get()?.n).toBe(2);
    } finally { db.close(); }
  });

  it("keeps the existing MCP Apple callback separate and bounds callback payloads", async () => {
    const { db, env } = fixture();
    try {
      const mcp = await request("/auth/apple/callback", env, { method: "POST", body: new URLSearchParams({ state: "A".repeat(32) }) });
      expect(mcp.status).toBe(400);
      expect(await mcp.text()).toContain("Sign-in session expired");
      expect((await request("/auth/apple/callback", env, { method: "POST", body: "a".repeat(16001) })).status).toBe(413);
    } finally { db.close(); }
  });
});
