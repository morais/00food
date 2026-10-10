import { describe, expect, it } from "vitest";
import { routeApi, type Env } from "../src/api";
import type { Principal } from "../src/auth";
import { dailyFeedbackContext, dateBefore, localToday, saveDailyFeedback, type DailyFeedbackRow } from "../src/dailyFeedback";
import { migratedD1 } from "./d1";

const foodId = "c5f84159-41d0-495e-947d-18c2238db9b3";
const reviewId = "a4d491d0-6787-4920-983a-ec8ec1b7319b";
const newReviewId = "b4d491d0-6787-4920-983a-ec8ec1b7319b";
const logId = "d4d491d0-6787-4920-983a-ec8ec1b7319b";
const principal: Principal = { tenantId: "tenant", kind: "app", scopes: [], tokenHash: "app" };

function setup() {
  const { db, d1 } = migratedD1();
  const now = "2026-01-01T00:00:00Z";
  const yesterday = dateBefore(localToday("UTC"), 1);
  db.prepare("INSERT INTO tenants (id, apple_subject, created_at, updated_at) VALUES ('tenant', 'apple', ?, ?)").run(now, now);
  db.prepare(`INSERT INTO foods (id, tenant_id, name, serving, kcal, source, created_at, updated_at)
    VALUES (?, 'tenant', 'Soup', '1 bowl', 300, 'manual', ?, ?)`).run(foodId, now, now);
  db.prepare(`INSERT INTO credentials (token_hash, id, tenant_id, kind, audience, scopes, label, created_at, expires_at)
    VALUES ('agent', 'agent', 'tenant', 'mcp', 'aud', 'daily:read daily:write', 'MCP', ?, '2999-01-01')`).run(now);
  db.prepare(`INSERT INTO mcp_event_subscriptions (id, tenant_id, token_hash, name, arguments_json,
    callback_url, signing_secret, expires_at, created_at, updated_at)
    VALUES ('sub', 'tenant', 'agent', 'day.feedback_requested', '{}', 'https://chatgpt.com/events',
      'whsec_test', '2999-01-01', ?, ?)`).run(now, now);
  const wakes: string[] = [];
  const events = { getByName: () => ({ async fetch(url: string) {
    wakes.push(new URL(url).pathname);
    return new Response(null, { status: 204 });
  } }) } as unknown as DurableObjectNamespace;
  const env = { DB: d1, FOOD_EVENTS: events, PUBLIC_ORIGIN: "https://api.00food.com" } as Env;
  const post = (path: string, input: unknown, user = principal) => routeApi(
    new Request(`https://api.00food.com${path}`, { method: "POST", body: JSON.stringify(input) }), env, user);
  const review = (extra = {}) => post("/v1/daily-feedback", { id: reviewId, localDate: yesterday,
    timeZone: "UTC", healthDays: [{ localDate: yesterday, waterMl: 2000 }], ...extra });
  const log = (extra = {}) => post("/v1/logs", { id: logId, foodId, localDate: yesterday,
    loggedAt: `${yesterday}T18:30:00Z`, createdAt: new Date().toISOString(), ...extra });
  return { db, env, yesterday, wakes, post, review, log };
}

describe("late food logs and renewed daily reviews", () => {
  it("requires a food addition, sends a fresh event once, and rejects the old agent response", async () => {
    const { db, env, yesterday, wakes, review, log } = setup();
    try {
      expect((await review()).status).toBe(201);
      await saveDailyFeedback(env, "tenant", reviewId, "Original review");
      const replacement = { id: newReviewId, replacesRequestId: reviewId,
        healthDays: [{ localDate: yesterday, waterMl: 2750 }] };
      expect((await review(replacement)).status).toBe(409);
      // A food for today must not unlock yesterday's new-review action.
      expect((await log({ id: crypto.randomUUID(), localDate: localToday("UTC") })).status).toBe(201);
      expect((await review(replacement)).status).toBe(409);
      const logged = await log();
      expect(logged.status).toBe(201);
      expect((await logged.json() as { log: unknown }).log).toMatchObject({ localDate: yesterday,
        loggedAt: `${yesterday}T18:30:00Z` });
      expect(db.prepare("SELECT needs_refresh FROM daily_feedback_requests").get()).toEqual({ needs_refresh: 1 });
      db.prepare("UPDATE daily_feedback_deliveries SET delivered_at = 'delivered'").run();
      const renewed = await review(replacement);
      expect(renewed.status).toBe(201);
      expect((await renewed.json() as { request: unknown }).request).toMatchObject({ id: newReviewId,
        state: "pending", feedback: null, needsRefresh: false });
      expect(db.prepare("SELECT request_id, delivered_at FROM daily_feedback_deliveries").all())
        .toEqual([{ request_id: newReviewId, delivered_at: null }]);
      expect(wakes).toEqual(["/publish-daily", "/publish-daily"]);
      // Offline replay of either operation must not mark the new review stale
      // or send the replacement event twice.
      await log();
      await review(replacement);
      expect(wakes).toHaveLength(2);
      expect(db.prepare("SELECT needs_refresh FROM daily_feedback_requests").get()).toEqual({ needs_refresh: 0 });
      expect(await saveDailyFeedback(env, "tenant", reviewId, "Stale reply")).toBeNull();
      const row = db.prepare("SELECT * FROM daily_feedback_requests").get() as DailyFeedbackRow;
      const context = await dailyFeedbackContext(env, row);
      expect(context.days.find(day => day.localDate === yesterday)).toMatchObject({ foodKcal: 300,
        health: { waterMl: 2750 } });
      await saveDailyFeedback(env, "tenant", newReviewId, "Updated review");
      expect((await review({ id: crypto.randomUUID(), replacesRequestId: newReviewId })).status).toBe(409);
    } finally { db.close(); }
  });

  it("cannot replace another account's review or delete a review on an ID collision", async () => {
    const { db, review, log } = setup();
    try {
      await review();
      await log();
      const now = new Date().toISOString();
      db.prepare("INSERT INTO tenants (id, apple_subject, created_at, updated_at) VALUES ('other', 'other-apple', ?, ?)").run(now, now);
      db.prepare(`INSERT INTO daily_feedback_requests (id, tenant_id, local_date, time_zone, health_json,
        state, created_at, updated_at) VALUES (?, 'other', '2026-10-01', 'UTC', '[]', 'ready', ?, ?)`)
        .run(newReviewId, now, now);
      expect((await review({ id: newReviewId, replacesRequestId: reviewId })).status).toBe(409);
      expect(db.prepare("SELECT id FROM daily_feedback_requests WHERE tenant_id = 'tenant'").get()).toEqual({ id: reviewId });
      // A mismatching previous ID is harmless and cannot touch the other tenant.
      await review({ id: crypto.randomUUID(), replacesRequestId: newReviewId });
      expect(db.prepare("SELECT id FROM daily_feedback_requests WHERE tenant_id = 'other'").get()).toEqual({ id: newReviewId });
    } finally { db.close(); }
  });

  it("preserves the meal date when accepting a new-food estimate and marks its review stale", async () => {
    const { db, yesterday, post, review } = setup();
    try {
      await review();
      const estimateId = crypto.randomUUID();
      const now = new Date().toISOString();
      db.prepare(`INSERT INTO pending_estimations (id, tenant_id, description, state, proposed_name,
        proposed_serving, proposed_kcal, local_date, created_at, updated_at)
        VALUES (?, 'tenant', 'Yesterday dinner', 'proposed', 'Dinner', '1 plate', 500, ?, ?, ?)`)
        .run(estimateId, yesterday, now, now);
      expect((await post(`/v1/estimations/${estimateId}/accept`, { loggedAt: `${yesterday}T19:00:00Z` })).status).toBe(200);
      expect(db.prepare("SELECT local_date, logged_at, created_at FROM food_logs").get()).toMatchObject({
        local_date: yesterday, logged_at: `${yesterday}T19:00:00Z` });
      expect(db.prepare("SELECT needs_refresh FROM daily_feedback_requests").get()).toEqual({ needs_refresh: 1 });
      expect(db.prepare("SELECT created_at FROM food_logs").get()?.created_at).not.toBe(`${yesterday}T19:00:00Z`);
    } finally { db.close(); }
  });
});
