import { describe, expect, it, vi } from "vitest";
import { findOrCreateTenant } from "../src/auth";
import { sendNewTenantAlert } from "../src/signupAlert";
import type { Env } from "../src/api";
import { migratedD1 } from "./d1";

// `cloudflare:email` only resolves inside the Workers runtime. Standing in for
// it lets the hand-built message be read back.
vi.mock("cloudflare:email", () => ({
  EmailMessage: class {
    constructor(readonly from: string, readonly to: string, readonly raw: string) {}
  },
}));

function environment(alerts = true) {
  const send = vi.fn(async (_message: { from: string; to: string; raw: string }) => {});
  const env = {
    DB: migratedD1().d1, PUBLIC_ORIGIN: "https://api.00food.com", APP_NAME: "00Food",
    ...(alerts ? { SIGNUP_ALERTS: { send }, SIGNUP_ALERT_TO: "ops@example.com", SIGNUP_ALERT_FROM: "alerts@00food.com" } : {}),
  } as unknown as Env;
  return { env, send };
}

describe("signup alert", () => {
  it("emails the operator once, after the response, when a sign-in creates a tenant", async () => {
    const { env, send } = environment();
    const waitUntil = vi.fn();
    const ctx = { waitUntil } as unknown as ExecutionContext;
    const tenant = await findOrCreateTenant(env, "apple-sub", "new@example.com", { source: "mcp", ctx });
    expect(waitUntil).toHaveBeenCalledTimes(1);
    await waitUntil.mock.calls[0][0];
    const message = send.mock.calls[0][0];
    expect(message.from).toBe("alerts@00food.com");
    expect(message.to).toBe("ops@example.com");
    expect(message.raw).toContain("Subject: 00Food: new tenant new@example.com\r\n");
    expect(message.raw).toContain("Signup surface: MCP client connection");
    expect(message.raw).toContain(`Tenant id:   ${tenant.id}`);

    const again = await findOrCreateTenant(env, "apple-sub", "new@example.com", { source: "app", ctx });
    expect(again.id).toBe(tenant.id);
    expect(waitUntil).toHaveBeenCalledTimes(1);
    expect(send).toHaveBeenCalledTimes(1);
  });

  it("sends nothing unless both the binding and the recipient are configured", async () => {
    const { env } = environment(false);
    await expect(findOrCreateTenant(env, "apple-sub", null, { source: "app" })).resolves.toBeTruthy();
  });

  it("names the surface when Apple shares no email, and keeps newlines out of headers", async () => {
    const { env, send } = environment();
    await sendNewTenantAlert(env, { source: "app", tenantId: "t-1", ownerEmail: null, createdAt: "2026-10-08T00:00:00.000Z" });
    expect(send.mock.calls[0][0].raw).toContain("Subject: 00Food: new tenant via native app\r\n");
    expect(send.mock.calls[0][0].raw).toContain("Owner email: (none)");

    await sendNewTenantAlert(env, {
      source: "app", tenantId: "t-2", ownerEmail: "a@example.com\r\nBcc: evil@example.com", createdAt: "2026-10-08T00:00:00.000Z",
    });
    const headers = send.mock.calls[1][0].raw.split("\r\n\r\n")[0];
    expect(headers).not.toContain("\r\nBcc:");
  });

  it("never fails the sign-in when sending fails", async () => {
    const { env, send } = environment();
    send.mockRejectedValueOnce(new Error("not verified"));
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    await expect(findOrCreateTenant(env, "apple-sub", "new@example.com", { source: "app" })).resolves.toBeTruthy();
    expect(warn).toHaveBeenCalledWith("signup alert email failed", expect.objectContaining({ error: "not verified" }));
    warn.mockRestore();
  });
});
