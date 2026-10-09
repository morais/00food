import { z } from "zod";
import type { Env } from "./api";
import { constantTimeEqual, sha256Hex, type Principal } from "./auth";

const eventNames = {
  food_logged: "food.logged",
  estimate_requested: "food.estimate_requested",
  clarification_added: "food.clarification_added",
  daily_feedback_requested: "day.feedback_requested",
} as const;
type EventName = typeof eventNames[keyof typeof eventNames];
type FoodEventKind = "food_logged" | "estimate_requested" | "clarification_added";

const emptyArguments = { type: "object", properties: {}, additionalProperties: false };
const schema = (properties: Record<string, unknown>, required: string[]) =>
  ({ type: "object", properties, required, additionalProperties: false });
const string = { type: "string" };

export const eventDefinitions = [
  { name: "food.logged", description: "A food serving was logged. Use this to track food intake, not to estimate an already approved food.",
    delivery: ["webhook"], inputSchema: emptyArguments,
    payloadSchema: schema({ log_id: string, food_id: string, food_name: string, kcal: { type: "integer" },
      fruit_veg_portions: { type: "integer" }, local_date: string },
      ["log_id", "food_id", "food_name", "kcal", "local_date"]) },
  { name: "food.estimate_requested", description: "A new food description or photo needs a calorie estimate. Call get_pending_food and view_food_photo when available.",
    delivery: ["webhook"], inputSchema: emptyArguments,
    payloadSchema: schema({ estimation_id: string, description: string, has_photo: { type: "boolean" } },
      ["estimation_id", "description", "has_photo"]) },
  { name: "food.clarification_added", description: "The person added context to a pending food estimate. Read the pending food and revise the estimate.",
    delivery: ["webhook"], inputSchema: emptyArguments,
    payloadSchema: schema({ estimation_id: string, clarification: string }, ["estimation_id", "clarification"]) },
  { name: "day.feedback_requested", description: "A completed day is ready for a short food and activity reflection. Call get_daily_feedback_request for its seven-day context and reviewGuidance, then submit_daily_feedback. Cover protein sources and diet balance too; capped produce and recorded water totals are not exact total intake.",
    delivery: ["webhook"], inputSchema: emptyArguments,
    payloadSchema: schema({ request_id: string, local_date: string }, ["request_id", "local_date"]) },
];

// MCP clients may attach transport metadata to method parameters. Validate the
// fields we use, while ignoring extensions outside the event's filter arguments.
const subscriptionInput = z.object({
  name: z.enum(["food.logged", "food.estimate_requested", "food.clarification_added", "day.feedback_requested"]),
  arguments: z.strictObject({}).default({}),
  delivery: z.object({ mode: z.literal("webhook"), url: z.url(), secret: z.string().optional() }),
  cursor: z.null().optional(), ttlMs: z.number().int().positive().optional().nullable(),
});

export class McpEventsError extends Error {
  constructor(public code: number, message: string, public reason?: string) { super(message); }
}

type SubscriptionRow = { id: string; callback_url: string; signing_secret: string; name: EventName };
type DeliveryRow = { id: string; event_id: number; kind: FoodEventKind; subject_id: string;
  payload_json: string; created_at: string; attempts: number; subscription_id: string;
  callback_url: string; signing_secret: string; previous_secret: string | null;
  previous_secret_expires_at: string | null; name: EventName };

// Only ChatGPT-owned callback hosts are accepted. This also prevents redirects,
// private IPs, and DNS rebinding from reaching arbitrary destinations.
function validateCallback(raw: string): URL {
  let url: URL;
  try { url = new URL(raw); } catch { throw new McpEventsError(-32602, "Invalid callback URL"); }
  const host = url.hostname.toLowerCase();
  const allowed = ["chatgpt.com", "openai.com"].some(domain => host === domain || host.endsWith(`.${domain}`));
  if (url.protocol !== "https:" || !allowed || url.port && url.port !== "443" || url.username || url.password ||
      url.hash || raw.length > 2000) throw new McpEventsError(-32602, "Unsupported callback URL");
  return url;
}

function secretBytes(secret: string): Uint8Array {
  if (!secret.startsWith("whsec_")) throw new McpEventsError(-32602, "Invalid signing secret");
  try {
    const bytes = Uint8Array.from(atob(secret.slice(6)), char => char.charCodeAt(0));
    if (bytes.length >= 24 && bytes.length <= 64) return bytes;
  } catch { /* invalid base64 */ }
  throw new McpEventsError(-32602, "Invalid signing secret");
}

async function signedHeaders(secret: string, messageId: string, body: string, subscriptionId: string,
                             previousSecret?: string | null): Promise<Headers> {
  const timestamp = String(Math.floor(Date.now() / 1000));
  const input = new TextEncoder().encode(`${messageId}.${timestamp}.${body}`);
  const signatures = await Promise.all([secret, ...(previousSecret ? [previousSecret] : [])].map(async value => {
    const key = await crypto.subtle.importKey("raw", new Uint8Array(secretBytes(value)).buffer,
      { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    const signature = new Uint8Array(await crypto.subtle.sign("HMAC", key, input));
    return `v1,${btoa(String.fromCharCode(...signature))}`;
  }));
  return new Headers({ "Content-Type": "application/json", "webhook-id": messageId,
    "webhook-timestamp": timestamp, "webhook-signature": signatures.join(" "),
    "X-MCP-Subscription-Id": subscriptionId });
}

async function verifyCallback(url: URL, secret: string, id: string): Promise<void> {
  const challenge = crypto.randomUUID();
  const body = JSON.stringify({ type: "verification", challenge });
  let response: Response;
  try {
    response = await fetch(url.toString(), { method: "POST", redirect: "manual", signal: AbortSignal.timeout(10_000),
      headers: await signedHeaders(secret, `msg_verification_${crypto.randomUUID()}`, body, id), body });
  } catch (cause) {
    const name = cause instanceof Error ? cause.name : "unknown";
    const detail = cause instanceof Error ? cause.message
      .replace(/https?:\/\/\S+/gi, "[url]")
      .replace(/[A-Za-z0-9_-]{20,}/g, "[redacted]")
      .slice(0, 160) : "unknown";
    console.warn("MCP callback verification transport failed", { host: url.hostname, name, detail });
    throw new McpEventsError(-32015, "Callback verification failed",
      name === "TimeoutError" || name === "AbortError" ? "timeout" : "challenge_failed");
  }
  if (!response.ok) throw new McpEventsError(-32015, "Callback verification failed", "challenge_failed");
  let echoed: unknown;
  try { echoed = (await response.json() as { challenge?: unknown }).challenge; }
  catch { throw new McpEventsError(-32015, "Callback verification failed", "challenge_failed"); }
  if (typeof echoed !== "string" || !constantTimeEqual(challenge, echoed)) {
    throw new McpEventsError(-32015, "Callback verification failed", "challenge_failed");
  }
}

async function subscriptionId(principal: Principal, name: EventName, callbackUrl: string): Promise<string> {
  return `sub_${(await sha256Hex(`${principal.tokenHash}\n${name}\n{}\n${callbackUrl}`)).slice(0, 40)}`;
}

export async function subscribeWebhookEvent(env: Env, principal: Principal, raw: unknown): Promise<unknown> {
  const input = subscriptionInput.parse(raw);
  const requiredScope = input.name === "day.feedback_requested" ? "daily:read" : "food:read";
  if (!principal.scopes.includes(requiredScope)) throw new McpEventsError(-32003, `${requiredScope} scope required`);
  const url = validateCallback(input.delivery.url);
  if (!input.delivery.secret) throw new McpEventsError(-32602, "Signing secret required");
  secretBytes(input.delivery.secret);
  const id = await subscriptionId(principal, input.name, url.toString());
  const existing = await env.DB.prepare("SELECT id, callback_url, signing_secret, name FROM mcp_event_subscriptions WHERE id = ? AND tenant_id = ?")
    .bind(id, principal.tenantId).first<SubscriptionRow>();
  const count = await env.DB.prepare("SELECT COUNT(*) AS n FROM mcp_event_subscriptions WHERE tenant_id = ?")
    .bind(principal.tenantId).first<{ n: number }>();
  if (!existing && (count?.n ?? 0) >= 20) throw new McpEventsError(-32000, "Subscription limit reached");
  // A changed callback or signing key is verified before it can receive food data.
  if (!existing || existing.signing_secret !== input.delivery.secret) {
    await verifyCallback(url, input.delivery.secret, id);
  }
  const now = new Date();
  const ttl = Math.min(input.ttlMs ?? 7 * 86400000, 7 * 86400000);
  const expiresAt = new Date(now.getTime() + ttl).toISOString();
  const previousSecretExpiresAt = new Date(now.getTime() + 5 * 60000).toISOString();
  await env.DB.prepare(`INSERT INTO mcp_event_subscriptions
    (id, tenant_id, token_hash, name, arguments_json, callback_url, signing_secret, expires_at, created_at, updated_at)
    VALUES (?, ?, ?, ?, '{}', ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
      previous_secret = CASE WHEN signing_secret != excluded.signing_secret THEN signing_secret ELSE previous_secret END,
      previous_secret_expires_at = CASE WHEN signing_secret != excluded.signing_secret THEN ? ELSE previous_secret_expires_at END,
      signing_secret = excluded.signing_secret,
      expires_at = excluded.expires_at, updated_at = excluded.updated_at`)
    .bind(id, principal.tenantId, principal.tokenHash, input.name, url.toString(), input.delivery.secret,
      expiresAt, now.toISOString(), now.toISOString(), previousSecretExpiresAt).run();
  return { id, refreshBefore: expiresAt, cursor: null, truncated: false };
}

export async function unsubscribeWebhookEvent(env: Env, principal: Principal, raw: unknown): Promise<unknown> {
  const input = subscriptionInput.parse(raw);
  const requiredScope = input.name === "day.feedback_requested" ? "daily:read" : "food:read";
  if (!principal.scopes.includes(requiredScope)) throw new McpEventsError(-32003, `${requiredScope} scope required`);
  const url = validateCallback(input.delivery.url);
  const id = await subscriptionId(principal, input.name, url.toString());
  await env.DB.prepare("DELETE FROM mcp_event_subscriptions WHERE id = ? AND tenant_id = ? AND token_hash = ?")
    .bind(id, principal.tenantId, principal.tokenHash).run();
  return {};
}

export function webhookDeliveryInsert(env: Env, tenantId: string, eventKey: string): D1PreparedStatement {
  const now = new Date().toISOString();
  return env.DB.prepare(`INSERT OR IGNORE INTO mcp_event_deliveries
    (id, tenant_id, event_id, subscription_id, next_attempt_at)
    SELECT 'delivery:' || e.id || ':' || s.id, e.tenant_id, e.id, s.id, ?
    FROM food_events e JOIN mcp_event_subscriptions s ON s.tenant_id = e.tenant_id
    JOIN credentials c ON c.token_hash = s.token_hash
    WHERE e.tenant_id = ? AND e.event_key = ?
      AND s.name = CASE e.kind
        WHEN 'food_logged' THEN 'food.logged'
        WHEN 'estimate_requested' THEN 'food.estimate_requested'
        WHEN 'clarification_added' THEN 'food.clarification_added' END
      AND s.created_at <= e.created_at
      AND s.expires_at > ? AND c.revoked_at IS NULL AND c.expires_at > ?
      AND instr(' ' || c.scopes || ' ', ' food:read ') > 0`)
    .bind(now, tenantId, eventKey, now, now);
}

export function dailyFeedbackDeliveryInsert(env: Env, tenantId: string, requestId: string): D1PreparedStatement {
  const now = new Date().toISOString();
  return env.DB.prepare(`INSERT OR IGNORE INTO daily_feedback_deliveries
    (id, tenant_id, request_id, subscription_id, next_attempt_at)
    SELECT 'daily:' || r.id || ':' || s.id, r.tenant_id, r.id, s.id, ?
    FROM daily_feedback_requests r JOIN mcp_event_subscriptions s ON s.tenant_id = r.tenant_id
    JOIN credentials c ON c.token_hash = s.token_hash
    WHERE r.tenant_id = ? AND r.id = ? AND s.name = 'day.feedback_requested'
      AND s.created_at <= r.created_at AND s.expires_at > ?
      AND c.revoked_at IS NULL AND c.expires_at > ?
      AND instr(' ' || c.scopes || ' ', ' daily:read ') > 0`)
    .bind(now, tenantId, requestId, now, now);
}

function eventData(row: DeliveryRow): unknown {
  const data = JSON.parse(row.payload_json) as Record<string, unknown>;
  switch (row.kind) {
  case "food_logged": return { log_id: row.subject_id, food_id: data.foodId, food_name: data.foodName,
    kcal: data.kcal, fruit_veg_portions: data.fruitVegPortions ?? 0, local_date: data.localDate };
  case "estimate_requested": return { estimation_id: row.subject_id, description: data.description,
    has_photo: data.hasPhoto };
  case "clarification_added": return { estimation_id: row.subject_id, clarification: data.clarification };
  }
}

export async function deliverWebhookEvents(env: Env, tenantId: string): Promise<number | null> {
  const now = new Date().toISOString();
  const rows = await env.DB.prepare(`SELECT d.id, d.event_id, d.attempts, d.subscription_id,
    e.kind, e.subject_id, e.payload_json, e.created_at, s.callback_url, s.signing_secret,
    s.previous_secret, s.previous_secret_expires_at, s.name
    FROM mcp_event_deliveries d
    JOIN food_events e ON e.id = d.event_id
    JOIN mcp_event_subscriptions s ON s.id = d.subscription_id
    JOIN credentials c ON c.token_hash = s.token_hash
    WHERE d.tenant_id = ? AND d.delivered_at IS NULL AND d.failed_at IS NULL
      AND d.next_attempt_at <= ? AND s.expires_at > ? AND c.revoked_at IS NULL AND c.expires_at > ?
      AND instr(' ' || c.scopes || ' ', ' food:read ') > 0
    ORDER BY d.event_id ASC LIMIT 10`).bind(tenantId, now, now, now).all<DeliveryRow>();
  for (const row of rows.results) {
    const eventId = `evt_${row.event_id}_${row.subscription_id.slice(4, 16)}`;
    const body = JSON.stringify({ eventId, name: row.name, timestamp: row.created_at,
      data: eventData(row), cursor: null });
    let status = 0;
    try {
      const url = validateCallback(row.callback_url);
      const response = await fetch(url.toString(), { method: "POST", redirect: "manual", signal: AbortSignal.timeout(10_000),
        headers: await signedHeaders(row.signing_secret, eventId, body, row.subscription_id,
          row.previous_secret_expires_at && row.previous_secret_expires_at > new Date().toISOString()
            ? row.previous_secret : null), body });
      status = response.status;
    } catch { /* retry transient network failure */ }
    if (status >= 200 && status < 300) {
      await env.DB.prepare("UPDATE mcp_event_deliveries SET delivered_at = ?, attempts = attempts + 1 WHERE id = ?")
        .bind(new Date().toISOString(), row.id).run();
    } else if (status === 410 || status === 413 || status >= 400 && status < 500 && status !== 429 || row.attempts >= 4) {
      await env.DB.prepare("UPDATE mcp_event_deliveries SET failed_at = ?, attempts = attempts + 1 WHERE id = ?")
        .bind(new Date().toISOString(), row.id).run();
    } else {
      const delay = Math.min(3600000, 30000 * 2 ** row.attempts);
      await env.DB.prepare("UPDATE mcp_event_deliveries SET next_attempt_at = ?, attempts = attempts + 1 WHERE id = ?")
        .bind(new Date(Date.now() + delay).toISOString(), row.id).run();
    }
  }
  const next = await env.DB.prepare(`SELECT MIN(d.next_attempt_at) AS due FROM mcp_event_deliveries d
    JOIN mcp_event_subscriptions s ON s.id = d.subscription_id
    JOIN credentials c ON c.token_hash = s.token_hash
    WHERE d.tenant_id = ? AND d.delivered_at IS NULL AND d.failed_at IS NULL
      AND s.expires_at > ? AND c.revoked_at IS NULL AND c.expires_at > ?
      AND instr(' ' || c.scopes || ' ', ' food:read ') > 0`)
    .bind(tenantId, new Date().toISOString(), new Date().toISOString()).first<{ due: string | null }>();
  return next?.due ? Math.max(Date.now() + 1000, Date.parse(next.due)) : null;
}

type DailyDeliveryRow = { id: string; request_id: string; local_date: string; created_at: string;
  attempts: number; subscription_id: string; callback_url: string; signing_secret: string;
  previous_secret: string | null; previous_secret_expires_at: string | null };

export async function deliverDailyFeedbackEvents(env: Env, tenantId: string): Promise<number | null> {
  const now = new Date().toISOString();
  const rows = await env.DB.prepare(`SELECT d.id, d.request_id, d.attempts, d.subscription_id,
    r.local_date, r.created_at, s.callback_url, s.signing_secret,
    s.previous_secret, s.previous_secret_expires_at
    FROM daily_feedback_deliveries d
    JOIN daily_feedback_requests r ON r.id = d.request_id
    JOIN mcp_event_subscriptions s ON s.id = d.subscription_id
    JOIN credentials c ON c.token_hash = s.token_hash
    WHERE d.tenant_id = ? AND d.delivered_at IS NULL AND d.failed_at IS NULL
      AND d.next_attempt_at <= ? AND s.expires_at > ? AND c.revoked_at IS NULL AND c.expires_at > ?
      AND instr(' ' || c.scopes || ' ', ' daily:read ') > 0
    ORDER BY r.created_at ASC LIMIT 10`).bind(tenantId, now, now, now).all<DailyDeliveryRow>();
  for (const row of rows.results) {
    const eventId = `evt_daily_${row.request_id.replaceAll("-", "")}_${row.subscription_id.slice(4, 16)}`;
    const payload = JSON.stringify({ eventId, name: "day.feedback_requested", timestamp: row.created_at,
      data: { request_id: row.request_id, local_date: row.local_date }, cursor: null });
    let status = 0;
    try {
      const url = validateCallback(row.callback_url);
      const response = await fetch(url.toString(), { method: "POST", redirect: "manual", signal: AbortSignal.timeout(10_000),
        headers: await signedHeaders(row.signing_secret, eventId, payload, row.subscription_id,
          row.previous_secret_expires_at && row.previous_secret_expires_at > new Date().toISOString()
            ? row.previous_secret : null), body: payload });
      status = response.status;
    } catch { /* retry transient network failure */ }
    if (status >= 200 && status < 300) {
      await env.DB.prepare("UPDATE daily_feedback_deliveries SET delivered_at = ?, attempts = attempts + 1 WHERE id = ?")
        .bind(new Date().toISOString(), row.id).run();
    } else if (status === 410 || status === 413 || status >= 400 && status < 500 && status !== 429 || row.attempts >= 4) {
      await env.DB.prepare("UPDATE daily_feedback_deliveries SET failed_at = ?, attempts = attempts + 1 WHERE id = ?")
        .bind(new Date().toISOString(), row.id).run();
    } else {
      const delay = Math.min(3600000, 30000 * 2 ** row.attempts);
      await env.DB.prepare("UPDATE daily_feedback_deliveries SET next_attempt_at = ?, attempts = attempts + 1 WHERE id = ?")
        .bind(new Date(Date.now() + delay).toISOString(), row.id).run();
    }
  }
  const next = await env.DB.prepare(`SELECT MIN(d.next_attempt_at) AS due FROM daily_feedback_deliveries d
    JOIN mcp_event_subscriptions s ON s.id = d.subscription_id
    JOIN credentials c ON c.token_hash = s.token_hash
    WHERE d.tenant_id = ? AND d.delivered_at IS NULL AND d.failed_at IS NULL
      AND s.expires_at > ? AND c.revoked_at IS NULL AND c.expires_at > ?
      AND instr(' ' || c.scopes || ' ', ' daily:read ') > 0`)
    .bind(tenantId, new Date().toISOString(), new Date().toISOString()).first<{ due: string | null }>();
  return next?.due ? Math.max(Date.now() + 1000, Date.parse(next.due)) : null;
}
