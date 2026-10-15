import { describe, expect, it } from "vitest";
import { dailyFeedbackContext, dailyFeedbackInput, type DailyFeedbackRow } from "../src/dailyFeedback";
import type { Env } from "../src/api";
import { migratedD1 } from "./d1";

describe("daily review intake context", () => {
  it("accepts optional workout summaries but rejects unrelated metrics and invalid intervals", () => {
    const workout = { id: crypto.randomUUID(), activity: "Running", startedAt: "2026-10-08T07:00:00Z",
      endedAt: "2026-10-08T07:30:00Z", durationMinutes: 30, activeKcal: 300, distanceMeters: 5000 };
    const input = (extra = {}) => ({ id: crypto.randomUUID(), localDate: "2026-10-08", timeZone: "UTC",
      healthDays: [{ localDate: "2026-10-08", workouts: [{ ...workout, ...extra }] }] });
    expect(dailyFeedbackInput.parse(input()).healthDays[0].workouts).toEqual([workout]);
    expect(dailyFeedbackInput.safeParse(input({ heartRate: 150 })).success).toBe(false);
    expect(dailyFeedbackInput.safeParse(input({ endedAt: "2026-10-08T06:00:00Z" })).success).toBe(false);
    expect(dailyFeedbackInput.safeParse(input({ durationMinutes: -1 })).success).toBe(false);
  });
  it("defaults older requests to metric and validates preferred display units", () => {
    const request = { id: crypto.randomUUID(), localDate: "2026-10-09", timeZone: "UTC", healthDays: [] };
    expect(dailyFeedbackInput.parse(request).displayUnits).toBe("metric");
    expect(dailyFeedbackInput.parse({ ...request, displayUnits: "uk" }).displayUnits).toBe("uk");
    expect(dailyFeedbackInput.safeParse({ ...request, displayUnits: "invalid" }).success).toBe(false);
    expect(dailyFeedbackInput.parse(request).userInstructions).toBe("");
    expect(dailyFeedbackInput.parse({ ...request, userInstructions: "  Keep it brief.\n " }).userInstructions).toBe("Keep it brief.");
    expect(dailyFeedbackInput.safeParse({ ...request, userInstructions: "x".repeat(2001) }).success).toBe(false);
  });
  it("distinguishes goal completion from exact intake, preserves water above 2 L and missing data", async () => {
    const { db, d1 } = migratedD1();
    try {
      const now = "2026-10-09T00:00:00Z";
      db.prepare("INSERT INTO tenants (id, apple_subject, created_at, updated_at) VALUES ('tenant', 'apple', ?, ?)").run(now, now);
      db.prepare(`INSERT INTO foods (id, tenant_id, name, serving, kcal, source, created_at, updated_at)
        VALUES ('food', 'tenant', 'Lentils and vegetables', '1 bowl', 400, 'agent', ?, ?)`).run(now, now);
      const insert = db.prepare(`INSERT INTO food_logs
        (id, tenant_id, food_id, food_name, serving, quantity, kcal, fruit_veg_portions, local_date, logged_at)
        VALUES (?, 'tenant', 'food', 'Lentils and vegetables', '1 bowl', 1, 400, ?, ?, ?)`);
      insert.run("below", 4, "2026-10-06", now);
      insert.run("goal", 5, "2026-10-07", now);
      insert.run("above1", 4, "2026-10-08", now);
      insert.run("above2", 4, "2026-10-08", now);
      db.prepare(`INSERT INTO pending_estimations (id, tenant_id, description, state, local_date, created_at, updated_at)
        VALUES ('pending', 'tenant', 'Dinner with fish', 'pending', '2026-10-08', ?, ?)`).run(now, now);
      const row: DailyFeedbackRow = { id: "request", tenant_id: "tenant", local_date: "2026-10-08",
        time_zone: "Europe/Lisbon", health_json: JSON.stringify([
          { localDate: "2026-10-06", waterMl: 1750 },
          { localDate: "2026-10-07", waterMl: 2000 },
          { localDate: "2026-10-08", waterMl: 2750 },
        ]), state: "pending", feedback_text: null, created_at: now, updated_at: now };
      const context = await dailyFeedbackContext({ DB: d1 } as Env, row);
      expect(context.userInstructions).toBe("");
      const day = (date: string) => context.days.find(day => day.localDate === date)!;
      expect(day("2026-10-06")).toMatchObject({ fruitVegPortions: 4,
        fruitVegPortionsQualifier: "logged_estimate", fruitVegGoalMet: false,
        waterIntakeAtLeastMl: 1750, waterGoalMet: false });
      expect(day("2026-10-07")).toMatchObject({ fruitVegPortions: 5,
        fruitVegPortionsQualifier: "at_least", fruitVegGoalMet: true,
        waterIntakeAtLeastMl: 2000, waterGoalMet: true });
      expect(day("2026-10-08")).toMatchObject({ fruitVegPortions: 5,
        fruitVegPortionsQualifier: "at_least", fruitVegGoalMet: true,
        waterIntakeAtLeastMl: 2750, waterGoalMet: true, health: { waterMl: 2750 },
        foodKcal: 800, pendingFoods: ["Dinner with fish"] });
      expect(day("2026-10-05")).toMatchObject({ health: null,
        waterIntakeAtLeastMl: null, waterGoalMet: null });
      // Review instructions travel with the context, even when a connected
      // agent still has an older copy of the tool descriptions.
      expect(context.reviewGuidance.join(" ")).toContain("protein sources");
      expect(context.reviewGuidance.join(" ")).toContain("Do not invent nutrient quantities");
      expect(context.reviewGuidance.join(" ")).toContain("clickable Markdown citations");
      expect(context.referenceSources).toEqual([
        { title: "WHO — Healthy diet", url: "https://www.who.int/news-room/fact-sheets/detail/healthy-diet" },
        { title: "NHS — 5 A Day portion sizes", url: "https://www.nhs.uk/live-well/eat-well/5-a-day/portion-sizes/" },
        { title: "EFSA — Dietary Reference Values for Water (2010)", url: "https://www.efsa.europa.eu/en/efsajournal/pub/1459" },
      ]);
      expect(day("2026-10-08").foods[0].name).toBe("Lentils and vegetables");
    } finally { db.close(); }
  });
});
