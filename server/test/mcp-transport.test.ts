import { describe, expect, it } from "vitest";
import { routeMcp } from "../src/mcp";
import type { Env } from "../src/api";
import type { Principal } from "../src/auth";

const env = { PUBLIC_ORIGIN: "https://api.00food.com" } as Env;
const agent: Principal = { tenantId: "tenant", kind: "mcp", tokenHash: "hash", scopes: ["food:read", "food:write"] };
const rpc = (method: string, params?: unknown) => routeMcp(new Request("https://api.00food.com/mcp", {
  method: "POST", body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) }), env, agent);

describe("MCP transport without a server stream", () => {
  it("refuses GET with 405 so clients fall back to request/response", async () => {
    const response = await routeMcp(new Request("https://api.00food.com/mcp", {
      headers: { accept: "text/event-stream" } }), env, agent);
    expect(response.status).toBe(405);
    expect(response.headers.get("allow")).toBe("POST");
  });

  it("does not advertise or accept resource subscriptions", async () => {
    const init = await (await rpc("initialize")).json() as { result: { capabilities: { resources: { subscribe: boolean } } } };
    expect(init.result.capabilities.resources.subscribe).toBe(false);
    const subscribe = await (await rpc("resources/subscribe", { uri: "food://events" })).json() as { error: { code: number } };
    expect(subscribe.error.code).toBe(-32601);
  });
});
