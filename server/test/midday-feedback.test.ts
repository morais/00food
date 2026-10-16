import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { routeApi, type Env } from "../src/api";
import type { Principal } from "../src/auth";
import { dailyFeedbackContext, dateBefore, localToday, saveDailyFeedback, type DailyFeedbackRow } from "../src/dailyFeedback";
import { migratedD1, migrationsDir } from "./d1";

const principal: Principal = { tenantId: "tenant", kind: "app", scopes: [], tokenHash: "app" };
function setup(before?: string) {
  const { db, d1 } = migratedD1(before);
  const now = "2026-01-01T00:00:00Z";
  db.prepare("INSERT INTO tenants (id, apple_subject, created_at, updated_at) VALUES ('tenant', 'apple', ?, ?)").run(now, now);
  db.prepare(`INSERT INTO profiles (tenant_id, height_cm, weight_kg, estimate_profile, deficit_kcal, deficit_percent, updated_at)
    VALUES ('tenant', 175, 80, 'male', 600, 20, ?)`).run(now);
  db.prepare(`INSERT INTO credentials (token_hash, id, tenant_id, kind, audience, scopes, label, created_at, expires_at)
    VALUES ('agent', 'agent', 'tenant', 'mcp', 'aud', 'daily:read daily:write', 'MCP', ?, '2999-01-01')`).run(now);
  db.prepare(`INSERT INTO mcp_event_subscriptions (id, tenant_id, token_hash, name, arguments_json,
    callback_url, signing_secret, expires_at, created_at, updated_at)
    VALUES ('sub', 'tenant', 'agent', 'day.feedback_requested', '{}', 'https://chatgpt.com/events',
      'whsec_test', '2999-01-01', ?, ?)`).run(now, now);
  const wakes: string[] = [];
  const events = { getByName: () => ({ async fetch(url: string) {
    wakes.push(new URL(url).pathname); return new Response(null, { status: 204 });
  } }) } as unknown as DurableObjectNamespace;
  const env = { DB: d1, FOOD_EVENTS: events, PUBLIC_ORIGIN: "https://api.00food.com" } as Env;
  const post = (input: unknown) => routeApi(new Request("https://api.00food.com/v1/daily-feedback",
    { method: "POST", body: JSON.stringify(input) }), env, principal);
  const row = (id: string) => db.prepare("SELECT * FROM daily_feedback_requests WHERE id = ?").get(id) as DailyFeedbackRow;
  return { db, env, wakes, post, row };
}

describe("midday feedback", () => {
  it("captures today's partial data, freezes it, and supports idempotent refreshes without adding workout energy", async () => {
    const { db, env, wakes, post, row } = setup();
    try {
      const capturedAt = new Date().toISOString();
      const day = localToday("UTC", new Date(capturedAt));
      db.prepare(`INSERT INTO foods (id, tenant_id, name, serving, kcal, source, created_at, updated_at)
        VALUES ('food', 'tenant', 'Lunch', '1 bowl', 300, 'manual', 'now', 'now')`).run();
      db.prepare(`INSERT INTO food_logs (id, tenant_id, food_id, food_name, serving, quantity, kcal, local_date, logged_at, created_at)
        VALUES ('meal', 'tenant', 'food', 'Lunch', '1 bowl', 1, 300, ?, ?, ?)`)
        .run(day, `${day}T00:00:00Z`, `${day}T00:00:00Z`);
      const request = { id: crypto.randomUUID(), localDate: day, timeZone: "UTC", kind: "midday", capturedAt,
        restingEstimateKcal: 1800, userInstructions: "Suggest dinner ideas.",
        healthDays: [{ localDate: day, restingKcal: 700, activeKcal: 300, waterMl: 1000,
          workouts: [{ id: crypto.randomUUID(), activity: "Walking", startedAt: `${day}T00:00:00Z`,
            endedAt: `${day}T00:00:00Z`, durationMinutes: 20, activeKcal: 100 }] }] };
      expect((await post(request)).status).toBe(201);
      await post(request);
      expect(wakes).toHaveLength(1);
      let context = await dailyFeedbackContext(env, row(request.id));
      expect(context.reviewKind).toBe("midday");
      expect(context.userInstructions).toBe("Suggest dinner ideas.");
      expect(context.days.at(-1)).toMatchObject({ foodKcal: 300,
        calorieBudget: { tdeeKcal: 2100, allowanceKcal: 1680 }, health: { restingKcal: 700, waterMl: 1000 } });
      expect(context.reviewGuidance.join(" ")).toContain("day still in progress");
      db.prepare("UPDATE food_logs SET kcal = 900 WHERE id = 'meal'").run();
      db.prepare("UPDATE profiles SET deficit_percent = 10 WHERE tenant_id = 'tenant'").run();
      context = await dailyFeedbackContext(env, row(request.id));
      expect(context.days.at(-1)).toMatchObject({ foodKcal: 300, calorieBudget: { allowanceKcal: 1680 } });
      expect(context.currentPlanDeficitPercent).toBe(20);
      const next = { ...request, id: crypto.randomUUID(), replacesRequestId: request.id,
        capturedAt: new Date().toISOString() };
      expect((await post(next)).status).toBe(409);
      await saveDailyFeedback(env, "tenant", request.id, "Some dinner ideas.");
      expect((await post(next)).status).toBe(201);
      await post(next);
      expect(wakes).toHaveLength(2);
      expect(await saveDailyFeedback(env, "tenant", request.id, "Stale response")).toBeNull();
      expect((await dailyFeedbackContext(env, row(next.id))).days.at(-1)).toMatchObject({ foodKcal: 900 });
    } finally { db.close(); }
  });

  it("keeps a completed-day review and a delayed offline midday request separate", async () => {
    const { db, env, post } = setup();
    try {
      const day = dateBefore(localToday("UTC"), 1);
      const daily = { id: crypto.randomUUID(), localDate: day, timeZone: "UTC", healthDays: [] };
      expect((await post(daily)).status).toBe(201);
      const midday = { ...daily, id: crypto.randomUUID(), kind: "midday", capturedAt: `${day}T12:00:00Z`, restingEstimateKcal: 1800 };
      expect((await post(midday)).status).toBe(201);
      const snapshot = await routeApi(new Request("https://api.00food.com/v1/snapshot"), env, principal);
      expect(await snapshot.json()).toMatchObject({ dailyFeedback: [{ id: daily.id, kind: "daily" }],
        middayFeedback: [{ id: midday.id, kind: "midday" }] });
      expect((await post({ ...daily, id: crypto.randomUUID(), localDate: localToday("UTC") })).status).toBe(400);
      expect((await post({ ...midday, id: crypto.randomUUID(), capturedAt: `${day}T12:00:00Z`, localDate: dateBefore(day, 1) })).status).toBe(400);
      expect(db.prepare("SELECT count(*) AS total FROM daily_feedback_requests").get()).toEqual({ total: 2 });
    } finally { db.close(); }
  });

  it("preserves populated reviews, delivery retry state, foreign keys and triggers during migration", () => {
    const { db } = setup("0018_midday_feedback.sql");
    try {
      db.prepare(`INSERT INTO daily_feedback_requests
        (id, tenant_id, local_date, time_zone, health_json, state, feedback_text, created_at, updated_at, user_instructions)
        VALUES ('old', 'tenant', '2026-10-10', 'UTC', '[]', 'ready', 'Keep this review', 'now', 'now', 'Keep these preferences')`).run();
      db.prepare(`INSERT INTO daily_feedback_deliveries (id, tenant_id, request_id, subscription_id, attempts, next_attempt_at)
        VALUES ('delivery', 'tenant', 'old', 'sub', 3, 'retry later')`).run();
      const delivery = db.prepare("SELECT * FROM daily_feedback_deliveries").get();
      db.exec("BEGIN");
      db.exec(readFileSync(join(migrationsDir, "0018_midday_feedback.sql"), "utf8"));
      db.exec("COMMIT");
      expect(db.prepare("SELECT * FROM daily_feedback_deliveries").get()).toEqual(delivery);
      expect(db.prepare("SELECT feedback_text, user_instructions, review_kind FROM daily_feedback_requests").get())
        .toEqual({ feedback_text: "Keep this review", user_instructions: "Keep these preferences", review_kind: "daily" });
      expect(db.prepare("PRAGMA foreign_key_check").all()).toEqual([]);
      const version = db.prepare("SELECT data_version FROM tenants WHERE id = 'tenant'").get()?.data_version;
      db.prepare("UPDATE daily_feedback_requests SET feedback_text = 'Updated' WHERE id = 'old'").run();
      expect(db.prepare("SELECT data_version FROM tenants WHERE id = 'tenant'").get()?.data_version).not.toBe(version);
      db.prepare("DELETE FROM daily_feedback_requests WHERE id = 'old'").run();
      expect(db.prepare("SELECT count(*) AS total FROM daily_feedback_deliveries").get()).toEqual({ total: 0 });
    } finally { db.close(); }
  });
});
