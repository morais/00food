import { afterEach, describe, expect, it, vi } from "vitest";
import { revokeWithRetry } from "../src/appAuth";
import type { Env } from "../src/api";

afterEach(() => vi.unstubAllGlobals());

async function appleEnv(): Promise<Env> {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair;
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey) as ArrayBuffer);
  const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...pkcs8))}\n-----END PRIVATE KEY-----`;
  return { APPLE_APP_CLIENT_ID: "com.example.app", APPLE_TEAM_ID: "TEAM", APPLE_KEY_ID: "KEY",
    APPLE_PRIVATE_KEY: pem } as Env;
}

describe("Apple token revocation after account deletion", () => {
  it("retries until Apple accepts the revocation", async () => {
    const statuses = [503, 500, 200];
    const fetch = vi.fn(async () => new Response(null, { status: statuses.shift() }));
    vi.stubGlobal("fetch", fetch);
    expect(await revokeWithRetry(await appleEnv(), "token", [0, 0, 0])).toBe(true);
    expect(fetch).toHaveBeenCalledTimes(3);
  });

  it("gives up without throwing when Apple stays unavailable", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response(null, { status: 503 })));
    expect(await revokeWithRetry(await appleEnv(), "token", [0, 0])).toBe(false);
  });
});
