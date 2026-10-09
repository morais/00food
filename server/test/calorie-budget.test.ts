import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { calorieBudget, percentFromLegacyKcal } from "../src/calorieBudget";
import { routeApi, type Env } from "../src/api";
import { dailyFeedbackContext, type DailyFeedbackRow } from "../src/dailyFeedback";
import { migratedD1, migrationsDir } from "./d1";
import type { Principal } from "../src/auth";
const principal: Principal = { tenantId: "tenant", kind: "app", scopes: [], tokenHash: "hash" };
const now = "2026-10-09T00:00:00Z";
const seed = (db: ReturnType<typeof migratedD1>["db"], id = "tenant") =>
  db.prepare("INSERT INTO tenants (id, apple_subject, created_at, updated_at) VALUES (?, ?, ?, ?)").run(id, id, now, now);

describe("percentage budgets", () => {
  it("scales all energy including exercise and preserves Maintain", () => {
    for (const [percent, allowance] of [[0, 2500], [10, 2250], [15, 2125], [20, 2000]]) {
      expect(calorieBudget(1800, 700, percent)).toEqual({ tdeeKcal: 2500, deficitPercent: percent,
        allowanceKcal: allowance, gapKcal: 2500 - allowance });
    }
    expect(calorieBudget(1800, 800, 20).allowanceKcal).toBe(2080);
    expect(calorieBudget(1400, 0, 20).allowanceKcal).toBe(1120);
  });
  it("migrates pace selections and invalidates cached snapshots", () => {
    const { db } = migratedD1("0014_percentage_deficits.sql");
    try {
      for (const old of [0, 300, 450, 600, 374, 375, 524, 525]) {
        seed(db, String(old));
        db.prepare(`INSERT INTO profiles (tenant_id, height_cm, weight_kg, estimate_profile, deficit_kcal, updated_at)
          VALUES (?, 175, 80, 'male', ?, ?)`).run(String(old), old, now);
      }
      db.exec(readFileSync(join(migrationsDir, "0014_percentage_deficits.sql"), "utf8"));
      for (const old of [0, 300, 450, 600, 374, 375, 524, 525]) {
        expect(db.prepare("SELECT deficit_percent FROM profiles WHERE tenant_id = ?").get(String(old))?.deficit_percent)
          .toBe(percentFromLegacyKcal(old));
        expect(db.prepare("SELECT data_version FROM tenants WHERE id = ?").get(String(old))?.data_version).toBe(2);
      }
    } finally { db.close(); }
  });
  it("accepts percentage and legacy queued profiles, rejects other percentages", async () => {
    const { db, d1 } = migratedD1();
    try {
      seed(db);
      const env = { DB: d1, PUBLIC_ORIGIN: "https://api.00food.com" } as Env;
      const put = (plan: object) => routeApi(new Request("https://api.00food.com/v1/profile", {
        method: "PUT", body: JSON.stringify({ heightCm: 175, weightKg: 80, estimateProfile: "male", ...plan }),
      }), env, principal);
      for (const [percent, old] of [[0, 0], [10, 300], [15, 450], [20, 600]]) {
        const response = await put({ deficitPercent: percent });
        expect(response.status).toBe(200);
        expect(await response.json()).toMatchObject({ profile: { deficitPercent: percent, deficitKcal: old } });
      }
      expect(await (await put({ deficitKcal: 450 })).json()).toMatchObject({ profile: { deficitPercent: 15 } });
      expect(await (await put({ deficitPercent: 10, deficitKcal: 600 })).json())
        .toMatchObject({ profile: { deficitPercent: 10, deficitKcal: 300 } });
      expect((await put({ deficitPercent: 300 })).status).toBe(400);
      expect((await put({})).status).toBe(400);
      const snapshot = await routeApi(new Request("https://api.00food.com/v1/snapshot"), env, principal);
      expect(await snapshot.json()).toMatchObject({ profile: { deficitPercent: 10 } });
    } finally { db.close(); }
  });
  it("supplies agent budgets without inventing missing energy", async () => {
    const { db, d1 } = migratedD1();
    try {
      seed(db);
      db.prepare(`INSERT INTO profiles (tenant_id, height_cm, weight_kg, estimate_profile, deficit_kcal, deficit_percent, updated_at)
        VALUES ('tenant', 175, 80, 'male', 600, 20, ?)`).run(now);
      const row: DailyFeedbackRow = { id: "request", tenant_id: "tenant", local_date: "2026-10-08", time_zone: "Europe/Lisbon",
        health_json: JSON.stringify([{ localDate: "2026-10-08", restingKcal: 1800, activeKcal: 700 },
          { localDate: "2026-10-07", restingKcal: 1800 }]), state: "pending", feedback_text: null, created_at: now, updated_at: now };
      const context = await dailyFeedbackContext({ DB: d1 } as Env, row);
      expect(context.currentPlanDeficitPercent).toBe(20);
      expect(context.days.find(day => day.localDate === "2026-10-08")?.calorieBudget).toEqual({
        tdeeKcal: 2500, deficitPercent: 20, allowanceKcal: 2000, gapKcal: 500 });
      expect(context.days.find(day => day.localDate === "2026-10-07")?.calorieBudget).toBeNull();
      expect(context.reviewGuidance.join(" ")).toContain("including exercise");
    } finally { db.close(); }
  });
});
