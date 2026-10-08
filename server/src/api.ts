import { z } from "zod";
import { tenantForPrincipal, type Principal } from "./auth";
import { notifyDailyFeedbackEvent, notifyFoodEvent, recordFoodEvent } from "./foodEvents";
import { dailyFeedbackInput, dailyFeedbackView, dateBefore, localToday, validHealthWindow,
  type DailyFeedbackRow } from "./dailyFeedback";
import { dailyFeedbackDeliveryInsert, webhookDeliveryInsert } from "./mcpWebhookEvents";

export interface Env {
  DB: D1Database;
  PHOTOS?: R2Bucket;
  PUBLIC_ORIGIN: string;
  APP_NAME?: string;
  APPLE_APP_CLIENT_ID?: string;
  APPLE_WEB_CLIENT_ID?: string;
  APPLE_WEB_REDIRECT_URI?: string;
  APPLE_TEAM_ID?: string;
  APPLE_KEY_ID?: string;
  APPLE_PRIVATE_KEY?: string;
  OAUTH_SIGNING_SECRET?: string;
  MCP_VERIFIED_CLIENTS?: string;
  REVIEW_TENANT_IDS?: string;
  SOURCE_LIMITER?: RateLimit;
  SIGN_IN_LIMITER?: RateLimit;
  TENANT_LIMITER?: RateLimit;
  FOOD_EVENTS?: DurableObjectNamespace;
}

export const appName = (env: Env): string => env.APP_NAME?.trim().slice(0, 60) || "00Food";
export const json = (value: unknown, status = 200): Response => Response.json(value, {
  status, headers: { "Cache-Control": "no-store" },
});

const id = z.uuid();
const day = z.iso.date();
const profileInput = z.strictObject({
  heightCm: z.number().min(100).max(250),
  weightKg: z.number().min(25).max(400),
  estimateProfile: z.enum(["female", "male", "neutral"]),
  deficitKcal: z.number().int().min(0).max(1000),
  birthYear: z.number().int().min(1900).max(9999).nullable().optional(),
});
const foodInput = z.strictObject({
  id: id.optional(), name: z.string().trim().min(1).max(120),
  serving: z.string().trim().min(1).max(80),
  kcal: z.number().int().min(1).max(5000),
  fruitVegPortions: z.number().int().min(0).max(5).default(0),
  source: z.enum(["manual", "seed"]).default("manual"),
});
const logInput = z.strictObject({
  id: id.optional(), foodId: id, quantity: z.number().min(0.1).max(20).default(1),
  localDate: day, loggedAt: z.iso.datetime({ offset: true }).optional(),
});
const estimationInput = z.strictObject({
  id: id.optional(), description: z.string().trim().max(500), localDate: day,
  photoBase64: z.string().min(1).max(2_666_668).optional(),
});
export const proposalInput = z.strictObject({
  name: z.string().trim().min(1).max(120),
  serving: z.string().trim().min(1).max(80),
  kcal: z.number().int().min(1).max(5000),
  note: z.string().trim().max(500).default(""),
  reasoning: z.string().trim().min(1).max(2000).optional(),
  fruitVegPortions: z.number().int().min(0).max(5).optional(),
});

type FoodRow = {
  id: string; name: string; serving: string; kcal: number; source: string;
  fruit_veg_portions: number;
  use_count: number; last_used_at: string | null; dismissed_at: string | null;
  created_at: string; updated_at: string;
};
type LogRow = {
  id: string; food_id: string; food_name: string; serving: string;
  quantity: number; kcal: number; fruit_veg_portions: number; local_date: string; logged_at: string;
};
type ProfileRow = { height_cm: number; weight_kg: number; estimate_profile: string; deficit_kcal: number; birth_year: number | null; updated_at: string };
type EstimationRow = {
  id: string; description: string; photo_key: string | null; state: string;
  proposed_name: string | null; proposed_serving: string | null; proposed_kcal: number | null;
  agent_note: string | null; local_date: string; created_at: string; updated_at: string;
  agent_reasoning: string | null; user_clarification: string | null; clarification_id: string | null;
  proposed_fruit_veg_portions: number | null;
};

export const foodView = (r: FoodRow) => ({
  id: r.id, name: r.name, serving: r.serving, kcal: r.kcal, source: r.source,
  fruitVegPortions: r.fruit_veg_portions,
  useCount: r.use_count, lastUsedAt: r.last_used_at, dismissedAt: r.dismissed_at,
  createdAt: r.created_at, updatedAt: r.updated_at,
});
export const logView = (r: LogRow) => ({
  id: r.id, foodId: r.food_id, foodName: r.food_name, serving: r.serving,
  quantity: r.quantity, kcal: r.kcal, fruitVegPortions: r.fruit_veg_portions,
  localDate: r.local_date, loggedAt: r.logged_at,
});
export const estimationView = (r: EstimationRow) => ({
  id: r.id, description: r.description, hasPhoto: !!r.photo_key, state: r.state,
  proposedName: r.proposed_name, proposedServing: r.proposed_serving, proposedKcal: r.proposed_kcal,
  proposedFruitVegPortions: r.proposed_fruit_veg_portions,
  agentNote: r.agent_note, localDate: r.local_date, createdAt: r.created_at, updatedAt: r.updated_at,
  reasoning: r.agent_reasoning, clarification: r.user_clarification,
});
const profileView = (r: ProfileRow) => ({
  heightCm: r.height_cm, weightKg: r.weight_kg, estimateProfile: r.estimate_profile,
  deficitKcal: r.deficit_kcal, birthYear: r.birth_year, updatedAt: r.updated_at,
});

class APIError extends Error { constructor(public status: number, message: string) { super(message); } }
const fail = (status: number, message: string): never => { throw new APIError(status, message); };

function validateJpeg(bytes: Uint8Array): void {
  if (!bytes.byteLength || bytes.byteLength > 2_000_000) fail(413, "Photo must be under 2 MB");
  if (bytes[0] !== 0xff || bytes[1] !== 0xd8 ||
      bytes[bytes.length - 2] !== 0xff || bytes[bytes.length - 1] !== 0xd9) {
    fail(415, "Invalid JPEG photo");
  }
}

async function body(req: Request, limit = 16000): Promise<unknown> {
  if (Number(req.headers.get("content-length") || 0) > limit) fail(413, "Request too large");
  const raw = await req.text();
  if (raw.length > limit) fail(413, "Request too large");
  try { return JSON.parse(raw); } catch { return fail(400, "Expected JSON"); }
}

export async function findEstimation(env: Env, tenantId: string, estimationId: string): Promise<EstimationRow | null> {
  return env.DB.prepare("SELECT * FROM pending_estimations WHERE id = ? AND tenant_id = ?")
    .bind(estimationId, tenantId).first<EstimationRow>();
}

export async function proposeEstimation(env: Env, tenantId: string, estimationId: string, raw: unknown): Promise<Response> {
  const parsed = proposalInput.parse(raw);
  const now = new Date().toISOString();
  const row = await env.DB.prepare(`UPDATE pending_estimations SET state = 'proposed',
    proposed_name = ?, proposed_serving = ?, proposed_kcal = ?, agent_note = ?,
    agent_reasoning = COALESCE(?, agent_reasoning),
    proposed_fruit_veg_portions = COALESCE(?, proposed_fruit_veg_portions), updated_at = ?
    WHERE id = ? AND tenant_id = ? RETURNING *`).bind(
    parsed.name, parsed.serving, parsed.kcal, parsed.note, parsed.reasoning ?? null,
    parsed.fruitVegPortions ?? null, now, estimationId, tenantId,
  ).first<EstimationRow>();
  if (!row) return fail(404, "Estimation not found");
  return json({ estimation: estimationView(row) });
}

export async function setFoodFruitVegPortions(env: Env, tenantId: string, foodId: string,
                                              portions: number): Promise<ReturnType<typeof foodView> | null> {
  const existing = await env.DB.prepare("SELECT * FROM foods WHERE id = ? AND tenant_id = ?")
    .bind(foodId, tenantId).first<FoodRow>();
  if (!existing) return null;
  const now = new Date().toISOString();
  await env.DB.batch([
    env.DB.prepare("UPDATE foods SET fruit_veg_portions = ?, updated_at = ? WHERE id = ? AND tenant_id = ?")
      .bind(portions, now, foodId, tenantId),
    env.DB.prepare(`UPDATE food_logs SET fruit_veg_portions =
      min(5, CAST(round(? * quantity) AS INTEGER)) WHERE food_id = ? AND tenant_id = ?`)
      .bind(portions, foodId, tenantId),
  ]);
  return foodView({ ...existing, fruit_veg_portions: portions, updated_at: now });
}

export async function routeApi(req: Request, env: Env, principal: Principal): Promise<Response> {
  try { return await route(req, env, principal); }
  catch (cause) {
    if (cause instanceof APIError) return json({ error: cause.message }, cause.status);
    if (cause instanceof z.ZodError) return json({ error: "Invalid input", details: cause.issues.map(i => i.path.join(".")) }, 400);
    console.error("Food API failed", cause instanceof Error ? cause.message : "unknown error");
    return json({ error: "Server error" }, 500);
  }
}

async function route(req: Request, env: Env, principal: Principal): Promise<Response> {
  const path = new URL(req.url).pathname;
  const method = req.method;
  const tenantId = principal.tenantId;
  if (path === "/v1/me" && method === "GET") {
    const tenant = await tenantForPrincipal(env, principal);
    return json({ id: tenant?.id, email: tenant?.email });
  }
  if (path === "/v1/snapshot" && method === "GET") {
    // The version is read before the data, so a write that lands in between
    // can only make the ETag older than the body, never newer. The UTC date is
    // part of the tag because the 90-day log window moves daily.
    const tenant = await env.DB.prepare("SELECT created_at, data_version FROM tenants WHERE id = ?")
      .bind(tenantId).first<{ created_at: string; data_version: number }>();
    const etag = `"${tenant?.data_version ?? 0}-${new Date().toISOString().slice(0, 10)}"`;
    if (req.headers.get("if-none-match") === etag) {
      return new Response(null, { status: 304, headers: { ETag: etag, "Cache-Control": "no-store" } });
    }
    const [profile, foods, logs, estimations, dailyFeedback] = await Promise.all([
      env.DB.prepare("SELECT * FROM profiles WHERE tenant_id = ?").bind(tenantId).first<ProfileRow>(),
      env.DB.prepare("SELECT * FROM foods WHERE tenant_id = ? ORDER BY use_count DESC, last_used_at DESC, created_at DESC LIMIT 1000").bind(tenantId).all<FoodRow>(),
      env.DB.prepare("SELECT * FROM food_logs WHERE tenant_id = ? AND local_date >= date('now','-90 days') ORDER BY logged_at DESC LIMIT 5000").bind(tenantId).all<LogRow>(),
      env.DB.prepare("SELECT * FROM pending_estimations WHERE tenant_id = ? ORDER BY created_at DESC LIMIT 100").bind(tenantId).all<EstimationRow>(),
      env.DB.prepare("SELECT * FROM daily_feedback_requests WHERE tenant_id = ? ORDER BY local_date DESC LIMIT 90")
        .bind(tenantId).all<DailyFeedbackRow>(),
    ]);
    const response = json({ startedAt: tenant?.created_at ?? null, profile: profile ? profileView(profile) : null,
      foods: foods.results.map(foodView), logs: logs.results.map(logView),
      estimations: estimations.results.map(estimationView),
      dailyFeedback: dailyFeedback.results.map(dailyFeedbackView), serverTime: new Date().toISOString() });
    response.headers.set("ETag", etag);
    return response;
  }
  if (path === "/v1/daily-feedback" && method === "GET") {
    const rows = await env.DB.prepare("SELECT * FROM daily_feedback_requests WHERE tenant_id = ? ORDER BY local_date DESC LIMIT 90")
      .bind(tenantId).all<DailyFeedbackRow>();
    return json({ requests: rows.results.map(dailyFeedbackView) });
  }
  if (path === "/v1/daily-feedback" && method === "POST") {
    const input = dailyFeedbackInput.parse(await body(req));
    let today: string;
    try { today = localToday(input.timeZone); }
    catch { throw new APIError(400, "Invalid time zone"); }
    if (input.localDate >= today || input.localDate < dateBefore(today, 90) || !validHealthWindow(input)) {
      throw new APIError(400, "Feedback must be for a completed day with at most seven matching Health days");
    }
    const existing = await env.DB.prepare("SELECT * FROM daily_feedback_requests WHERE tenant_id = ? AND local_date = ?")
      .bind(tenantId, input.localDate).first<DailyFeedbackRow>();
    if (existing) return json({ request: dailyFeedbackView(existing) }, 201);
    const now = new Date().toISOString();
    await env.DB.batch([
      env.DB.prepare(`INSERT OR IGNORE INTO daily_feedback_requests
        (id, tenant_id, local_date, time_zone, health_json, state, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, 'pending', ?, ?)`).bind(input.id, tenantId, input.localDate,
          input.timeZone, JSON.stringify(input.healthDays), now, now),
      dailyFeedbackDeliveryInsert(env, tenantId, input.id),
    ]);
    const row = await env.DB.prepare("SELECT * FROM daily_feedback_requests WHERE tenant_id = ? AND local_date = ?")
      .bind(tenantId, input.localDate).first<DailyFeedbackRow>();
    if (!row) throw new APIError(409, "Feedback request ID is already in use");
    if (row.id === input.id) await notifyDailyFeedbackEvent(env, tenantId);
    return json({ request: dailyFeedbackView(row) }, 201);
  }
  if (path === "/v1/profile" && method === "PUT") {
    const input = profileInput.parse(await body(req));
    if (input.birthYear != null && input.birthYear > new Date().getUTCFullYear() - 18) {
      fail(400, "Birth year must be for an adult");
    }
    const now = new Date().toISOString();
    const previous = await env.DB.prepare("SELECT birth_year FROM profiles WHERE tenant_id = ?")
      .bind(tenantId).first<{ birth_year: number | null }>();
    const birthYear = input.birthYear === undefined ? previous?.birth_year ?? null : input.birthYear;
    await env.DB.prepare(`INSERT INTO profiles (tenant_id, height_cm, weight_kg, estimate_profile, deficit_kcal, birth_year, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(tenant_id) DO UPDATE SET
      height_cm=excluded.height_cm, weight_kg=excluded.weight_kg,
      estimate_profile=excluded.estimate_profile, deficit_kcal=excluded.deficit_kcal,
      birth_year=excluded.birth_year, updated_at=excluded.updated_at`)
      .bind(tenantId, input.heightCm, input.weightKg, input.estimateProfile, input.deficitKcal, birthYear, now).run();
    return json({ profile: { ...input, birthYear, updatedAt: now } });
  }
  if (path === "/v1/foods" && method === "POST") {
    const input = foodInput.parse(await body(req));
    const foodId = input.id || crypto.randomUUID();
    const existing = await env.DB.prepare("SELECT * FROM foods WHERE id = ? AND tenant_id = ?")
      .bind(foodId, tenantId).first<FoodRow>();
    if (existing) return json({ food: foodView(existing) }, 201);
    const count = await env.DB.prepare("SELECT food_count AS n FROM tenants WHERE id = ?")
      .bind(tenantId).first<{ n: number }>();
    if ((count?.n ?? 0) >= 2000) throw new APIError(403, "Food library limit reached");
    const now = new Date().toISOString();
    const row = await env.DB.prepare(`INSERT OR IGNORE INTO foods
      (id, tenant_id, name, serving, kcal, fruit_veg_portions, source, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING *`).bind(foodId, tenantId, input.name, input.serving,
        input.kcal, input.fruitVegPortions, input.source, now, now).first<FoodRow>();
    if (!row) throw new APIError(409, "Food ID is already in use");
    return json({ food: foodView(row) }, 201);
  }
  const dismissFoodMatch = /^\/v1\/foods\/([a-f0-9-]{36})\/dismiss$/.exec(path);
  if (dismissFoodMatch && method === "POST") {
    const now = new Date().toISOString();
    const row = await env.DB.prepare("UPDATE foods SET dismissed_at = ? WHERE id = ? AND tenant_id = ? RETURNING *")
      .bind(now, dismissFoodMatch[1], tenantId).first<FoodRow>();
    if (!row) throw new APIError(404, "Food not found");
    return json({ food: foodView(row) });
  }
  const fruitVegMatch = /^\/v1\/foods\/([a-f0-9-]{36})\/fruit-veg-portions$/.exec(path);
  if (fruitVegMatch && method === "PUT") {
    const input = z.strictObject({ fruitVegPortions: z.number().int().min(0).max(5) }).parse(await body(req));
    const food = await setFoodFruitVegPortions(env, tenantId, fruitVegMatch[1], input.fruitVegPortions);
    if (!food) throw new APIError(404, "Food not found");
    return json({ food });
  }
  if (path === "/v1/logs" && method === "POST") {
    const input = logInput.parse(await body(req));
    const food = await env.DB.prepare("SELECT * FROM foods WHERE id = ? AND tenant_id = ?")
      .bind(input.foodId, tenantId).first<FoodRow>();
    if (!food) throw new APIError(404, "Food not found");
    const logId = input.id || crypto.randomUUID();
    const existing = await env.DB.prepare("SELECT * FROM food_logs WHERE id = ? AND tenant_id = ?")
      .bind(logId, tenantId).first<LogRow>();
    if (existing) {
      await recordFoodEvent(env, tenantId, `log:${logId}`, "food_logged", logId, logView(existing));
      return json({ log: logView(existing) }, 201);
    }
    const count = await env.DB.prepare("SELECT log_count AS n FROM tenants WHERE id = ?")
      .bind(tenantId).first<{ n: number }>();
    if ((count?.n ?? 0) >= 10000) throw new APIError(403, "Food log limit reached");
    const now = new Date().toISOString();
    const calories = Math.max(1, Math.round(food.kcal * input.quantity));
    const portions = Math.min(5, Math.round(food.fruit_veg_portions * input.quantity));
    const loggedAt = input.loggedAt || now;
    const row = await env.DB.prepare(`INSERT OR IGNORE INTO food_logs
      (id, tenant_id, food_id, food_name, serving, quantity, kcal, fruit_veg_portions, local_date, logged_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING *`).bind(logId, tenantId, food.id, food.name,
        food.serving, input.quantity, calories, portions, input.localDate, loggedAt).first<LogRow>();
    // Nothing returned means the ID belongs to another account's log.
    if (!row) throw new APIError(409, "Log ID is already in use");
    await env.DB.prepare(`UPDATE foods SET use_count = use_count + 1,
      last_used_at = CASE WHEN last_used_at IS NULL OR last_used_at < ? THEN ? ELSE last_used_at END,
      dismissed_at = NULL WHERE id = ? AND tenant_id = ?`)
      .bind(loggedAt, loggedAt, food.id, tenantId).run();
    await recordFoodEvent(env, tenantId, `log:${logId}`, "food_logged", logId, logView(row));
    return json({ log: logView(row) }, 201);
  }
  const logMatch = /^\/v1\/logs\/([a-f0-9-]{36})$/.exec(path);
  if (logMatch && method === "DELETE") {
    const row = await env.DB.prepare("SELECT food_id FROM food_logs WHERE id = ? AND tenant_id = ?")
      .bind(logMatch[1], tenantId).first<{ food_id: string }>();
    if (!row) throw new APIError(404, "Log not found");
    await env.DB.batch([
      env.DB.prepare("DELETE FROM food_logs WHERE id = ? AND tenant_id = ?").bind(logMatch[1], tenantId),
      env.DB.prepare("UPDATE foods SET use_count = max(0, use_count - 1) WHERE id = ? AND tenant_id = ?").bind(row.food_id, tenantId),
    ]);
    return json({ ok: true });
  }
  if (path === "/v1/estimations" && method === "POST") {
    const input = estimationInput.parse(await body(req, 2_700_000));
    const estimationId = input.id || crypto.randomUUID();
    const existing = await findEstimation(env, tenantId, estimationId);
    if (existing) {
      await recordFoodEvent(env, tenantId, `estimate:${estimationId}`, "estimate_requested", estimationId,
        { description: existing.description, hasPhoto: !!existing.photo_key, localDate: existing.local_date });
      return json({ estimation: estimationView(existing) }, 201);
    }
    const count = await env.DB.prepare("SELECT estimate_count AS n FROM tenants WHERE id = ?")
      .bind(tenantId).first<{ n: number }>();
    if ((count?.n ?? 0) >= 100) throw new APIError(403, "Review queue is full");
    const now = new Date().toISOString();
    let photoKey: string | null = null;
    if (input.photoBase64) {
      if (!env.PHOTOS) throw new APIError(503, "Photo storage is unavailable");
      let bytes: Uint8Array;
      try { bytes = Uint8Array.from(atob(input.photoBase64), character => character.charCodeAt(0)); }
      catch { throw new APIError(415, "Invalid JPEG photo"); }
      validateJpeg(bytes);
      photoKey = `${tenantId}/${estimationId}.jpg`;
      await env.PHOTOS.put(photoKey, bytes, { httpMetadata: { contentType: "image/jpeg" } });
    }
    let row: EstimationRow | null;
    try {
      row = await env.DB.prepare(`INSERT OR IGNORE INTO pending_estimations
        (id, tenant_id, description, photo_key, state, local_date, created_at, updated_at)
        VALUES (?, ?, ?, ?, 'pending', ?, ?, ?) RETURNING *`).bind(estimationId, tenantId, input.description,
          photoKey, input.localDate, now, now).first<EstimationRow>();
      if (!row) throw new APIError(409, "Estimation ID is already in use");
    } catch (error) {
      if (photoKey) await env.PHOTOS?.delete(photoKey);
      throw error;
    }
    await recordFoodEvent(env, tenantId, `estimate:${estimationId}`, "estimate_requested", estimationId,
      { description: row.description, hasPhoto: !!row.photo_key, localDate: row.local_date });
    return json({ estimation: estimationView(row) }, 201);
  }
  const photoMatch = /^\/v1\/estimations\/([a-f0-9-]{36})\/photo$/.exec(path);
  if (photoMatch && method === "PUT") {
    if (!env.PHOTOS) throw new APIError(503, "Photo storage is unavailable");
    const row = await findEstimation(env, tenantId, photoMatch[1]);
    if (!row || row.state !== "pending") throw new APIError(404, "Pending estimation not found");
    if (req.headers.get("content-type") !== "image/jpeg") fail(415, "Use a JPEG photo");
    // Refuse before buffering: an unchecked body could be far larger than a photo.
    const declared = Number(req.headers.get("content-length") ?? NaN);
    if (!Number.isFinite(declared) || declared > 2_000_000) fail(declared > 2_000_000 ? 413 : 411, "Photo must be under 2 MB");
    const bytes = await req.arrayBuffer();
    validateJpeg(new Uint8Array(bytes));
    const key = `${tenantId}/${row.id}.jpg`;
    await env.PHOTOS.put(key, bytes, { httpMetadata: { contentType: "image/jpeg" } });
    await env.DB.prepare("UPDATE pending_estimations SET photo_key = ?, updated_at = ? WHERE id = ? AND tenant_id = ?")
      .bind(key, new Date().toISOString(), row.id, tenantId).run();
    return json({ ok: true });
  }
  const proposalMatch = /^\/v1\/estimations\/([a-f0-9-]{36})\/proposal$/.exec(path);
  if (proposalMatch && method === "PUT") {
    const existing = await findEstimation(env, tenantId, proposalMatch[1]);
    if (!existing || existing.state !== "proposed") throw new APIError(409, "No estimate is ready for review");
    const input = proposalInput.parse(await body(req));
    return proposeEstimation(env, tenantId, existing.id, { ...input, reasoning: existing.agent_reasoning ?? undefined });
  }
  const clarificationMatch = /^\/v1\/estimations\/([a-f0-9-]{36})\/clarifications$/.exec(path);
  if (clarificationMatch && method === "POST") {
    const input = z.strictObject({ id, text: z.string().trim().min(1).max(1000) }).parse(await body(req));
    const existing = await findEstimation(env, tenantId, clarificationMatch[1]);
    if (!existing) throw new APIError(404, "Estimation not found");
    if (existing.clarification_id === input.id) return json({ estimation: estimationView(existing) });
    const now = new Date().toISOString();
    const updated = await env.DB.prepare(`UPDATE pending_estimations SET user_clarification = ?, clarification_id = ?,
      state = 'pending', updated_at = ? WHERE id = ? AND tenant_id = ? RETURNING *`)
      .bind(input.text, input.id, now, existing.id, tenantId).first<EstimationRow>();
    if (!updated) throw new APIError(404, "Estimation not found");
    await recordFoodEvent(env, tenantId, `clarification:${input.id}`, "clarification_added", existing.id,
      { estimationId: existing.id, clarification: input.text });
    return json({ estimation: estimationView(updated) });
  }
  const estimationMatch = /^\/v1\/estimations\/([a-f0-9-]{36})$/.exec(path);
  if (estimationMatch && method === "DELETE") {
    const row = await findEstimation(env, tenantId, estimationMatch[1]);
    if (!row) throw new APIError(404, "Estimation not found");
    await env.DB.prepare("DELETE FROM pending_estimations WHERE id = ? AND tenant_id = ?")
      .bind(row.id, tenantId).run();
    if (row.photo_key) await env.PHOTOS?.delete(row.photo_key);
    return json({ ok: true });
  }
  const acceptMatch = /^\/v1\/estimations\/([a-f0-9-]{36})\/accept$/.exec(path);
  if (acceptMatch && method === "POST") {
    const row = await findEstimation(env, tenantId, acceptMatch[1]);
    if (!row || row.state !== "proposed" || !row.proposed_name || !row.proposed_serving || !row.proposed_kcal) {
      throw new APIError(409, "No estimate is ready for review");
    }
    const foodId = crypto.randomUUID();
    const logId = crypto.randomUUID();
    const now = new Date().toISOString();
    const portions = row.proposed_fruit_veg_portions ?? 0;
    await env.DB.batch([
      env.DB.prepare(`INSERT INTO foods
        (id, tenant_id, name, serving, kcal, fruit_veg_portions, source, use_count, last_used_at, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, 'agent', 1, ?, ?, ?)`).bind(foodId, tenantId, row.proposed_name,
          row.proposed_serving, row.proposed_kcal, portions, now, now, now),
      env.DB.prepare(`INSERT INTO food_logs
        (id, tenant_id, food_id, food_name, serving, quantity, kcal, fruit_veg_portions, local_date, logged_at)
        VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?, ?)`).bind(logId, tenantId, foodId,
          row.proposed_name, row.proposed_serving, row.proposed_kcal, portions, row.local_date, now),
      env.DB.prepare("DELETE FROM pending_estimations WHERE id = ? AND tenant_id = ?").bind(row.id, tenantId),
      env.DB.prepare(`INSERT INTO food_events (tenant_id, event_key, kind, subject_id, payload_json, created_at)
        VALUES (?, ?, 'food_logged', ?, ?, ?)`).bind(tenantId, `log:${logId}`, logId,
          JSON.stringify({ id: logId, foodId, foodName: row.proposed_name, serving: row.proposed_serving,
            quantity: 1, kcal: row.proposed_kcal, fruitVegPortions: portions,
            localDate: row.local_date, loggedAt: now }), now),
      webhookDeliveryInsert(env, tenantId, `log:${logId}`),
    ]);
    await notifyFoodEvent(env, tenantId);
    if (row.photo_key) await env.PHOTOS?.delete(row.photo_key);
    return json({ foodId, logId });
  }
  return json({ error: "Not found" }, 404);
}
