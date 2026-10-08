import { describe, expect, it } from "vitest";
import { webhookDeliveryInsert } from "../src/mcpWebhookEvents";
import type { Env } from "../src/api";
import { migratedD1 } from "./d1";

describe("food event webhook scope", () => {
  it("queues food events only for connections that still hold food:read", async () => {
    const { db, d1 } = migratedD1();
    try {
      const past = "2026-01-01T00:00:00.000Z";
      db.prepare("INSERT INTO tenants VALUES ('tenant', 'apple', NULL, ?, ?)").run(past, past);
      const credential = db.prepare(`INSERT INTO credentials (token_hash, id, tenant_id, kind, audience, scopes, label,
        created_at, expires_at) VALUES (?, ?, 'tenant', 'mcp', 'aud', ?, 'MCP', ?, '2999-01-01')`);
      credential.run("food-token", "food", "food:read food:write", past);
      credential.run("daily-token", "daily", "daily:read daily:write", past);
      const subscription = db.prepare(`INSERT INTO mcp_event_subscriptions (id, tenant_id, token_hash, name,
        arguments_json, callback_url, signing_secret, expires_at, created_at, updated_at)
        VALUES (?, 'tenant', ?, 'food.logged', '{}', 'https://chatgpt.com/x', 'whsec_x', '2999-01-01', ?, ?)`);
      subscription.run("sub-food", "food-token", past, past);
      subscription.run("sub-daily", "daily-token", past, past);
      db.prepare(`INSERT INTO food_events (tenant_id, event_key, kind, subject_id, payload_json, created_at)
        VALUES ('tenant', 'log:1', 'food_logged', 'log-1', '{}', ?)`).run(new Date().toISOString());
      await webhookDeliveryInsert({ DB: d1 } as Env, "tenant", "log:1").run();
      const queued = db.prepare("SELECT subscription_id FROM mcp_event_deliveries").all() as { subscription_id: string }[];
      expect(queued.map(row => row.subscription_id)).toEqual(["sub-food"]);
    } finally { db.close(); }
  });
});
