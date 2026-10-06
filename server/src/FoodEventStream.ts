import { DurableObject } from "cloudflare:workers";
import { foodEventsUri } from "./foodEvents";
import { deliverWebhookEvents } from "./mcpWebhookEvents";
import type { Env } from "./api";

export class FoodEventStream extends DurableObject<Env> {
  private listeners = new Map<ReadableStreamDefaultController<Uint8Array>, { tokenHash: string; active: boolean;
    timeout: ReturnType<typeof setTimeout> }>();
  private readonly encoder = new TextEncoder();

  async fetch(request: Request): Promise<Response> {
    if (new URL(request.url).pathname === "/publish") {
      const tenantId = request.headers.get("x-tenant-id");
      if (!tenantId) return new Response(null, { status: 400 });
      await this.ctx.storage.put("tenantId", tenantId);
      await this.ctx.storage.setAlarm(Date.now());
      const notification = `data: ${JSON.stringify({ jsonrpc: "2.0", method: "notifications/resources/updated",
        params: { uri: foodEventsUri } })}\n\n`;
      for (const [listener, subscription] of this.listeners) {
        if (!subscription.active) continue;
        try { listener.enqueue(this.encoder.encode(notification)); }
        catch {
          const subscription = this.listeners.get(listener);
          if (subscription) clearTimeout(subscription.timeout);
          this.listeners.delete(listener);
        }
      }
      return new Response(null, { status: 204 });
    }
    if (new URL(request.url).pathname === "/activate") {
      const tokenHash = request.headers.get("x-token-hash");
      for (const subscription of this.listeners.values()) {
        if (subscription.tokenHash === tokenHash) subscription.active = true;
      }
      return new Response(null, { status: 204 });
    }
    if (new URL(request.url).pathname === "/close" || new URL(request.url).pathname === "/close-all") {
      const tokenHash = request.headers.get("x-token-hash");
      for (const [listener, subscription] of this.listeners) {
        if (new URL(request.url).pathname === "/close-all" || subscription.tokenHash === tokenHash) {
          clearTimeout(subscription.timeout);
          try { listener.close(); } catch { /* already disconnected */ }
          this.listeners.delete(listener);
        }
      }
      return new Response(null, { status: 204 });
    }
    if (new URL(request.url).pathname !== "/listen") return new Response(null, { status: 404 });
    const tokenHash = request.headers.get("x-token-hash");
    if (!tokenHash) return new Response(null, { status: 400 });
    let listener: ReadableStreamDefaultController<Uint8Array>;
    const stream = new ReadableStream<Uint8Array>({
      start: controller => {
        listener = controller;
        controller.enqueue(this.encoder.encode(": connected\n\n"));
        // Reconnect through the Worker so authorization is checked regularly.
        const timeout = setTimeout(() => {
          this.listeners.delete(controller);
          try { controller.close(); } catch { /* already disconnected */ }
        }, 15 * 60 * 1000);
        this.listeners.set(controller, { tokenHash, active: request.headers.get("x-active") === "true", timeout });
      },
      cancel: () => {
        const subscription = this.listeners.get(listener);
        if (subscription) clearTimeout(subscription.timeout);
        this.listeners.delete(listener);
      },
    });
    return new Response(stream, { headers: { "Content-Type": "text/event-stream", "Cache-Control": "no-cache, no-transform",
      "Connection": "keep-alive" } });
  }

  async alarm(): Promise<void> {
    const tenantId = await this.ctx.storage.get<string>("tenantId");
    if (!tenantId) return;
    const next = await deliverWebhookEvents(this.env, tenantId);
    if (next) await this.ctx.storage.setAlarm(next);
  }
}
