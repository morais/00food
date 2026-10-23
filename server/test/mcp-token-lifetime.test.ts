import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { migratedD1, migrationsDir } from "./d1";

describe("MCP token lifetime migration", () => {
  it("extends active MCP tokens without reviving expired or revoked tokens or changing app sessions", () => {
    const migration = "0020_mcp_token_lifetime.sql";
    const { db } = migratedD1(migration);
    const now = Date.now();
    const at = (days: number) => new Date(now + days * 86400000).toISOString();
    try {
      db.prepare("INSERT INTO tenants (id, apple_subject, created_at, updated_at) VALUES ('tenant', 'apple', ?, ?)")
        .run(at(-7), at(-7));
      const insert = db.prepare(`INSERT INTO credentials
        (id, token_hash, tenant_id, kind, audience, scopes, label, created_at, expires_at, revoked_at)
        VALUES (?, ?, 'tenant', ?, 'audience', 'food:read daily:read', 'Agent', ?, ?, ?)`);
      insert.run("active", "active-hash", "mcp", at(-7), at(23), null);
      insert.run("expired", "expired-hash", "mcp", at(-45), at(-15), null);
      insert.run("revoked", "revoked-hash", "mcp", at(-7), at(23), at(-1));
      insert.run("longer", "longer-hash", "mcp", at(-7), at(400), null);
      insert.run("app", "app-hash", "app", at(-7), at(83), null);
      db.exec(readFileSync(join(migrationsDir, migration), "utf8"));
      const expires = (id: string) => db.prepare("SELECT expires_at FROM credentials WHERE id = ?").get(id)?.expires_at;
      expect(expires("active")).toBe(at(358));
      expect(expires("expired")).toBe(at(-15));
      expect(expires("revoked")).toBe(at(23));
      expect(expires("longer")).toBe(at(400));
      expect(expires("app")).toBe(at(83));
      expect(db.prepare("SELECT token_hash, scopes, revoked_at FROM credentials WHERE id = 'active'").get())
        .toEqual({ token_hash: "active-hash", scopes: "food:read daily:read", revoked_at: null });
    } finally { db.close(); }
  });
});
