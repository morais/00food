/// <reference types="node" />
import { DatabaseSync } from "node:sqlite";
import { afterEach, describe, expect, it, vi } from "vitest";
import { listMcpConnections } from "../src/mcpConnections";
import type { Env } from "../src/api";
import type { Principal } from "../src/auth";

afterEach(() => vi.useRealTimers());

describe("agent connection event status", () => {
  it("reports only unexpired subscriptions belonging to each active account connection", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-10-07T12:00:00Z"));
    const db = new DatabaseSync(":memory:");
    try {
      db.exec(`CREATE TABLE credentials (id TEXT, label TEXT, scopes TEXT, created_at TEXT,
        last_used_at TEXT, expires_at TEXT, tenant_id TEXT, kind TEXT, revoked_at TEXT, token_hash TEXT);
        CREATE TABLE mcp_event_subscriptions (tenant_id TEXT, token_hash TEXT, name TEXT, expires_at TEXT);`);
      const credential = db.prepare("INSERT INTO credentials VALUES (?, ?, 'food:read food:write', '2026-10-01', NULL, ?, ?, ?, ?, ?)");
      credential.run("connected", "MCP · ChatGPT", "2026-11-01", "account", "mcp", null, "token-a");
      credential.run("unsubscribed", "Other agent", "2026-11-01", "account", "mcp", null, "token-b");
      credential.run("revoked", "Revoked", "2026-11-01", "account", "mcp", "2026-10-06", "token-c");
      credential.run("expired", "Expired", "2026-10-01", "account", "mcp", null, "token-d");
      credential.run("other-account", "Private", "2026-11-01", "other", "mcp", null, "token-e");
      credential.run("app", "App credential", "2026-11-01", "account", "app", null, "token-f");
      const subscription = db.prepare("INSERT INTO mcp_event_subscriptions VALUES (?, ?, ?, ?)");
      subscription.run("account", "token-a", "food.estimate_requested", "2026-10-08");
      subscription.run("account", "token-a", "food.estimate_requested", "2026-10-09");
      subscription.run("account", "token-a", "food.clarification_added", "2026-10-08");
      subscription.run("account", "token-a", "day.feedback_requested", "2026-10-07T12:00:00.000Z");
      subscription.run("other", "token-a", "food.logged", "2026-10-08");
      subscription.run("account", "token-b", "food.logged", "2026-10-06");
      const env = { DB: { prepare(sql: string) {
        return { bind(...args: string[]) { return { async all() {
          return { results: db.prepare(sql).all(...args) };
        } }; } };
      } } as unknown as D1Database } as Env;
      const principal: Principal = { tenantId: "account", kind: "app", tokenHash: "token-f", scopes: [] };
      const response = await listMcpConnections(env, principal);
      const result = await response.json() as { connections: { id: string; clientName: string; activeEvents: string[] }[] };
      expect(result.connections).toHaveLength(2);
      expect(result.connections.find(c => c.id === "connected")).toMatchObject({ clientName: "ChatGPT",
        activeEvents: ["food.clarification_added", "food.estimate_requested"] });
      expect(result.connections.find(c => c.id === "unsubscribed")?.activeEvents).toEqual([]);
      expect(JSON.stringify(result)).not.toContain("token-a");
    } finally { db.close(); }
  });

  it("does not expose account connection status to an MCP credential", async () => {
    const response = await listMcpConnections({} as Env,
      { tenantId: "account", kind: "mcp", tokenHash: "hash", scopes: ["food:read"] });
    expect(response.status).toBe(403);
  });
});
