import { describe, expect, it } from "vitest";
import { routeApi, type Env } from "../src/api";
import type { Principal } from "../src/auth";

describe("offline log replay", () => {
  it("keeps the original time and does not count a retried log twice", async () => {
    const foodId = "c5f84159-41d0-495e-947d-18c2238db9b3";
    const logId = "a4d491d0-6787-4920-983a-ec8ec1b7319b";
    const loggedAt = "2026-10-03T19:10:00Z";
    const food = { id: foodId, name: "Rice bowl", serving: "1 bowl", kcal: 540, source: "manual",
      use_count: 0, last_used_at: null as string | null, dismissed_at: null,
      created_at: loggedAt, updated_at: loggedAt };
    let log: Record<string, unknown> | null = null;
    let eventCount = 0;
    const db = {
      prepare(sql: string) {
        return {
          bind(...args: unknown[]) {
            return {
              async first<T>(): Promise<T | null> {
                if (sql.startsWith("SELECT * FROM foods")) return food as T;
                if (sql.startsWith("SELECT * FROM food_logs")) return log as T | null;
                if (sql.startsWith("SELECT COUNT(*) AS n FROM food_logs")) return { n: log ? 1 : 0 } as T;
                throw new Error(`Unexpected SELECT: ${sql}`);
              },
              async run() {
                if (sql.startsWith("INSERT OR IGNORE INTO food_logs")) {
                  if (log) return { meta: { changes: 0 } };
                  log = { id: args[0], food_id: args[2], food_name: args[3], serving: args[4],
                    quantity: args[5], kcal: args[6], local_date: args[7], logged_at: args[8] };
                  return { meta: { changes: 1 } };
                }
                if (sql.startsWith("UPDATE foods SET use_count")) {
                  food.use_count += 1;
                  food.last_used_at = args[1] as string;
                  return { meta: { changes: 1 } };
                }
                if (sql.startsWith("INSERT OR IGNORE INTO food_events")) {
                  const inserted = eventCount === 0;
                  if (inserted) eventCount++;
                  return { meta: { changes: inserted ? 1 : 0 } };
                }
                throw new Error(`Unexpected write: ${sql}`);
              },
            };
          },
        };
      },
    };
    const env = { DB: db as unknown as D1Database, PUBLIC_ORIGIN: "https://api.00food.com" } as Env;
    const principal: Principal = { tenantId: "tenant", kind: "app", scopes: ["food:read", "food:write"], tokenHash: "hash" };
    const request = () => new Request("https://api.00food.com/v1/logs", { method: "POST",
      body: JSON.stringify({ id: logId, foodId, quantity: 1, localDate: "2026-10-03", loggedAt }) });

    const first = await routeApi(request(), env, principal);
    const retry = await routeApi(request(), env, principal);
    expect(first.status).toBe(201);
    expect(retry.status).toBe(201);
    expect((await first.json() as { log: { loggedAt: string } }).log.loggedAt).toBe(loggedAt);
    expect(food.use_count).toBe(1);
    expect(food.last_used_at).toBe(loggedAt);
    expect(eventCount).toBe(1);
    expect((log as unknown as Record<string, unknown>)["local_date"]).toBe("2026-10-03");
  });
});
