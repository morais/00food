import { afterEach, describe, expect, it, vi } from "vitest";
import { apnsProviderToken, deliverAgentResponsePushes, routePushDevice } from "../src/agentResponsePush";
import { proposeEstimation, type Env } from "../src/api";
import { saveDailyFeedback } from "../src/dailyFeedback";
import { decodeBase64url, revokeCredential, type Principal } from "../src/auth";
import { migratedD1 } from "./d1";

const installation = "11111111-1111-4111-8111-111111111111";
const estimate = "22222222-2222-4222-8222-222222222222";
const feedback = "33333333-3333-4333-8333-333333333333";
const token = "a".repeat(64);
const principal: Principal = { tenantId: "tenant", kind: "app", scopes: [], tokenHash: "session" };
const keys = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
const exported = new Uint8Array(await crypto.subtle.exportKey("pkcs8", keys.privateKey));
const privateKey = `-----BEGIN PRIVATE KEY-----\n${Buffer.from(exported).toString("base64")}\n-----END PRIVATE KEY-----`;
afterEach(() => vi.unstubAllGlobals());

function setup() {
  const { db, d1 } = migratedD1();
  const now = new Date().toISOString();
  for (const tenant of ["tenant", "other"]) {
    db.prepare("INSERT INTO tenants (id, apple_subject, created_at, updated_at) VALUES (?, ?, ?, ?)").run(tenant, tenant, now, now);
    db.prepare(`INSERT INTO credentials (token_hash, id, tenant_id, kind, audience, scopes, label, created_at, expires_at)
      VALUES (?, ?, ?, 'app', 'aud', '', 'iPhone', ?, '2999-01-01')`).run(tenant === "tenant" ? "session" : "other-session", tenant, tenant, now);
  }
  db.prepare(`INSERT INTO pending_estimations (id, tenant_id, description, state, local_date, created_at, updated_at)
    VALUES (?, 'tenant', 'Soup', 'pending', '2026-10-09', ?, ?)`).run(estimate, now, now);
  db.prepare(`INSERT INTO daily_feedback_requests (id, tenant_id, local_date, time_zone, health_json, state, created_at, updated_at)
    VALUES (?, 'tenant', '2026-10-08', 'UTC', '[]', 'pending', ?, ?)`).run(feedback, now, now);
  const wakes: string[] = [];
  const env = { DB: d1, PUBLIC_ORIGIN: "https://api.00food.com", APPLE_APP_CLIENT_ID: "com.00food.app",
    APPLE_TEAM_ID: "TEAM", APNS_KEY_ID: "KEY", APNS_PRIVATE_KEY: privateKey,
    FOOD_EVENTS: { getByName: (tenant: string) => ({ async fetch(url: string) {
      wakes.push(`${tenant}:${new URL(url).pathname}`); return new Response(null, { status: 204 });
    } }) } } as unknown as Env;
  const register = (p = principal, deviceToken = token, environment = "production") => routePushDevice(
    new Request("https://api.00food.com/v1/push/device", { method: "PUT", body: JSON.stringify({ installationId: installation, deviceToken, environment }) }), env, p);
  const propose = (kcal = 200) => proposeEstimation(env, "tenant", estimate, { name: "Soup", serving: "1 bowl", kcal, reasoning: "A medium serving" });
  return { db, env, wakes, register, propose };
}

describe("silent agent response pushes", () => {
  it("queues food, clarification and daily replies atomically, but not identical retries or requests without devices", async () => {
    const { db, register, propose, env, wakes } = setup();
    try {
      await propose();
      expect(db.prepare("SELECT * FROM push_pending").all()).toHaveLength(0);
      await register();
      await propose(220);
      const first = db.prepare("SELECT version FROM push_pending").get()!.version;
      await propose(220);
      expect(db.prepare("SELECT version FROM push_pending").get()!.version).toBe(first);
      db.prepare("UPDATE pending_estimations SET state = 'pending', user_clarification = 'Smaller bowl' WHERE id = ?").run(estimate);
      await propose(150);
      expect(db.prepare("SELECT version FROM push_pending").get()!.version).not.toBe(first);
      await saveDailyFeedback(env, "tenant", feedback, "A balanced day.");
      expect(db.prepare("SELECT * FROM push_pending").all()).toHaveLength(1);
      expect(wakes.every(value => value === "tenant:/publish-response")).toBe(true);
    } finally { db.close(); }
  });

  it("binds registrations to live app sessions, transfers a device on account switch, and removes it at sign-out", async () => {
    const { db, register, env } = setup();
    try {
      expect((await register({ ...principal, kind: "mcp" })).status).toBe(403);
      await register();
      await register({ ...principal, tenantId: "other", tokenHash: "other-session" });
      expect(db.prepare("SELECT tenant_id FROM push_devices").all()).toEqual([{ tenant_id: "other" }]);
      await revokeCredential(env, { ...principal, tenantId: "other", tokenHash: "other-session" });
      expect(db.prepare("SELECT * FROM push_devices").all()).toHaveLength(0);
      expect((await register({ ...principal, tenantId: "other", tokenHash: "other-session" })).status).toBe(401);
      expect((await register(principal, "not-a-token")).status).toBe(400);
    } finally { db.close(); }
  });

  it("uses ES256 with the correct team and reuses the provider token", async () => {
    const config = { keyId: "VERIFY", privateKey, teamId: "TEAM", topic: "com.00food.app" };
    const jwt = await apnsProviderToken(config);
    const parts = jwt.split(".");
    expect(JSON.parse(new TextDecoder().decode(decodeBase64url(parts[0])))).toEqual({ alg: "ES256", kid: "VERIFY" });
    expect(JSON.parse(new TextDecoder().decode(decodeBase64url(parts[1]))).iss).toBe("TEAM");
    expect(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, keys.publicKey,
      new Uint8Array(decodeBase64url(parts[2])), new TextEncoder().encode(`${parts[0]}.${parts[1]}`))).toBe(true);
    expect(await apnsProviderToken(config)).toBe(jwt);
  });

  it("sends only a background signal, coalesces follow-up replies and never repeats already accepted deliveries during retries", async () => {
    const { db, register, propose, env } = setup();
    try {
      await register(); await propose();
      const sent = vi.fn(async () => new Response(null, { status: 200 })); vi.stubGlobal("fetch", sent);
      const now = Date.now();
      expect(await deliverAgentResponsePushes(env, "tenant", now)).toBeNull();
      const [url, init] = sent.mock.calls[0] as unknown as [string, RequestInit];
      expect(url).toBe(`https://api.push.apple.com/3/device/${token}`);
      const headers = new Headers(init.headers);
      expect(headers.get("apns-push-type")).toBe("background");
      expect(headers.get("apns-priority")).toBe("5");
      expect(headers.get("apns-topic")).toBe("com.00food.app");
      expect(JSON.parse(String(init.body))).toEqual({ aps: { "content-available": 1 }, foodSync: true });
      await propose(240);
      expect(await deliverAgentResponsePushes(env, "tenant", now + 1000)).toBe(now + 20 * 60000);
      expect(sent).toHaveBeenCalledTimes(1);
      expect(await deliverAgentResponsePushes(env, "tenant", now + 20 * 60000)).toBeNull();
      expect(sent).toHaveBeenCalledTimes(2);
      expect(db.prepare("SELECT * FROM push_pending").all()).toHaveLength(0);
    } finally { db.close(); }
  });

  it("retries transient failures, retains devices for provider errors, and removes invalid Apple device tokens", async () => {
    const { db, register, propose, env } = setup();
    try {
      await register(); await propose();
      const now = Date.now();
      vi.stubGlobal("fetch", vi.fn(async () => Response.json({ reason: "InvalidProviderToken" }, { status: 403 })));
      expect(await deliverAgentResponsePushes(env, "tenant", now)).toBe(now + 30000);
      expect(db.prepare("SELECT * FROM push_devices").all()).toHaveLength(1);
      vi.stubGlobal("fetch", vi.fn(async () => Response.json({ reason: "Unregistered" }, { status: 410 })));
      expect(await deliverAgentResponsePushes(env, "tenant", now + 30000)).toBeNull();
      expect(db.prepare("SELECT * FROM push_devices").all()).toHaveLength(0);
    } finally { db.close(); }
  });

  it("does not lose a response arriving during an in-flight push", async () => {
    const { db, register, propose, env } = setup();
    try {
      await register(); await propose();
      vi.stubGlobal("fetch", vi.fn(async () => { await propose(350); return new Response(null, { status: 200 }); }));
      expect(await deliverAgentResponsePushes(env, "tenant")).not.toBeNull();
      expect(db.prepare("SELECT * FROM push_pending").all()).toHaveLength(1);
      const pending = db.prepare("SELECT version FROM push_pending").get()!.version;
      expect(db.prepare("SELECT delivered_version FROM push_devices").get()!.delivered_version).not.toBe(pending);
    } finally { db.close(); }
  });

  it("never resends an accepted device while another device's delivery retries", async () => {
    const { db, register, propose, env } = setup();
    try {
      await register();
      const second = token.replaceAll("a", "b");
      await routePushDevice(new Request("https://api.00food.com/v1/push/device", { method: "PUT",
        body: JSON.stringify({ installationId: "44444444-4444-4444-8444-444444444444", deviceToken: second, environment: "production" }) }), env, principal);
      await propose();
      const now = Date.now();
      const sent = vi.fn(async (url: string) => url.endsWith(token) ? new Response(null, { status: 200 }) : Response.json({}, { status: 500 }));
      vi.stubGlobal("fetch", sent);
      expect(await deliverAgentResponsePushes(env, "tenant", now)).toBe(now + 30000);
      await deliverAgentResponsePushes(env, "tenant", now + 30000);
      expect(sent.mock.calls.filter(([url]) => url.endsWith(token))).toHaveLength(1);
      expect(sent.mock.calls.filter(([url]) => url.endsWith(second))).toHaveLength(2);
    } finally { db.close(); }
  });

  it("does not deliver to an expired session or a different account", async () => {
    const { db, register, propose, env } = setup();
    try {
      await register(); await propose();
      db.prepare("UPDATE credentials SET expires_at = '2000-01-01' WHERE token_hash = 'session'").run();
      const sent = vi.fn(); vi.stubGlobal("fetch", sent);
      expect(await deliverAgentResponsePushes(env, "tenant")).toBeNull();
      expect(await deliverAgentResponsePushes(env, "other")).toBeNull();
      expect(sent).not.toHaveBeenCalled();
      await propose(400);
      expect(db.prepare("SELECT * FROM push_pending").all()).toHaveLength(0);
    } finally { db.close(); }
  });
});
