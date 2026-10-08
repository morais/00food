import { describe, expect, it } from "vitest";
import { routeApi, type Env } from "../src/api";
import type { Principal } from "../src/auth";
import { migratedD1 } from "./d1";

describe("offline log replay", () => {
  it("keeps the original time and does not count a retried log twice", async () => {
    const foodId = "c5f84159-41d0-495e-947d-18c2238db9b3";
    const logId = "a4d491d0-6787-4920-983a-ec8ec1b7319b";
    const loggedAt = "2026-10-03T19:10:00Z";
    const { db, d1 } = migratedD1();
    try {
      db.prepare("INSERT INTO tenants VALUES ('tenant', 'apple', NULL, ?, ?)").run(loggedAt, loggedAt);
      db.prepare(`INSERT INTO foods (id, tenant_id, name, serving, kcal, fruit_veg_portions, source, created_at, updated_at)
        VALUES (?, 'tenant', 'Rice bowl', '1 bowl', 540, 2, 'manual', ?, ?)`).run(foodId, loggedAt, loggedAt);
      const env = { DB: d1, PUBLIC_ORIGIN: "https://api.00food.com" } as Env;
      const principal: Principal = { tenantId: "tenant", kind: "app", scopes: ["food:read", "food:write"], tokenHash: "hash" };
      const request = () => new Request("https://api.00food.com/v1/logs", { method: "POST",
        body: JSON.stringify({ id: logId, foodId, quantity: 1, localDate: "2026-10-03", loggedAt }) });

      const first = await routeApi(request(), env, principal);
      const retry = await routeApi(request(), env, principal);
      expect(first.status).toBe(201);
      expect(retry.status).toBe(201);
      expect((await first.json() as { log: { loggedAt: string } }).log.loggedAt).toBe(loggedAt);
      expect(db.prepare("SELECT use_count, last_used_at FROM foods").get())
        .toEqual({ use_count: 1, last_used_at: loggedAt });
      expect(db.prepare("SELECT COUNT(*) AS n FROM food_events").get()).toEqual({ n: 1 });
      expect(db.prepare("SELECT local_date, fruit_veg_portions FROM food_logs").get())
        .toEqual({ local_date: "2026-10-03", fruit_veg_portions: 2 });
    } finally { db.close(); }
  });

  it("refuses a log ID that already belongs to another account", async () => {
    const { db, d1 } = migratedD1();
    try {
      const now = "2026-10-03T19:10:00Z";
      const foods = { tenant: "d1f84159-41d0-495e-947d-18c2238db9b3", other: "e2f84159-41d0-495e-947d-18c2238db9b3" };
      for (const [tenant, food] of Object.entries(foods)) {
        db.prepare("INSERT INTO tenants VALUES (?, ?, NULL, ?, ?)").run(tenant, `apple-${tenant}`, now, now);
        db.prepare(`INSERT INTO foods (id, tenant_id, name, serving, kcal, source, created_at, updated_at)
          VALUES (?, ?, 'Toast', '1 slice', 90, 'manual', ?, ?)`).run(food, tenant, now, now);
      }
      const logId = "b4d491d0-6787-4920-983a-ec8ec1b7319b";
      db.prepare(`INSERT INTO food_logs (id, tenant_id, food_id, food_name, serving, quantity, kcal, local_date, logged_at)
        VALUES (?, 'other', ?, 'Toast', '1 slice', 1, 90, '2026-10-03', ?)`).run(logId, foods.other, now);
      const env = { DB: d1, PUBLIC_ORIGIN: "https://api.00food.com" } as Env;
      const principal: Principal = { tenantId: "tenant", kind: "app", scopes: [], tokenHash: "hash" };
      const response = await routeApi(new Request("https://api.00food.com/v1/logs", { method: "POST",
        body: JSON.stringify({ id: logId, foodId: foods.tenant, localDate: "2026-10-03" }) }), env, principal);
      expect(response.status).toBe(409);
      expect(db.prepare("SELECT use_count FROM foods WHERE tenant_id = 'tenant'").get()).toEqual({ use_count: 0 });
    } finally { db.close(); }
  });
});
