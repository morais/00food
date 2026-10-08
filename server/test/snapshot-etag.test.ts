import { describe, expect, it } from "vitest";
import { routeApi, type Env } from "../src/api";
import { migratedD1 } from "./d1";
import type { Principal } from "../src/auth";

const principal: Principal = { tenantId: "tenant", kind: "app", scopes: [], tokenHash: "hash" };

describe("snapshot revalidation", () => {
  it("answers 304 until something in the snapshot changes", async () => {
    const { db, d1 } = migratedD1();
    try {
      const now = "2026-10-08T00:00:00Z";
      db.prepare("INSERT INTO tenants (id, apple_subject, email, created_at, updated_at) VALUES ('tenant', 'a', NULL, ?, ?)").run(now, now);
      const env = { DB: d1, PUBLIC_ORIGIN: "https://api.00food.com" } as Env;
      const call = (method: string, path: string, init: { body?: unknown; etag?: string | null } = {}) =>
        routeApi(new Request(`https://api.00food.com${path}`, { method,
          headers: init.etag ? { "if-none-match": init.etag } : {},
          body: init.body ? JSON.stringify(init.body) : undefined }), env, principal);

      const first = await call("GET", "/v1/snapshot");
      const etag = first.headers.get("etag");
      expect(first.status).toBe(200);
      expect(etag).toMatch(/^"\d+-\d{4}-\d{2}-\d{2}"$/);
      const unchanged = await call("GET", "/v1/snapshot", { etag });
      expect(unchanged.status).toBe(304);
      expect(await unchanged.text()).toBe("");

      const changes: Array<[string, string, unknown?]> = [
        ["POST", "/v1/foods", { name: "Toast", serving: "1 slice", kcal: 90 }],
        ["PUT", "/v1/profile", { heightCm: 170, weightKg: 70, estimateProfile: "neutral", deficitKcal: 300 }],
        ["POST", "/v1/estimations", { description: "Soup", localDate: "2026-10-08" }],
      ];
      let previous = etag;
      for (const [method, path, body] of changes) {
        expect((await call(method, path, { body })).status).toBeLessThan(300);
        const after = await call("GET", "/v1/snapshot", { etag: previous });
        expect(after.status, `${method} ${path}`).toBe(200);
        previous = after.headers.get("etag");
      }

      // An agent proposal is an UPDATE made outside the app, and must also invalidate.
      db.prepare("UPDATE pending_estimations SET state = 'proposed', proposed_name = 'Soup'").run();
      expect((await call("GET", "/v1/snapshot", { etag: previous })).status).toBe(200);
    } finally { db.close(); }
  });
});
