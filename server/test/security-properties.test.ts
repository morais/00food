// One regression test per defensive property listed in SECURITY.md. Keep the
// numbering in step with that file.
import { afterEach, describe, expect, it, vi } from "vitest";
import { routeApi, type Env } from "../src/api";
import { resetAppleKeysForTest, verifyAppleIdToken } from "../src/apple";
import { authenticate, base64url, issueCredential, sha256Base64url, sha256Hex, type Principal } from "../src/auth";
import { routeMcp } from "../src/mcp";
import { McpEventsError, subscribeWebhookEvent } from "../src/mcpWebhookEvents";
import { exchangeCode, registerClient } from "../src/oauth";
import { migratedD1 } from "./d1";

const origin = "https://api.00food.com";
const now = "2026-10-08T00:00:00.000Z";
afterEach(() => { vi.unstubAllGlobals(); resetAppleKeysForTest(); });

function twoTenants() {
  const { db, d1 } = migratedD1();
  for (const tenant of ["alice", "mallory"]) {
    db.prepare("INSERT INTO tenants (id, apple_subject, email, created_at, updated_at) VALUES (?, ?, NULL, ?, ?)").run(tenant, `apple-${tenant}`, now, now);
  }
  return { db, env: { DB: d1, PUBLIC_ORIGIN: origin } as Env };
}
const principal = (tenantId: string, kind: "app" | "mcp" = "app"): Principal =>
  ({ tenantId, kind, tokenHash: `hash-${tenantId}`, scopes: ["food:read", "food:write", "daily:read", "daily:write"] });

describe("1. Tenant isolation", () => {
  it("does not let one account read, change, or delete another account's data", async () => {
    const { db, env } = twoTenants();
    try {
      const estimate = "11111111-1111-4111-8111-111111111111";
      const food = "22222222-2222-4222-8222-222222222222";
      const log = "33333333-3333-4333-8333-333333333333";
      db.prepare(`INSERT INTO pending_estimations (id, tenant_id, description, state, proposed_name, proposed_serving,
        proposed_kcal, local_date, created_at, updated_at)
        VALUES (?, 'alice', 'Private soup', 'proposed', 'Soup', '1 bowl', 200, '2026-10-08', ?, ?)`).run(estimate, now, now);
      db.prepare(`INSERT INTO foods (id, tenant_id, name, serving, kcal, source, created_at, updated_at)
        VALUES (?, 'alice', 'Toast', '1 slice', 90, 'manual', ?, ?)`).run(food, now, now);
      db.prepare(`INSERT INTO food_logs (id, tenant_id, food_id, food_name, serving, quantity, kcal, local_date, logged_at)
        VALUES (?, 'alice', ?, 'Toast', '1 slice', 1, 90, '2026-10-08', ?)`).run(log, food, now);
      const as = (method: string, path: string, body?: unknown) => routeApi(new Request(`${origin}${path}`,
        { method, body: body ? JSON.stringify(body) : undefined }), env, principal("mallory"));

      expect((await as("POST", `/v1/estimations/${estimate}/accept`)).status).toBe(409);
      expect((await as("DELETE", `/v1/estimations/${estimate}`)).status).toBe(404);
      expect((await as("DELETE", `/v1/logs/${log}`)).status).toBe(404);
      expect((await as("POST", "/v1/logs", { foodId: food, localDate: "2026-10-08" })).status).toBe(404);
      expect((await as("POST", `/v1/foods/${food}/dismiss`)).status).toBe(404);
      const snapshot = await (await as("GET", "/v1/snapshot")).text();
      expect(snapshot).not.toContain("Private soup");
      expect(snapshot).not.toContain("Toast");

      const mcp = await routeMcp(new Request(`${origin}/mcp`, { method: "POST", body: JSON.stringify({
        jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "get_pending_food", arguments: { id: estimate } },
      }) }), env, principal("mallory", "mcp"));
      expect(await mcp.text()).not.toContain("Private soup");

      expect(db.prepare("SELECT COUNT(*) AS n FROM pending_estimations").get()).toEqual({ n: 1 });
      expect(db.prepare("SELECT COUNT(*) AS n FROM food_logs").get()).toEqual({ n: 1 });
    } finally { db.close(); }
  });
});

describe("2. Credential opacity", () => {
  it("stores only a hash and keeps app and MCP credentials apart", async () => {
    const { db, env } = twoTenants();
    try {
      const app = await issueCredential(env, "alice", "app", "iOS app");
      const mcp = await issueCredential(env, "alice", "mcp", "MCP · Test", ["food:read"]);
      const stored = db.prepare("SELECT token_hash FROM credentials").all() as { token_hash: string }[];
      expect(stored.map(row => row.token_hash).sort()).toEqual([await sha256Hex(app.token), await sha256Hex(mcp.token)].sort());
      expect(JSON.stringify(db.prepare("SELECT * FROM credentials").all())).not.toContain(app.token.slice(7));

      const bearer = (token: string) => new Request(origin, { headers: { authorization: `Bearer ${token}` } });
      expect(await authenticate(bearer(app.token), env, "app")).toMatchObject({ tenantId: "alice", kind: "app" });
      expect(await authenticate(bearer(app.token), env, "mcp")).toBeNull();
      expect(await authenticate(bearer(mcp.token), env, "app")).toBeNull();
      expect(await authenticate(bearer(mcp.token), env, "mcp")).toMatchObject({ scopes: ["food:read"] });
    } finally { db.close(); }
  });
});

describe("3. Scoped agent access", () => {
  it("refuses food tools to a daily-only connection and cannot log food", async () => {
    const { db, env } = twoTenants();
    try {
      const dailyOnly: Principal = { tenantId: "alice", kind: "mcp", tokenHash: "h", scopes: ["daily:read"] };
      const response = await routeMcp(new Request(`${origin}/mcp`, { method: "POST", body: JSON.stringify({
        jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "list_pending_foods", arguments: {} },
      }) }), env, dailyOnly);
      expect(response.status).toBe(403);
      const tools = await (await routeMcp(new Request(`${origin}/mcp`, { method: "POST", body: JSON.stringify({
        jsonrpc: "2.0", id: 2, method: "tools/list" }) }), env, principal("alice", "mcp"))).json() as
        { result: { tools: { name: string; annotations: { readOnlyHint: boolean } }[] } };
      // Agents may only propose and annotate; nothing they can call logs or accepts food.
      expect(tools.result.tools.filter(tool => !tool.annotations.readOnlyHint).map(tool => tool.name).sort())
        .toEqual(["propose_food_estimate", "set_food_fruit_veg_portions", "submit_daily_feedback"]);
    } finally { db.close(); }
  });
});

describe("4. Apple identity validation", () => {
  async function signer() {
    const pair = await crypto.subtle.generateKey({ name: "RSASSA-PKCS1-v1_5", modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" }, true, ["sign", "verify"]) as CryptoKeyPair;
    const jwk = await crypto.subtle.exportKey("jwk", pair.publicKey) as JsonWebKey;
    vi.stubGlobal("fetch", vi.fn(async () => Response.json({ keys: [{ kty: "RSA", kid: "k1", n: jwk.n, e: jwk.e }] })));
    const encode = (value: unknown) => base64url(new TextEncoder().encode(JSON.stringify(value)));
    return async (claims: Record<string, unknown>, header: Record<string, unknown> = { alg: "RS256", kid: "k1" }) => {
      const input = `${encode(header)}.${encode(claims)}`;
      const signature = new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", pair.privateKey,
        new TextEncoder().encode(input)));
      return `${input}.${base64url(signature)}`;
    };
  }
  const t = Math.floor(Date.now() / 1000);
  const good = { iss: "https://appleid.apple.com", aud: "com.example.app", sub: "user", iat: t, exp: t + 600, nonce: "n" };

  it("accepts a correctly signed, current token for this app and nonce", async () => {
    const sign = await signer();
    await expect(verifyAppleIdToken(await sign(good), "com.example.app", "n")).resolves.toMatchObject({ sub: "user" });
  });

  it.each([
    ["another audience", { aud: "com.other.app" }],
    ["another issuer", { iss: "https://evil.example" }],
    ["a different nonce", { nonce: "other" }],
    ["an expired token", { exp: t - 1 }],
    ["a stale issue time", { iat: t - 3600 }],
    ["an unverified email", { email: "a@example.com", email_verified: false }],
  ])("rejects %s", async (_label, change) => {
    const sign = await signer();
    await expect(verifyAppleIdToken(await sign({ ...good, ...change }), "com.example.app", "n")).rejects.toThrow();
  });

  it("rejects a tampered payload and an unsigned token", async () => {
    const sign = await signer();
    const [header, , signature] = (await sign(good)).split(".");
    const forged = base64url(new TextEncoder().encode(JSON.stringify({ ...good, sub: "victim" })));
    await expect(verifyAppleIdToken(`${header}.${forged}.${signature}`, "com.example.app", "n")).rejects.toThrow();
    await expect(verifyAppleIdToken(await sign(good, { alg: "none", kid: "k1" }), "com.example.app", "n")).rejects.toThrow();
  });
});

describe("5. OAuth for MCP", () => {
  it("requires S256 PKCE, the bound client and redirect, and redeems a code once", async () => {
    const { db, env: base } = twoTenants();
    try {
      const env = { ...base, OAUTH_SIGNING_SECRET: "x".repeat(32), APPLE_WEB_CLIENT_ID: "web",
        APPLE_WEB_REDIRECT_URI: `${origin}/auth/apple/callback`, APPLE_PRIVATE_KEY: "unused" } as Env;
      const register = async (redirect: string) => (await (await registerClient(new Request(`${origin}/oauth/register`, {
        method: "POST", body: JSON.stringify({ redirect_uris: [redirect], client_name: "Test" }) }), env)).json() as
        { client_id: string }).client_id;
      const clientId = await register("https://client.example/cb");
      const otherClient = await register("https://other.example/cb");
      const verifier = "v".repeat(50);
      const code = "c".repeat(43);
      db.prepare(`INSERT INTO oauth_codes (code_hash, tenant_id, client_id, redirect_uri, code_challenge, resource, scopes, expires_at)
        VALUES (?, 'alice', ?, 'https://client.example/cb', ?, ?, 'food:read', '2999-01-01')`)
        .run(await sha256Hex(code), clientId, await sha256Base64url(verifier), `${origin}/mcp`);
      const exchange = (fields: Record<string, string>) => exchangeCode(new Request(`${origin}/oauth/token`, {
        method: "POST", body: new URLSearchParams({ grant_type: "authorization_code", client_id: clientId, code,
          code_verifier: verifier, redirect_uri: "https://client.example/cb", resource: `${origin}/mcp`, ...fields }) }), env);

      expect((await exchange({ code_verifier: "w".repeat(50) })).status).toBe(400);
      expect((await exchange({ client_id: otherClient })).status).toBe(400);
      expect((await exchange({ redirect_uri: "https://client.example/other" })).status).toBe(400);
      expect((await exchange({ client_id: `${clientId.slice(0, -2)}xx` })).status).toBe(401);
      const issued = await exchange({});
      expect(issued.status).toBe(200);
      expect(await issued.json()).toMatchObject({ token_type: "Bearer", scope: "food:read" });
      expect((await exchange({})).status).toBe(400);
    } finally { db.close(); }
  });
});

describe("6. Webhook delivery", () => {
  it.each([
    "https://evil.example/hook", "http://chatgpt.com/hook", "https://chatgpt.com.evil.example/hook",
    "https://chatgpt.com:8443/hook", "https://user:pass@chatgpt.com/hook",
  ])("refuses callback %s before contacting it", async (url) => {
    const fetch = vi.fn();
    vi.stubGlobal("fetch", fetch);
    const subscribe = subscribeWebhookEvent({} as Env, principal("alice", "mcp"), {
      name: "food.logged", delivery: { mode: "webhook", url, secret: `whsec_${btoa("k".repeat(32))}` } });
    await expect(subscribe).rejects.toBeInstanceOf(McpEventsError);
    expect(fetch).not.toHaveBeenCalled();
  });
});

describe("7. Bounded inputs", () => {
  it("refuses oversized JSON bodies and over-long fields", async () => {
    const { db, env } = twoTenants();
    try {
      const post = (body: string) => routeApi(new Request(`${origin}/v1/foods`, { method: "POST", body }), env, principal("alice"));
      expect((await post("x".repeat(16001))).status).toBe(413);
      expect((await post(JSON.stringify({ name: "n".repeat(121), serving: "1", kcal: 1 }))).status).toBe(400);
      expect((await post(JSON.stringify({ name: "Ok", serving: "1", kcal: 5001 }))).status).toBe(400);
    } finally { db.close(); }
  });
});
