import { DurableObject } from "cloudflare:workers";
import { deliverDailyFeedbackEvents, deliverWebhookEvents } from "./mcpWebhookEvents";
import type { Env } from "./api";
import { deliverAgentResponsePushes } from "./agentResponsePush";

/// One object per account that sends queued MCP webhook deliveries from its
/// alarm, so an account's deliveries run one at a time and retry with backoff.
/// It holds no open connections: it runs only while an alarm is delivering.
export class FoodEventStream extends DurableObject<Env> {
  async fetch(request: Request): Promise<Response> {
    const path = new URL(request.url).pathname;
    if (!["/publish", "/publish-daily", "/publish-response"].includes(path)) return new Response(null, { status: 404 });
    const tenantId = request.headers.get("x-tenant-id");
    if (!tenantId) return new Response(null, { status: 400 });
    await this.ctx.storage.put("tenantId", tenantId);
    await this.ctx.storage.setAlarm(Date.now());
    return new Response(null, { status: 204 });
  }

  async alarm(): Promise<void> {
    const tenantId = await this.ctx.storage.get<string>("tenantId");
    if (!tenantId) return;
    const deliveries = await Promise.allSettled([
      deliverWebhookEvents(this.env, tenantId), deliverDailyFeedbackEvents(this.env, tenantId),
      deliverAgentResponsePushes(this.env, tenantId),
    ]);
    const due = deliveries.map(result => result.status === "fulfilled" ? result.value : Date.now() + 30000);
    if (deliveries.some(result => result.status === "rejected")) console.warn("MCP event delivery will retry");
    const next = due.filter((value): value is number => value !== null)
      .reduce<number | null>((earliest, value) => earliest === null ? value : Math.min(earliest, value), null);
    if (next) await this.ctx.storage.setAlarm(next);
  }
}
