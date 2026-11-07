import { describe, expect, it } from "vitest";
import type { Env } from "../src/api";
import { issueCredential, type Principal } from "../src/auth";
import { routeMcp } from "../src/mcp";
import { reviewFixtureIds, reviewSeed } from "../src/reviewSeed";
import { migratedD1 } from "./d1";

const principal: Principal = { tenantId: "alice", kind: "mcp", tokenHash: "hash", scopes: ["food:read"] };
const names = ["list_pending_foods", "list_known_foods"] as const;
type FoodList = { foods: Array<{ id: string }>; setup: {
  status: string; iosSignInRecorded: boolean; profileConfigured: boolean; guidance: string; appStoreUrl?: string;
} };
function request(name: string, version: string) {
  return new Request("https://api.00food.com/mcp", { method: "POST",
    headers: { "MCP-Protocol-Version": version },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: {} } }),
  });
}
function fixture() {
  const { db, d1 } = migratedD1();
  const ids = reviewFixtureIds();
  db.exec(reviewSeed("alice", "a".repeat(64), "2999-01-01", ids));
  db.exec(reviewSeed("bob", "b".repeat(64), "2999-01-01", reviewFixtureIds()));
  const env = { DB: d1, PUBLIC_ORIGIN: "https://api.00food.com" } as Env;
  const list = async (name: string, version: string) => {
    const before = db.prepare("SELECT total_changes() AS n").get()?.n;
    const response = await routeMcp(request(name, version), env, principal);
    const { result } = await response.json() as { result: { content: Array<{ text: string }>; isError?: boolean } };
    expect(response.status).toBe(200);
    expect(result.isError).toBeUndefined();
    expect(db.prepare("SELECT total_changes() AS n").get()?.n).toBe(before);
    return JSON.parse(result.content[0].text) as FoodList;
  };
  return { db, env, ids, list };
}

describe.each(["2025-11-25", "2026-07-28"])("MCP iPhone setup guidance (%s)", version => {
  it.each(names)("rechecks setup through %s without blocking foods or exposing another account", async name => {
    const { db, env, ids, list } = fixture();
    try {
      db.exec("DELETE FROM profiles WHERE tenant_id = 'alice'");
      // Bob's completed setup must not make Alice ready.
      db.exec("UPDATE tenants SET first_ios_sign_in_at = '2026-11-01' WHERE id = 'bob'");
      const unknown = await list(name, version);
      expect(unknown.foods.map(food => food.id).sort()).toEqual(
        (name === "list_pending_foods" ? [ids.estimate] : [ids.oats, ids.soup]).sort());
      expect(unknown.setup).toMatchObject({ status: "ios_setup_unknown",
        iosSignInRecorded: false, profileConfigured: false,
        appStoreUrl: "https://apps.apple.com/app/id6818843517" });
      expect(unknown.setup.guidance).toContain("does not prove the app has never been used");

      await issueCredential(env, "alice", "app", "iOS app");
      const unfinished = await list(name, version);
      expect(unfinished.foods).toEqual(unknown.foods);
      expect(unfinished.setup).toMatchObject({ status: "finish_ios_setup",
        iosSignInRecorded: true, profileConfigured: false });
      expect(unfinished.setup.guidance).toContain("same Apple account");
      expect(unfinished.setup.guidance).toContain("Health access is optional");
      expect(unfinished.setup.guidance).toContain("call the same food-list tool again");

      db.exec(`INSERT INTO profiles (tenant_id, height_cm, weight_kg, estimate_profile, deficit_kcal, updated_at)
        VALUES ('alice', 175, 75, 'neutral', 450, '2026-11-07')`);
      const ready = await list(name, version);
      expect(ready.foods).toEqual(unknown.foods);
      expect(ready.setup).toMatchObject({ status: "ready", iosSignInRecorded: true, profileConfigured: true });
      expect(Object.keys(ready.setup).sort()).toEqual(["guidance", "iosSignInRecorded", "profileConfigured", "status"]);

      // An empty diary still has a configured profile; no install prompt.
      db.exec("DELETE FROM pending_estimations WHERE tenant_id = 'alice'; DELETE FROM foods WHERE tenant_id = 'alice'");
      const empty = await list(name, version);
      expect(empty.foods).toEqual([]);
      expect(empty.setup).toEqual(ready.setup);
    } finally { db.close(); }
  });

  it("keeps prepared reviewer accounts ready without a native sign-in", async () => {
    const { db, list } = fixture();
    try {
      for (const name of names) {
        const { setup } = await list(name, version);
        expect(setup).toMatchObject({ status: "ready", iosSignInRecorded: false, profileConfigured: true });
        expect(setup.appStoreUrl).toBeUndefined();
      }
    } finally { db.close(); }
  });

  it.each(names)("requires food:read before querying setup through %s", async name => {
    // No DB binding: an unauthorized request must not reach account data.
    const response = await routeMcp(request(name, version), { PUBLIC_ORIGIN: "https://api.00food.com" } as Env,
      { ...principal, scopes: ["daily:read"] });
    if (version === "2025-11-25") expect(response.status).toBe(403);
    else expect(await response.json()).toMatchObject({ result: { isError: true } });
  });
});
