import type { Env } from "./api";
import { webhookDeliveryInsert } from "./mcpWebhookEvents";

export const foodEventsUri = "food://events";

type FoodEventRow = { id: number; kind: string; subject_id: string; payload_json: string; created_at: string };

const viewEvent = (row: FoodEventRow) => ({
  id: row.id, kind: row.kind, subjectId: row.subject_id,
  data: JSON.parse(row.payload_json), createdAt: row.created_at,
});

export async function listFoodEvents(env: Env, tenantId: string, after = 0, limit = 100): Promise<unknown> {
  const rows = await env.DB.prepare(`SELECT id, kind, subject_id, payload_json, created_at FROM food_events
    WHERE tenant_id = ? AND id > ? ORDER BY id ASC LIMIT ?`).bind(tenantId, after, limit).all<FoodEventRow>();
  return { events: rows.results.map(viewEvent), nextCursor: rows.results.at(-1)?.id ?? after };
}

export async function recentFoodEvents(env: Env, tenantId: string): Promise<unknown> {
  const rows = await env.DB.prepare(`SELECT id, kind, subject_id, payload_json, created_at FROM food_events
    WHERE tenant_id = ? ORDER BY id DESC LIMIT 100`).bind(tenantId).all<FoodEventRow>();
  return { events: rows.results.reverse().map(viewEvent), nextCursor: rows.results.at(-1)?.id ?? 0 };
}

export async function recordFoodEvent(env: Env, tenantId: string, eventKey: string, kind: string,
                                      subjectId: string, data: unknown): Promise<void> {
  const [event, deliveries] = await env.DB.batch([env.DB.prepare(`INSERT OR IGNORE INTO food_events
    (tenant_id, event_key, kind, subject_id, payload_json, created_at) VALUES (?, ?, ?, ?, ?, ?)`)
    .bind(tenantId, eventKey, kind, subjectId, JSON.stringify(data), new Date().toISOString()),
  webhookDeliveryInsert(env, tenantId, eventKey)]);
  // A replayed request finds its event already recorded; nobody needs telling again.
  if (!event.meta.changes) return;
  await notifyFoodEvent(env, tenantId, deliveries.meta.changes > 0);
}

/// Wakes the account's event object only when it has work: webhook deliveries
/// to send, or a subscribed stream listening for resource updates. Accounts
/// without a connected agent cost no Durable Object request or alarm.
export async function notifyFoodEvent(env: Env, tenantId: string, queuedDeliveries: boolean): Promise<void> {
  if (!env.FOOD_EVENTS) return;
  try {
    const streaming = !queuedDeliveries && await env.DB.prepare(
      "SELECT 1 FROM mcp_resource_subscriptions WHERE tenant_id = ? LIMIT 1").bind(tenantId).first();
    if (!queuedDeliveries && !streaming) return;
    await env.FOOD_EVENTS.getByName(tenantId).fetch("https://events.internal/publish", {
      method: "POST", headers: { "x-tenant-id": tenantId, "x-deliver": queuedDeliveries ? "true" : "false" },
    });
  } catch (cause) {
    // The D1 event journal is authoritative; connected clients can catch up by cursor.
    console.warn("Food event notification failed", cause instanceof Error ? cause.message : "unknown error");
  }
}

/// Daily feedback has no stream notification, only webhooks, so the object is
/// woken only when a delivery was queued.
export async function notifyDailyFeedbackEvent(env: Env, tenantId: string, queuedDeliveries: boolean): Promise<void> {
  if (!env.FOOD_EVENTS || !queuedDeliveries) return;
  try {
    await env.FOOD_EVENTS.getByName(tenantId).fetch("https://events.internal/publish-daily", {
      method: "POST", headers: { "x-tenant-id": tenantId },
    });
  } catch (cause) {
    // Pending requests remain available through the MCP list tool on reconnect.
    console.warn("Daily feedback event notification failed", cause instanceof Error ? cause.message : "unknown error");
  }
}

export async function closeFoodEventStream(env: Env, tenantId: string, tokenHash: string): Promise<void> {
  if (!env.FOOD_EVENTS) return;
  try {
    await env.FOOD_EVENTS.getByName(tenantId).fetch("https://events.internal/close", {
      method: "POST", headers: { "x-token-hash": tokenHash },
    });
  } catch (cause) {
    console.warn("Closing MCP event stream failed", cause instanceof Error ? cause.message : "unknown error");
  }
}

export async function closeAllFoodEventStreams(env: Env, tenantId: string): Promise<void> {
  if (!env.FOOD_EVENTS) return;
  try {
    await env.FOOD_EVENTS.getByName(tenantId).fetch("https://events.internal/close-all", { method: "POST" });
  } catch (cause) {
    console.warn("Closing account event streams failed", cause instanceof Error ? cause.message : "unknown error");
  }
}
