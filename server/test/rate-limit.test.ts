import { describe, expect, it } from "vitest";
import { signInAllowed, sourceAllowed } from "../src/rateLimit";
import type { Env } from "../src/api";

const req = new Request("https://api.00food.com/oauth/token", { headers: { "cf-connecting-ip": "203.0.113.5" } });
const broken = { async limit() { throw new Error("limiter down"); } } as unknown as RateLimit;

describe("rate limiting", () => {
  it("refuses sign-in when the limiter is missing in a deployed Worker", async () => {
    expect(await signInAllowed({ PUBLIC_ORIGIN: "https://api.00food.com" } as Env, req)).toBe(false);
  });

  it("allows sign-in without a limiter when running locally", async () => {
    expect(await signInAllowed({ PUBLIC_ORIGIN: "http://localhost:8787" } as Env, req)).toBe(true);
  });

  it("refuses sign-in when the limiter throws, but keeps general traffic flowing", async () => {
    const env = { PUBLIC_ORIGIN: "https://api.00food.com", SIGN_IN_LIMITER: broken, SOURCE_LIMITER: broken } as Env;
    expect(await signInAllowed(env, req)).toBe(false);
    expect(await sourceAllowed(env, req)).toBe(true);
  });
});
