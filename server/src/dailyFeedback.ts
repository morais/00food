import { z } from "zod";
import type { Env } from "./api";

const healthDay = z.strictObject({
  localDate: z.iso.date(),
  activeKcal: z.number().int().min(0).max(10000).nullish(),
  restingKcal: z.number().int().min(0).max(10000).nullish(),
  waterMl: z.number().int().min(0).max(30000).nullish(),
  weightKg: z.number().min(25).max(400).nullish(),
  bodyFatPercent: z.number().min(0).max(100).nullish(),
});

export const dailyFeedbackInput = z.strictObject({
  id: z.uuid(), localDate: z.iso.date(), timeZone: z.string().min(1).max(100),
  healthDays: z.array(healthDay).max(7),
});

export type DailyFeedbackRow = {
  id: string; tenant_id: string; local_date: string; time_zone: string;
  health_json: string; state: "pending" | "ready"; feedback_text: string | null;
  created_at: string; updated_at: string;
};

type LogRow = { id: string; food_name: string; serving: string; quantity: number;
  kcal: number; fruit_veg_portions: number; local_date: string; logged_at: string };
type EstimateRow = { description: string; local_date: string };
type ProfileRow = { deficit_kcal: number };

export const dailyFeedbackView = (row: DailyFeedbackRow) => ({
  id: row.id, localDate: row.local_date, state: row.state, feedback: row.feedback_text,
  createdAt: row.created_at, updatedAt: row.updated_at,
});

export function dateBefore(localDate: string, days: number): string {
  const [year, month, day] = localDate.split("-").map(Number);
  return new Date(Date.UTC(year, month - 1, day - days)).toISOString().slice(0, 10);
}

export function localToday(timeZone: string, now = new Date()): string {
  const parts = new Intl.DateTimeFormat("en-US", { timeZone, year: "numeric", month: "2-digit",
    day: "2-digit" }).formatToParts(now);
  const part = (type: string) => parts.find(value => value.type === type)?.value ?? "";
  return `${part("year")}-${part("month")}-${part("day")}`;
}

export function validHealthWindow(input: z.infer<typeof dailyFeedbackInput>): boolean {
  const earliest = dateBefore(input.localDate, 6);
  const dates = input.healthDays.map(day => day.localDate);
  return new Set(dates).size === dates.length && dates.every(date => date >= earliest && date <= input.localDate);
}

export async function findDailyFeedback(env: Env, tenantId: string, id: string): Promise<DailyFeedbackRow | null> {
  return env.DB.prepare("SELECT * FROM daily_feedback_requests WHERE id = ? AND tenant_id = ?")
    .bind(id, tenantId).first<DailyFeedbackRow>();
}

export async function dailyFeedbackContext(env: Env, row: DailyFeedbackRow): Promise<unknown> {
  const first = dateBefore(row.local_date, 6);
  const [logs, estimates, profile] = await Promise.all([
    env.DB.prepare(`SELECT id, food_name, serving, quantity, kcal, fruit_veg_portions, local_date, logged_at
      FROM food_logs WHERE tenant_id = ? AND local_date BETWEEN ? AND ?
      ORDER BY local_date, logged_at LIMIT 5000`).bind(row.tenant_id, first, row.local_date).all<LogRow>(),
    env.DB.prepare(`SELECT description, local_date FROM pending_estimations
      WHERE tenant_id = ? AND local_date BETWEEN ? AND ? LIMIT 100`)
      .bind(row.tenant_id, first, row.local_date).all<EstimateRow>(),
    env.DB.prepare("SELECT deficit_kcal FROM profiles WHERE tenant_id = ?")
      .bind(row.tenant_id).first<ProfileRow>(),
  ]);
  const health = JSON.parse(row.health_json) as z.infer<typeof healthDay>[];
  const healthByDate = new Map(health.map(day => [day.localDate, day]));
  const days = Array.from({ length: 7 }, (_, index) => dateBefore(row.local_date, 6 - index)).map(localDate => {
    const foods = logs.results.filter(log => log.local_date === localDate).map(log => ({
      id: log.id, name: log.food_name, serving: log.serving, quantity: log.quantity,
      kcal: log.kcal, fruitVegPortions: log.fruit_veg_portions, loggedAt: log.logged_at,
    }));
    const pendingFoods = estimates.results.filter(item => item.local_date === localDate)
      .map(item => item.description);
    return { localDate, foods, foodKcal: foods.reduce((total, item) => total + item.kcal, 0),
      fruitVegPortions: Math.min(5, foods.reduce((total, item) => total + item.fruitVegPortions, 0)),
      pendingFoods, health: healthByDate.get(localDate) ?? null };
  });
  return { requestId: row.id, feedbackDay: row.local_date, timeZone: row.time_zone,
    currentPlanCalorieGapKcal: profile?.deficit_kcal ?? null,
    days, note: "Health values are daily aggregates when available. Missing values are null. Food totals omit pending estimates. The current plan may differ from the plan on earlier days." };
}

export async function saveDailyFeedback(env: Env, tenantId: string, id: string, feedback: string): Promise<DailyFeedbackRow | null> {
  await env.DB.prepare(`UPDATE daily_feedback_requests SET state = 'ready', feedback_text = ?, updated_at = ?
    WHERE id = ? AND tenant_id = ?`).bind(feedback, new Date().toISOString(), id, tenantId).run();
  return findDailyFeedback(env, tenantId, id);
}
