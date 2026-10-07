import { describe, expect, it } from "vitest";
import { routeMcp } from "../src/mcp";
import { verifiedClientName } from "../src/oauth";
import type { Env } from "../src/api";
import type { Principal } from "../src/auth";

const env = { PUBLIC_ORIGIN: "https://api.00food.com" } as Env;
const foodOnly: Principal = {
  tenantId: "tenant", kind: "mcp", tokenHash: "hash", scopes: ["food:read", "food:write"],
};
const request = (method: string, params?: unknown) => new Request("https://api.00food.com/mcp", {
  method: "POST",
  headers: { "MCP-Protocol-Version": "2026-07-28" },
  body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
});

describe("MCP daily feedback scope upgrade", () => {
  it("recognizes only ChatGPT's exact stable callback", () => {
    const configured = {
      MCP_VERIFIED_CLIENTS: '{"https://chatgpt.com/connector_platform_oauth_redirect":"ChatGPT"}',
    } as Env;
    expect(verifiedClientName(configured, "https://chatgpt.com/connector_platform_oauth_redirect"))
      .toBe("ChatGPT");
    expect(verifiedClientName(configured, "https://chatgpt.com.evil.example/connector_platform_oauth_redirect"))
      .toBeUndefined();
    expect(verifiedClientName(configured, "https://chatgpt.com/connector_platform_oauth_redirect?next=evil"))
      .toBeUndefined();
  });

  it("declares daily permissions on the relevant tools", async () => {
    const response = await routeMcp(request("tools/list"), env, foodOnly);
    const payload = await response.json() as { result: { tools: Array<{
      name: string; securitySchemes: Array<{ type: string; scopes: string[] }> }> } };
    const scopes = (name: string) => payload.result.tools.find(tool => tool.name === name)?.securitySchemes[0].scopes;
    expect(scopes("list_pending_foods")).toEqual(["food:read"]);
    expect(scopes("list_pending_daily_feedback")).toEqual(["daily:read"]);
    expect(scopes("get_daily_feedback_request")).toEqual(["daily:read"]);
    expect(scopes("submit_daily_feedback")).toEqual(["daily:write"]);
  });

  it("asks ChatGPT to reauthorize before returning Health context", async () => {
    const response = await routeMcp(request("tools/call", {
      name: "get_daily_feedback_request", arguments: { id: crypto.randomUUID() },
    }), env, foodOnly);
    const payload = await response.json() as { result: {
      isError: boolean; _meta: { "mcp/www_authenticate": string[] } } };
    expect(response.status).toBe(200);
    expect(payload.result.isError).toBe(true);
    expect(payload.result._meta["mcp/www_authenticate"][0])
      .toContain('scope="food:read food:write daily:read"');
  });
});
