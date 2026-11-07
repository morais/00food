import { readFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { signInWithApple } from "../src/appAuth";
import { verifyNativeAppleLogin } from "../src/apple";
import { findOrCreateTenant, issueCredential } from "../src/auth";
import { sweepExpiredAuthData } from "../src/cleanup";
import type { Env } from "../src/api";
import { migratedD1, migrationsDir } from "./d1";

vi.mock("../src/apple", async importOriginal => ({
  ...await importOriginal<typeof import("../src/apple")>(),
  verifyNativeAppleLogin: vi.fn(),
}));

const first = "2026-11-07T10:00:00.000Z";
const verified = vi.mocked(verifyNativeAppleLogin);
beforeEach(() => {
  vi.useFakeTimers();
  vi.setSystemTime(new Date(first));
  verified.mockReset().mockResolvedValue({ accessToken: "apple-access", claims: {
    iss: "https://appleid.apple.com", aud: "com.00food.app", sub: "apple-user",
    iat: 0, exp: 9999999999,
  } });
});
afterEach(() => { vi.useRealTimers(); vi.restoreAllMocks(); });

function fixture() {
  const { db, d1 } = migratedD1();
  return { db, env: { DB: d1, PUBLIC_ORIGIN: "https://api.00food.com",
    APPLE_APP_CLIENT_ID: "com.00food.app", APPLE_PRIVATE_KEY: "mocked" } as Env };
}
const login = (env: Env) => signInWithApple(new Request("https://api.00food.com/v1/auth/apple", {
  method: "POST", body: JSON.stringify({ identityToken: "x".repeat(100),
    authorizationCode: "apple-code", nonce: "n".repeat(32) }),
}), env);

describe("first observed iOS sign-in", () => {
  it("does not backfill existing accounts, even if an app credential exists", () => {
    const { db } = migratedD1("0021_first_ios_sign_in.sql");
    try {
      db.exec(`INSERT INTO tenants (id, apple_subject, created_at, updated_at)
        VALUES ('old', 'apple-old', '2026-10-01', '2026-10-01');
        INSERT INTO credentials (token_hash, id, tenant_id, kind, audience, scopes, label, created_at, expires_at)
        VALUES ('hash', 'credential', 'old', 'app', 'aud', 'food:read', 'iOS app', '2026-10-02', '2999-01-01')`);
      db.exec(readFileSync(join(migrationsDir, "0021_first_ios_sign_in.sql"), "utf8"));
      expect(db.prepare("SELECT first_ios_sign_in_at FROM tenants").get())
        .toEqual({ first_ios_sign_in_at: null });
    } finally { db.close(); }
  });

  it.each(["new", "mcp", "dashboard"] as const)("records native login for a %s account and preserves it", async source => {
    const { db, env } = fixture();
    try {
      if (source !== "new") {
        const tenant = await findOrCreateTenant(env, "apple-user", null, { source });
        await issueCredential(env, tenant.id, "mcp", "MCP");
        expect(db.prepare("SELECT first_ios_sign_in_at FROM tenants").get())
          .toEqual({ first_ios_sign_in_at: null });
      }
      expect((await login(env)).status).toBe(201);
      const tenant = db.prepare("SELECT id, first_ios_sign_in_at FROM tenants").get()!;
      expect(tenant.first_ios_sign_in_at).toBe(first);
      expect(db.prepare("SELECT COUNT(*) AS n FROM credentials WHERE kind = 'app'").get()?.n).toBe(1);
      vi.setSystemTime(new Date("2026-11-17T10:00:00.000Z"));
      expect((await login(env)).status).toBe(201);
      expect(db.prepare("SELECT COUNT(*) AS n FROM tenants").get()?.n).toBe(1);
      expect(db.prepare("SELECT first_ios_sign_in_at FROM tenants WHERE id = ?").get(tenant.id)?.first_ios_sign_in_at).toBe(first);
      db.exec("UPDATE credentials SET revoked_at = '2026-11-17'");
      await sweepExpiredAuthData(env, new Date("2028-01-01"));
      expect(db.prepare("SELECT COUNT(*) AS n FROM credentials").get()?.n).toBe(0);
      expect(db.prepare("SELECT first_ios_sign_in_at FROM tenants").get()?.first_ios_sign_in_at).toBe(first);
    } finally { db.close(); }
  });

  it("does not mark an account when Apple verification fails", async () => {
    const { db, env } = fixture();
    try {
      await findOrCreateTenant(env, "apple-user", null, { source: "mcp" });
      verified.mockRejectedValueOnce(new Error("Invalid Apple token"));
      vi.spyOn(console, "warn").mockImplementation(() => {});
      expect((await login(env)).status).toBe(401);
      expect(db.prepare("SELECT first_ios_sign_in_at FROM tenants").get()?.first_ios_sign_in_at).toBeNull();
      expect(db.prepare("SELECT COUNT(*) AS n FROM credentials").get()?.n).toBe(0);
    } finally { db.close(); }
  });

  it("rolls back the credential if recording the first sign-in fails", async () => {
    const { db, env } = fixture();
    try {
      await findOrCreateTenant(env, "apple-user", null, { source: "mcp" });
      db.exec(`CREATE TRIGGER fail_marker BEFORE UPDATE OF first_ios_sign_in_at ON tenants
        BEGIN SELECT RAISE(ABORT, 'temporary database failure'); END`);
      vi.spyOn(console, "warn").mockImplementation(() => {});
      expect((await login(env)).status).toBe(401);
      expect(db.prepare("SELECT COUNT(*) AS n FROM credentials").get()?.n).toBe(0);
      expect(db.prepare("SELECT first_ios_sign_in_at FROM tenants").get()?.first_ios_sign_in_at).toBeNull();
      db.exec("DROP TRIGGER fail_marker");
      expect((await login(env)).status).toBe(201);
      expect(db.prepare("SELECT first_ios_sign_in_at FROM tenants").get()?.first_ios_sign_in_at).toBe(first);
    } finally { db.close(); }
  });
});
