import { afterEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../src/api";
import type { Principal } from "../src/auth";
import { deliverWebhookEvents, subscribeWebhookEvent, unsubscribeWebhookEvent } from "../src/mcpWebhookEvents";

afterEach(() => vi.unstubAllGlobals());

describe("MCP 2.0 webhook events", () => {
  it("verifies the callback, signs deliveries, and unsubscribes idempotently", async () => {
    const secret = `whsec_${Buffer.alloc(32, 7).toString("base64")}`;
    const principal: Principal = { tenantId: "tenant", tokenHash: "token-hash", kind: "mcp",
      scopes: ["food:read", "food:write"] };
    let subscriptionId = "";
    let deliveries = 0;
    let deleted = 0;
    let savedSecret: string | null = null;
    let phase: "verify" | "deliver" = "verify";
    const signed = async (request: { headers: Headers; text: () => Promise<string> }): Promise<void> => {
      const id = request.headers.get("webhook-id")!;
      const timestamp = request.headers.get("webhook-timestamp")!;
      const body = await request.text();
      const key = await crypto.subtle.importKey("raw", Buffer.alloc(32, 7),
        { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
      const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key,
        new TextEncoder().encode(`${id}.${timestamp}.${body}`)));
      expect(request.headers.get("webhook-signature")).toBe(`v1,${Buffer.from(mac).toString("base64")}`);
      expect(request.headers.get("x-mcp-subscription-id")).toBe(subscriptionId);
    };
    vi.stubGlobal("fetch", vi.fn(async (url: string, options: RequestInit) => {
      expect(url).toBe("https://events.chatgpt.com/00food");
      expect(options.redirect).toBe("error");
      const request = new Request(url, options);
      if (phase === "verify") {
        subscriptionId = request.headers.get("x-mcp-subscription-id")!;
        await signed(request.clone());
        const body = await request.json() as { type: string; challenge: string };
        expect(body.type).toBe("verification");
        return Response.json({ challenge: body.challenge });
      }
      await signed(request.clone());
      const body = await request.json() as { eventId: string; name: string; data: Record<string, unknown> };
      expect(body.eventId).toMatch(/^evt_42_/);
      expect(body.name).toBe("food.clarification_added");
      expect(body.data).toEqual({ estimation_id: "estimate-1", clarification: "It contains yogurt" });
      deliveries++;
      return new Response(null, { status: 202 });
    }));
    const db = {
      prepare(sql: string) {
        return {
          bind(..._args: unknown[]) {
            return {
              async first<T>(): Promise<T | null> {
                if (sql.includes("FROM mcp_event_subscriptions WHERE id")) return savedSecret
                  ? { id: subscriptionId, callback_url: "https://events.chatgpt.com/00food",
                    signing_secret: savedSecret, name: "food.clarification_added" } as T : null;
                if (sql.includes("COUNT(*) AS n")) return { n: 0 } as T;
                if (sql.includes("MIN(d.next_attempt_at)")) return { due: null } as T;
                throw Error(`Unexpected SELECT ${sql}`);
              },
              async all<T>(): Promise<{ results: T[] }> {
                if (sql.includes("FROM mcp_event_deliveries d")) return { results: [{
                  id: "delivery-1", event_id: 42, attempts: 0, subscription_id: subscriptionId,
                  kind: "clarification_added", subject_id: "estimate-1", payload_json: JSON.stringify({ clarification: "It contains yogurt" }),
                  created_at: "2026-10-06T12:00:00Z", callback_url: "https://events.chatgpt.com/00food",
                  signing_secret: secret, name: "food.clarification_added",
                }] as T[] };
                throw Error(`Unexpected query ${sql}`);
              },
              async run(): Promise<{ meta: { changes: number } }> {
                if (sql.startsWith("INSERT INTO mcp_event_subscriptions")) savedSecret = secret;
                if (sql.startsWith("DELETE FROM mcp_event_subscriptions")) deleted++;
                return { meta: { changes: 1 } };
              },
            };
          },
        };
      },
    };
    const env = { DB: db as unknown as D1Database } as Env;
    const input = { name: "food.clarification_added", arguments: {},
      delivery: { mode: "webhook", url: "https://events.chatgpt.com/00food", secret } };
    const subscription = await subscribeWebhookEvent(env, principal, input) as { id: string; refreshBefore: string };
    expect(subscription.id).toBe(subscriptionId);
    expect(subscription.refreshBefore).toBeTruthy();
    const refresh = await subscribeWebhookEvent(env, principal, input) as { id: string };
    expect(refresh.id).toBe(subscription.id);
    expect(vi.mocked(fetch)).toHaveBeenCalledTimes(1);
    phase = "deliver";
    expect(await deliverWebhookEvents(env, principal.tenantId)).toBeNull();
    expect(deliveries).toBe(1);
    await unsubscribeWebhookEvent(env, principal, { ...input, delivery: { ...input.delivery, secret: undefined } });
    expect(deleted).toBe(1);
  });
});
