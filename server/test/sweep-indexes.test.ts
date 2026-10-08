import { describe, expect, it } from "vitest";
import { sweepExpiredAuthData } from "../src/cleanup";
import type { Env } from "../src/api";
import { migratedD1 } from "./d1";

describe("expired auth data sweep", () => {
  it("finds revoked credentials through an index instead of scanning", () => {
    const { db } = migratedD1();
    try {
      const plan = db.prepare("EXPLAIN QUERY PLAN DELETE FROM credentials WHERE revoked_at IS NOT NULL").all() as
        { detail: string }[];
      expect(plan.map(step => step.detail).join(" ")).toContain("credentials_revoked");
    } finally { db.close(); }
  });
});

describe("scheduled cleanup", () => {
  it("removes only rows that can never be used again", async () => {
    const { db, d1 } = migratedD1();
    try {
      const now = new Date("2026-10-08T03:17:00Z");
      db.prepare("INSERT INTO tenants (id, apple_subject, email, created_at, updated_at) VALUES ('t', 'a', NULL, '', '')").run();
      const credential = db.prepare(`INSERT INTO credentials (token_hash, id, tenant_id, kind, audience, scopes, label,
        created_at, expires_at, revoked_at) VALUES (?, ?, 't', 'mcp', 'aud', 'food:read', 'MCP', '', ?, ?)`);
      credential.run("live", "1", "2026-11-01T00:00:00Z", null);
      credential.run("expired", "2", "2026-10-01T00:00:00Z", null);
      credential.run("revoked", "3", "2026-11-01T00:00:00Z", "2026-10-07T00:00:00Z");
      const event = db.prepare(`INSERT INTO food_events (tenant_id, event_key, kind, subject_id, payload_json, created_at)
        VALUES ('t', ?, 'food_logged', 's', '{}', ?)`);
      event.run("recent", "2026-10-01T00:00:00Z");
      event.run("old", "2026-09-01T00:00:00Z");
      await sweepExpiredAuthData({ DB: d1 } as Env, now);
      expect(db.prepare("SELECT token_hash FROM credentials").all()).toEqual([{ token_hash: "live" }]);
      expect(db.prepare("SELECT event_key FROM food_events").all()).toEqual([{ event_key: "recent" }]);
    } finally { db.close(); }
  });
});
