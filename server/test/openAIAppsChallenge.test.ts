import { describe, expect, it, vi } from "vitest";
import handler from "../src/index";
import type { Env } from "../src/api";

// This public route never uses the Durable Object, whose native base class
// exists only in the Worker runtime. Keep the real fetch router under test.
vi.mock("../src/FoodEventStream", () => ({ FoodEventStream: class {} }));

const origin = "https://api.00food.com";
const path = "/.well-known/openai-apps-challenge";
const token = "test-openai-verification-token";
const context = {} as ExecutionContext;

const request = (suffix = path, configured: string | null = token, method = "GET") =>
  handler.fetch(new Request(origin + suffix, { method }), {
    OPENAI_APPS_CHALLENGE_TOKEN: configured ?? undefined,
  } as Env, context);

describe("OpenAI apps challenge", () => {
  it("returns only the configured token as uncached plain text", async () => {
    const response = await request();
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("text/plain; charset=utf-8");
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(response.headers.get("x-content-type-options")).toBe("nosniff");
    expect(await response.text()).toBe(token);
  });

  it("is disabled when no token is configured", async () => {
    expect((await request(path, null)).status).toBe(404);
    expect((await request(path, "   ")).status).toBe(404);
  });

  it("matches only the exact path and supports HEAD", async () => {
    expect((await request(path + "/")).status).toBe(404);
    expect((await request(path + ".txt")).status).toBe(404);
    const head = await request(path, token, "HEAD");
    expect(head.status).toBe(200);
    expect(await head.text()).toBe("");
  });
});
