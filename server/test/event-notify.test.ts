import { describe, expect, it } from "vitest";
import { routeApi, type Env } from "../src/api";
import type { Principal } from "../src/auth";
import { migratedD1 } from "./d1";

const principal: Principal = { tenantId: "tenant", kind: "app", scopes: [], tokenHash: "hash" };
const now = "2026-01-01T00:00:00.000Z";
const foodId = "c5f84159-41d0-495e-947d-18c2238db9b3";

function setup(agent: "none" | "webhook" | "stream") {
  const { db, d1 } = migratedD1();
  db.prepare("INSERT INTO tenants (id, apple_subject, email, created_at, updated_at) VALUES ('tenant', 'a', NULL, ?, ?)").run(now, now);
  db.prepare(`INSERT INTO foods (id, tenant_id, name, serving, kcal, source, created_at, updated_at)
    VALUES (?, 'tenant', 'Toast', '1 slice', 90, 'manual', ?, ?)`).run(foodId, now, now);
  if (agent !== "none") {
    db.prepare(`INSERT INTO credentials (token_hash, id, tenant_id, kind, audience, scopes, label, created_at, expires_at)
      VALUES ('agent', 'c', 'tenant', 'mcp', 'aud', 'food:read', 'MCP', ?, '2999-01-01')`).run(now);
  }
  if (agent === "webhook") {
    db.prepare(`INSERT INTO mcp_event_subscriptions (id, tenant_id, token_hash, name, arguments_json, callback_url,
      signing_secret, expires_at, created_at, updated_at) VALUES ('sub', 'tenant', 'agent', 'food.logged', '{}',
      'https://chatgpt.com/x', 'whsec_x', '2999-01-01', ?, ?)`).run(now, now);
  }
  if (agent === "stream") {
    db.prepare("INSERT INTO mcp_resource_subscriptions VALUES ('agent', 'tenant', 'food://events', ?)").run(now);
  }
  const wakes: Array<{ path: string; deliver: string | null }> = [];
  const events = { getByName: () => ({ async fetch(url: string, init: RequestInit) {
    wakes.push({ path: new URL(url).pathname, deliver: new Headers(init.headers).get("x-deliver") });
    return new Response(null, { status: 204 });
  } }) } as unknown as DurableObjectNamespace;
  const env = { DB: d1, FOOD_EVENTS: events, PUBLIC_ORIGIN: "https://api.00food.com" } as Env;
  const log = () => routeApi(new Request("https://api.00food.com/v1/logs", { method: "POST",
    body: JSON.stringify({ id: "a4d491d0-6787-4920-983a-ec8ec1b7319b", foodId, localDate: "2026-10-08" }) }), env, principal);
  return { db, wakes, log };
}

describe("food event notifications", () => {
  it("do not wake the event object for an account without an agent", async () => {
    const { db, wakes, log } = setup("none");
    try {
      expect((await log()).status).toBe(201);
      expect(wakes).toEqual([]);
    } finally { db.close(); }
  });

  it("wake it with an alarm when a webhook delivery was queued, once per event", async () => {
    const { db, wakes, log } = setup("webhook");
    try {
      await log();
      await log();
      expect(wakes).toEqual([{ path: "/publish", deliver: "true" }]);
    } finally { db.close(); }
  });

  it("wake it without an alarm for a stream subscriber", async () => {
    const { db, wakes, log } = setup("stream");
    try {
      await log();
      expect(wakes).toEqual([{ path: "/publish", deliver: "false" }]);
    } finally { db.close(); }
  });
});
