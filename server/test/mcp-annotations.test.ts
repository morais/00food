import { describe, expect, it } from "vitest";
import type { Env } from "../src/api";
import type { Principal } from "../src/auth";
import { routeMcp } from "../src/mcp";

const principal: Principal = { tenantId: "tenant", kind: "mcp", tokenHash: "hash",
  scopes: ["food:read", "food:write", "daily:read", "daily:write"] };

describe("MCP tool overwrite annotations", () => {
  it.each(["2025-11-25", "2026-07-28"])("declares replacements in the %s catalog", async version => {
    const response = await routeMcp(new Request("https://api.00food.com/mcp", {
      method: "POST", headers: { "MCP-Protocol-Version": version },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list" }),
    }), {} as Env, principal);
    const { result } = await response.json() as { result: { tools: Array<{
      name: string; description: string;
      annotations: { readOnlyHint: boolean; destructiveHint: boolean };
    }> } };
    const replacing = result.tools.filter(tool => tool.annotations.destructiveHint);
    expect(replacing.map(tool => tool.name).sort()).toEqual([
      "propose_food_estimate", "set_food_fruit_veg_portions", "submit_daily_feedback",
    ]);
    expect(replacing.every(tool => !tool.annotations.readOnlyHint)).toBe(true);
    expect(result.tools.filter(tool => tool.annotations.readOnlyHint)).toHaveLength(7);
    expect(result.tools.filter(tool => tool.annotations.readOnlyHint)
      .every(tool => !tool.annotations.destructiveHint)).toBe(true);
    const portions = replacing.find(tool => tool.name === "set_food_fruit_veg_portions")!;
    expect(portions.description).toContain("all existing logs");
    expect(portions.description).toContain("Previous portion values are overwritten");
  });
});
