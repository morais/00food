import { describe, expect, it } from "vitest";
import { routeApi, type Env } from "../src/api";
import type { Principal } from "../src/auth";
import { migratedD1 } from "./d1";

const estimationId = "6f1c2a4e-8d3b-4c5a-9e7f-0a1b2c3d4e5f";
const principal: Principal = { tenantId: "tenant", kind: "app", scopes: ["food:read", "food:write"], tokenHash: "hash" };

function setup() {
  const { db, d1 } = migratedD1();
  db.prepare("INSERT INTO tenants (id, apple_subject, email, created_at, updated_at) VALUES ('tenant', 'apple-subject', NULL, '2026-10-01', '2026-10-01')").run();
  db.prepare(`INSERT INTO pending_estimations (id, tenant_id, description, state, local_date, created_at, updated_at)
    VALUES (?, 'tenant', 'Soup', 'pending', '2026-10-08', '2026-10-08', '2026-10-08')`).run(estimationId);
  const puts: string[] = [];
  const photos = { async put(key: string) { puts.push(key); } } as unknown as R2Bucket;
  return { db, puts, env: { DB: d1, PHOTOS: photos, PUBLIC_ORIGIN: "https://api.00food.com" } as Env };
}

const upload = (headers: Record<string, string>, body: BodyInit = new Uint8Array([0xff, 0xd8, 0xff, 0xd9])) =>
  new Request(`https://api.00food.com/v1/estimations/${estimationId}/photo`, {
    method: "PUT", headers: { "content-type": "image/jpeg", ...headers }, body, duplex: "half",
  } as RequestInit);

describe("photo upload size", () => {
  it("refuses an oversized declared body before reading it", async () => {
    const { db, puts, env } = setup();
    try {
      let pulled = false;
      const body = new ReadableStream({ pull() { pulled = true; } }, { highWaterMark: 0 });
      const response = await routeApi(upload({ "content-length": "50000000" }, body), env, principal);
      expect(response.status).toBe(413);
      expect(pulled).toBe(false);
      expect(puts).toEqual([]);
    } finally { db.close(); }
  });

  it("accepts a small JPEG with a declared length", async () => {
    const { db, puts, env } = setup();
    try {
      const response = await routeApi(upload({ "content-length": "4" }), env, principal);
      expect(response.status).toBe(200);
      expect(puts).toEqual([`tenant/${estimationId}.jpg`]);
    } finally { db.close(); }
  });
});
