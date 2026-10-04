import { z } from "zod";
import { tenantForPrincipal, type Principal } from "./auth";

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
});
const foodInput = z.strictObject({
  id: id.optional(), name: z.string().trim().min(1).max(120),
  serving: z.string().trim().min(1).max(80),
  kcal: z.number().int().min(1).max(5000),
  source: z.enum(["manual", "seed"]).default("manual"),
});
const logInput = z.strictObject({
  id: id.optional(), foodId: id, quantity: z.number().min(0.1).max(20).default(1),
  localDate: day,
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
});

type FoodRow = {
  id: string; name: string; serving: string; kcal: number; source: string;
  use_count: number; last_used_at: string | null; created_at: string; updated_at: string;
};
type LogRow = {
  id: string; food_id: string; food_name: string; serving: string;
  quantity: number; kcal: number; local_date: string; logged_at: string;
};
type ProfileRow = { height_cm: number; weight_kg: number; estimate_profile: string; deficit_kcal: number; updated_at: string };
type EstimationRow = {
  id: string; description: string; photo_key: string | null; state: string;
  proposed_name: string | null; proposed_serving: string | null; proposed_kcal: number | null;
  agent_note: string | null; local_date: string; created_at: string; updated_at: string;
};

export const foodView = (r: FoodRow) => ({
  id: r.id, name: r.name, serving: r.serving, kcal: r.kcal, source: r.source,
  useCount: r.use_count, lastUsedAt: r.last_used_at, createdAt: r.created_at, updatedAt: r.updated_at,
});
export const logView = (r: LogRow) => ({
  id: r.id, foodId: r.food_id, foodName: r.food_name, serving: r.serving,
  quantity: r.quantity, kcal: r.kcal, localDate: r.local_date, loggedAt: r.logged_at,
});
export const estimationView = (r: EstimationRow) => ({
  id: r.id, description: r.description, hasPhoto: !!r.photo_key, state: r.state,
  proposedName: r.proposed_name, proposedServing: r.proposed_serving, proposedKcal: r.proposed_kcal,
  agentNote: r.agent_note, localDate: r.local_date, createdAt: r.created_at, updatedAt: r.updated_at,
});
const profileView = (r: ProfileRow) => ({
  heightCm: r.height_cm, weightKg: r.weight_kg, estimateProfile: r.estimate_profile,
  deficitKcal: r.deficit_kcal, updatedAt: r.updated_at,
});

export const seedFoods = [
  { name: "Banana", serving: "1 medium", kcal: 105 },
  { name: "Apple", serving: "1 medium", kcal: 95 },
  { name: "Egg", serving: "1 large", kcal: 72 },
  { name: "Toast", serving: "1 slice", kcal: 85 },
  { name: "Oatmeal", serving: "1 bowl", kcal: 160 },
  { name: "Greek yogurt", serving: "1 cup", kcal: 130 },
  { name: "Coffee with milk", serving: "1 cup", kcal: 50 },
  { name: "Cappuccino", serving: "1 cup", kcal: 120 },
  { name: "Rice, cooked", serving: "1 cup", kcal: 205 },
  { name: "Pasta, cooked", serving: "1 cup", kcal: 220 },
  { name: "Chicken breast", serving: "100 g", kcal: 165 },
  { name: "Salmon", serving: "100 g", kcal: 208 },
  { name: "Mixed salad", serving: "1 bowl", kcal: 100 },
  { name: "Olive oil", serving: "1 tablespoon", kcal: 120 },
  { name: "Bread", serving: "1 slice", kcal: 90 },
  { name: "Cheese", serving: "1 slice", kcal: 110 },
  { name: "Pizza", serving: "1 slice", kcal: 285 },
  { name: "Dark chocolate", serving: "1 square", kcal: 55 },
  { name: "Beer", serving: "330 ml", kcal: 150 },
  { name: "Wine", serving: "150 ml", kcal: 125 },
];

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
  const result = await env.DB.prepare(`UPDATE pending_estimations SET state = 'proposed',
    proposed_name = ?, proposed_serving = ?, proposed_kcal = ?, agent_note = ?, updated_at = ?
    WHERE id = ? AND tenant_id = ?`).bind(
    parsed.name, parsed.serving, parsed.kcal, parsed.note, now, estimationId, tenantId,
  ).run();
  if (!result.meta.changes) fail(404, "Estimation not found");
  return json({ estimation: estimationView((await findEstimation(env, tenantId, estimationId))!) });
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
  if (path === "/v1/seeds" && method === "GET") return json({ foods: seedFoods });
  if (path === "/v1/snapshot" && method === "GET") {
    const [tenant, profile, foods, logs, estimations] = await Promise.all([
      env.DB.prepare("SELECT created_at FROM tenants WHERE id = ?").bind(tenantId).first<{ created_at: string }>(),
      env.DB.prepare("SELECT * FROM profiles WHERE tenant_id = ?").bind(tenantId).first<ProfileRow>(),
      env.DB.prepare("SELECT * FROM foods WHERE tenant_id = ? ORDER BY use_count DESC, last_used_at DESC, created_at DESC LIMIT 1000").bind(tenantId).all<FoodRow>(),
      env.DB.prepare("SELECT * FROM food_logs WHERE tenant_id = ? AND local_date >= date('now','-90 days') ORDER BY logged_at DESC LIMIT 5000").bind(tenantId).all<LogRow>(),
      env.DB.prepare("SELECT * FROM pending_estimations WHERE tenant_id = ? ORDER BY created_at DESC LIMIT 100").bind(tenantId).all<EstimationRow>(),
    ]);
    return json({ startedAt: tenant?.created_at ?? null, profile: profile ? profileView(profile) : null,
      foods: foods.results.map(foodView), logs: logs.results.map(logView),
      estimations: estimations.results.map(estimationView), serverTime: new Date().toISOString() });
  }
  if (path === "/v1/profile" && method === "PUT") {
    const input = profileInput.parse(await body(req));
    const now = new Date().toISOString();
    await env.DB.prepare(`INSERT INTO profiles (tenant_id, height_cm, weight_kg, estimate_profile, deficit_kcal, updated_at)
      VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(tenant_id) DO UPDATE SET
      height_cm=excluded.height_cm, weight_kg=excluded.weight_kg,
      estimate_profile=excluded.estimate_profile, deficit_kcal=excluded.deficit_kcal, updated_at=excluded.updated_at`)
      .bind(tenantId, input.heightCm, input.weightKg, input.estimateProfile, input.deficitKcal, now).run();
    return json({ profile: { ...input, updatedAt: now } });
  }
  if (path === "/v1/foods" && method === "POST") {
    const input = foodInput.parse(await body(req));
    const foodId = input.id || crypto.randomUUID();
    const existing = await env.DB.prepare("SELECT * FROM foods WHERE id = ? AND tenant_id = ?")
      .bind(foodId, tenantId).first<FoodRow>();
    if (existing) return json({ food: foodView(existing) }, 201);
    const count = await env.DB.prepare("SELECT COUNT(*) AS n FROM foods WHERE tenant_id = ?")
      .bind(tenantId).first<{ n: number }>();
    if ((count?.n ?? 0) >= 2000) throw new APIError(403, "Food library limit reached");
    const now = new Date().toISOString();
    await env.DB.prepare(`INSERT OR IGNORE INTO foods
      (id, tenant_id, name, serving, kcal, source, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)`).bind(foodId, tenantId, input.name, input.serving,
        input.kcal, input.source, now, now).run();
    const row = await env.DB.prepare("SELECT * FROM foods WHERE id = ? AND tenant_id = ?")
      .bind(foodId, tenantId).first<FoodRow>();
    if (!row) throw new APIError(409, "Food ID is already in use");
    return json({ food: foodView(row) }, 201);
  }
  if (path === "/v1/logs" && method === "POST") {
    const input = logInput.parse(await body(req));
    const food = await env.DB.prepare("SELECT * FROM foods WHERE id = ? AND tenant_id = ?")
      .bind(input.foodId, tenantId).first<FoodRow>();
    if (!food) throw new APIError(404, "Food not found");
    const logId = input.id || crypto.randomUUID();
    const existing = await env.DB.prepare("SELECT * FROM food_logs WHERE id = ? AND tenant_id = ?")
      .bind(logId, tenantId).first<LogRow>();
    if (existing) return json({ log: logView(existing) }, 201);
    const count = await env.DB.prepare("SELECT COUNT(*) AS n FROM food_logs WHERE tenant_id = ?")
      .bind(tenantId).first<{ n: number }>();
    if ((count?.n ?? 0) >= 10000) throw new APIError(403, "Food log limit reached");
    const now = new Date().toISOString();
    const calories = Math.max(1, Math.round(food.kcal * input.quantity));
    const result = await env.DB.prepare(`INSERT OR IGNORE INTO food_logs
      (id, tenant_id, food_id, food_name, serving, quantity, kcal, local_date, logged_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`).bind(logId, tenantId, food.id, food.name,
        food.serving, input.quantity, calories, input.localDate, now).run();
    if (result.meta.changes) {
      await env.DB.prepare(`UPDATE foods SET use_count = use_count + 1, last_used_at = ?
        WHERE id = ? AND tenant_id = ?`).bind(now, food.id, tenantId).run();
    }
    const row = await env.DB.prepare("SELECT * FROM food_logs WHERE id = ? AND tenant_id = ?")
      .bind(logId, tenantId).first<LogRow>();
    if (!row) throw new APIError(409, "Log ID is already in use");
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
    if (existing) return json({ estimation: estimationView(existing) }, 201);
    const count = await env.DB.prepare("SELECT COUNT(*) AS n FROM pending_estimations WHERE tenant_id = ?")
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
    try {
      await env.DB.prepare(`INSERT OR IGNORE INTO pending_estimations
        (id, tenant_id, description, photo_key, state, local_date, created_at, updated_at)
        VALUES (?, ?, ?, ?, 'pending', ?, ?, ?)`).bind(estimationId, tenantId, input.description,
          photoKey, input.localDate, now, now).run();
      const row = await findEstimation(env, tenantId, estimationId);
      if (!row) throw new APIError(409, "Estimation ID is already in use");
      return json({ estimation: estimationView(row) }, 201);
    } catch (error) {
      if (photoKey) await env.PHOTOS?.delete(photoKey);
      throw error;
    }
  }
  const photoMatch = /^\/v1\/estimations\/([a-f0-9-]{36})\/photo$/.exec(path);
  if (photoMatch && method === "PUT") {
    if (!env.PHOTOS) throw new APIError(503, "Photo storage is unavailable");
    const row = await findEstimation(env, tenantId, photoMatch[1]);
    if (!row || row.state !== "pending") throw new APIError(404, "Pending estimation not found");
    if (req.headers.get("content-type") !== "image/jpeg") fail(415, "Use a JPEG photo");
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
    return proposeEstimation(env, tenantId, existing.id, await body(req));
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
    await env.DB.batch([
      env.DB.prepare(`INSERT INTO foods
        (id, tenant_id, name, serving, kcal, source, use_count, last_used_at, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, 'agent', 1, ?, ?, ?)`).bind(foodId, tenantId, row.proposed_name,
          row.proposed_serving, row.proposed_kcal, now, now, now),
      env.DB.prepare(`INSERT INTO food_logs
        (id, tenant_id, food_id, food_name, serving, quantity, kcal, local_date, logged_at)
        VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?)`).bind(logId, tenantId, foodId,
          row.proposed_name, row.proposed_serving, row.proposed_kcal, row.local_date, now),
      env.DB.prepare("DELETE FROM pending_estimations WHERE id = ? AND tenant_id = ?").bind(row.id, tenantId),
    ]);
    if (row.photo_key) await env.PHOTOS?.delete(row.photo_key);
    return json({ foodId, logId });
  }
  return json({ error: "Not found" }, 404);
}
