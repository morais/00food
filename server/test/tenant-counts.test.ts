/// <reference types="node" />
import { describe, expect, it } from "vitest";
import { routeApi, type Env } from "../src/api";
import type { Principal } from "../src/auth";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { migratedD1, migrationsDir } from "./d1";

const principal: Principal = { tenantId: "tenant", kind: "app", scopes: [], tokenHash: "hash" };
const now = "2026-10-08T00:00:00Z";

describe("per-account row counts", () => {
  it("track inserts and deletes on every path, including accept", async () => {
    const { db, d1 } = migratedD1();
    try {
      db.prepare("INSERT INTO tenants (id, apple_subject, email, created_at, updated_at) VALUES ('tenant', 'a', NULL, ?, ?)").run(now, now);
      const env = { DB: d1, PUBLIC_ORIGIN: "https://api.00food.com" } as Env;
      const call = (method: string, path: string, body?: unknown) => routeApi(new Request(`https://api.00food.com${path}`,
        { method, body: body ? JSON.stringify(body) : undefined }), env, principal);
      const counts = () => db.prepare("SELECT food_count, log_count, estimate_count FROM tenants").get();

      const food = (await (await call("POST", "/v1/foods", { name: "Toast", serving: "1 slice", kcal: 90 })).json() as
        { food: { id: string } }).food.id;
      const log = (await (await call("POST", "/v1/logs", { foodId: food, localDate: "2026-10-08" })).json() as
        { log: { id: string } }).log.id;
      const estimate = (await (await call("POST", "/v1/estimations", { description: "Soup", localDate: "2026-10-08" })).json() as
        { estimation: { id: string } }).estimation.id;
      expect(counts()).toEqual({ food_count: 1, log_count: 1, estimate_count: 1 });

      db.prepare(`UPDATE pending_estimations SET state = 'proposed', proposed_name = 'Soup', proposed_serving = '1 bowl',
        proposed_kcal = 200`).run();
      expect((await call("POST", `/v1/estimations/${estimate}/accept`)).status).toBe(200);
      expect(counts()).toEqual({ food_count: 2, log_count: 2, estimate_count: 0 });

      expect((await call("DELETE", `/v1/logs/${log}`)).status).toBe(200);
      expect(counts()).toEqual({ food_count: 2, log_count: 1, estimate_count: 0 });
    } finally { db.close(); }
  });

  it("enforce the review-queue limit from the counter", async () => {
    const { db, d1 } = migratedD1();
    try {
      db.prepare(`INSERT INTO tenants (id, apple_subject, email, created_at, updated_at, estimate_count)
        VALUES ('tenant', 'a', NULL, ?, ?, 100)`).run(now, now);
      const response = await routeApi(new Request("https://api.00food.com/v1/estimations", { method: "POST",
        body: JSON.stringify({ description: "Soup", localDate: "2026-10-08" }) }),
      { DB: d1, PUBLIC_ORIGIN: "https://api.00food.com" } as Env, principal);
      expect(response.status).toBe(403);
    } finally { db.close(); }
  });

  it("backfills existing accounts when the migration runs", async () => {
    const { db } = migratedD1("0010_tenant_row_counts.sql");
    try {
      db.prepare("INSERT INTO tenants VALUES ('tenant', 'a', NULL, ?, ?)").run(now, now);
      for (const id of ["f1", "f2"]) {
        db.prepare(`INSERT INTO foods (id, tenant_id, name, serving, kcal, source, created_at, updated_at)
          VALUES (?, 'tenant', 'Toast', '1 slice', 90, 'manual', ?, ?)`).run(id, now, now);
      }
      db.prepare(`INSERT INTO food_logs (id, tenant_id, food_id, food_name, serving, quantity, kcal, local_date, logged_at)
        VALUES ('l1', 'tenant', 'f1', 'Toast', '1 slice', 1, 90, '2026-10-08', ?)`).run(now);
      db.exec(readFileSync(join(migrationsDir, "0010_tenant_row_counts.sql"), "utf8"));
      expect(db.prepare("SELECT food_count, log_count, estimate_count FROM tenants").get())
        .toEqual({ food_count: 2, log_count: 1, estimate_count: 0 });
    } finally { db.close(); }
  });
});
