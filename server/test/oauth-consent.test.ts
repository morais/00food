import { describe, expect, it } from "vitest";
import { randomToken, sha256Hex } from "../src/auth";
import { showConsent } from "../src/oauth";
import type { Env } from "../src/api";
import { migratedD1 } from "./d1";

async function consentPage(redirectUri: string, clientName: string): Promise<string> {
  const { db, d1 } = migratedD1();
  try {
    const flowId = randomToken(24);
    const secret = randomToken(24);
    db.prepare("INSERT INTO tenants VALUES ('tenant', 'apple-subject', NULL, '2026-10-01', '2026-10-01')").run();
    db.prepare(`INSERT INTO oauth_flows (id_hash, client_id, client_name, redirect_uri, code_challenge,
      client_state, resource, scopes, apple_nonce, tenant_id, consent_hash, created_at, expires_at)
      VALUES (?, 'client', ?, ?, 'challenge', NULL, 'https://api.00food.com/mcp', 'food:read food:write',
      'nonce', 'tenant', ?, '2026-10-01', '2999-01-01')`)
      .run(await sha256Hex(flowId), clientName, redirectUri, await sha256Hex(secret));
    const env = { DB: d1, PUBLIC_ORIGIN: "https://api.00food.com",
      MCP_VERIFIED_CLIENTS: '{"https://chatgpt.com/connector_platform_oauth_redirect":"ChatGPT"}' } as Env;
    const response = await showConsent(new Request(`https://api.00food.com/oauth/consent?flow=${flowId}`, {
      headers: { cookie: `fd_consent=${flowId}.${secret}` },
    }), env);
    expect(response.status).toBe(200);
    return await response.text();
  } finally { db.close(); }
}

describe("OAuth consent page", () => {
  it("never puts a self-asserted client name in the heading", async () => {
    const page = await consentPage("https://evil.example/callback", "ChatGPT");
    expect(page).toContain("<h1>Connect an unverified app to 00Food?</h1>");
    expect(page).not.toMatch(/<h1>[^<]*ChatGPT/);
    expect(page).toContain("It calls itself “ChatGPT”");
    expect(page).toContain("<code>evil.example</code>");
  });

  it("names a verified callback by its server-owned name", async () => {
    const page = await consentPage("https://chatgpt.com/connector_platform_oauth_redirect", "Anything");
    expect(page).toContain("<h1>Connect ChatGPT to 00Food?</h1>");
    expect(page).toContain("Recognized callback");
  });

  it("escapes the claimed name", async () => {
    const page = await consentPage("https://evil.example/callback", "<script>x</script>");
    expect(page).not.toContain("<script>x</script>");
    expect(page).toContain("&lt;script&gt;");
  });
});

describe("OAuth consent buttons", () => {
  it("styles Deny as the secondary choice so the two actions are distinct", async () => {
    const page = await consentPage("https://evil.example/callback", "Test");
    expect(page).toContain('<button class="secondary" name="decision" value="deny">Deny</button>');
    expect(page).toContain('<button name="decision" value="approve">Approve</button>');
  });
});
