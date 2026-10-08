import { describe, expect, it } from "vitest";
import { deleteTenantData } from "../src/appAuth";
import type { Env } from "../src/api";
import { migratedD1 } from "./d1";

function seed(db: ReturnType<typeof migratedD1>["db"], tenant: string): void {
  const now = "2026-10-08T00:00:00Z";
  const run = (sql: string, ...args: (string | number | null)[]) => db.prepare(sql).run(...args);
  run("INSERT INTO tenants (id, apple_subject, email, created_at, updated_at) VALUES (?, ?, NULL, ?, ?)", tenant, `apple-${tenant}`, now, now);
  run(`INSERT INTO credentials (token_hash, id, tenant_id, kind, audience, scopes, label, created_at, expires_at)
    VALUES (?, ?, ?, 'mcp', 'aud', 'food:read', 'MCP', ?, '2999-01-01')`, `hash-${tenant}`, `cred-${tenant}`, tenant, now);
  run("INSERT INTO review_credentials VALUES (?, ?, '2999-01-01', NULL)", `review-${tenant}`, tenant);
  run(`INSERT INTO oauth_flows (id_hash, client_id, client_name, redirect_uri, code_challenge, resource, scopes,
    apple_nonce, tenant_id, created_at, expires_at) VALUES (?, 'c', 'n', 'r', 'x', 'res', 's', 'n', ?, ?, '2999-01-01')`,
  `flow-${tenant}`, tenant, now);
  run(`INSERT INTO oauth_codes (code_hash, tenant_id, client_id, redirect_uri, code_challenge, resource, scopes, expires_at)
    VALUES (?, ?, 'c', 'r', 'x', 'res', 's', '2999-01-01')`, `code-${tenant}`, tenant);
  run(`INSERT INTO profiles (tenant_id, height_cm, weight_kg, estimate_profile, deficit_kcal, updated_at)
    VALUES (?, 170, 70, 'neutral', 300, ?)`, tenant, now);
  run(`INSERT INTO foods (id, tenant_id, name, serving, kcal, source, created_at, updated_at)
    VALUES (?, ?, 'Soup', '1 bowl', 200, 'manual', ?, ?)`, `food-${tenant}`, tenant, now, now);
  run(`INSERT INTO food_logs (id, tenant_id, food_id, food_name, serving, quantity, kcal, local_date, logged_at)
    VALUES (?, ?, ?, 'Soup', '1 bowl', 1, 200, '2026-10-08', ?)`, `log-${tenant}`, tenant, `food-${tenant}`, now);
  run(`INSERT INTO pending_estimations (id, tenant_id, description, state, local_date, created_at, updated_at)
    VALUES (?, ?, 'Salad', 'pending', '2026-10-08', ?, ?)`, `est-${tenant}`, tenant, now, now);
  const event = run(`INSERT INTO food_events (tenant_id, event_key, kind, subject_id, payload_json, created_at)
    VALUES (?, 'log:1', 'food_logged', 'log', '{}', ?)`, tenant, now);
  run(`INSERT INTO mcp_event_subscriptions (id, tenant_id, token_hash, name, arguments_json, callback_url,
    signing_secret, expires_at, created_at, updated_at) VALUES (?, ?, ?, 'food.logged', '{}', 'https://chatgpt.com/x',
    'whsec_x', '2999-01-01', ?, ?)`, `sub-${tenant}`, tenant, `hash-${tenant}`, now, now);
  run(`INSERT INTO mcp_event_deliveries (id, tenant_id, event_id, subscription_id, next_attempt_at)
    VALUES (?, ?, ?, ?, ?)`, `del-${tenant}`, tenant, Number(event.lastInsertRowid), `sub-${tenant}`, now);
  run(`INSERT INTO daily_feedback_requests (id, tenant_id, local_date, time_zone, health_json, state, created_at, updated_at)
    VALUES (?, ?, '2026-10-07', 'UTC', '[{"weightKg":70}]', 'pending', ?, ?)`, `daily-${tenant}`, tenant, now, now);
  run(`INSERT INTO daily_feedback_deliveries (id, tenant_id, request_id, subscription_id, next_attempt_at)
    VALUES (?, ?, ?, ?, ?)`, `ddel-${tenant}`, tenant, `daily-${tenant}`, `sub-${tenant}`, now);
}

describe("account deletion", () => {
  it("removes the account's rows from every table without relying on cascades", async () => {
    const { db, d1 } = migratedD1();
    try {
      seed(db, "gone");
      seed(db, "kept");
      // Cascades would hide a table missing from the explicit list.
      db.exec("PRAGMA foreign_keys = OFF");
      await deleteTenantData({ DB: d1 } as Env, "gone", "apple-gone");
      const tables = (db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
        .all() as { name: string }[]).map(row => row.name);
      for (const table of tables) {
        const columns = (db.prepare(`PRAGMA table_info(${table})`).all() as { name: string }[]).map(c => c.name);
        const column = table === "tenants" ? "id" : columns.includes("tenant_id") ? "tenant_id" : null;
        expect(column, `${table} has no tenant column`).not.toBeNull();
        const count = (tenant: string) =>
          (db.prepare(`SELECT COUNT(*) AS n FROM ${table} WHERE ${column} = ?`).get(tenant) as { n: number }).n;
        expect(count("gone"), table).toBe(0);
        expect(count("kept"), table).toBeGreaterThan(0);
      }
    } finally { db.close(); }
  });

  it("deletes every photo under the account prefix across pages", async () => {
    const { db, d1 } = migratedD1();
    try {
      const keys = ["gone/a.jpg", "gone/b.jpg", "gone/c.jpg"];
      const deleted: string[] = [];
      const photos = {
        async list({ cursor }: { cursor?: string }) {
          const start = Number(cursor ?? 0);
          const objects = keys.slice(start, start + 2).map(key => ({ key }));
          return { objects, truncated: start + 2 < keys.length, cursor: String(start + 2) };
        },
        async delete(batch: string[]) { deleted.push(...batch); },
      } as unknown as R2Bucket;
      await deleteTenantData({ DB: d1, PHOTOS: photos } as Env, "gone", "apple-gone");
      expect(deleted).toEqual(keys);
    } finally { db.close(); }
  });
});
