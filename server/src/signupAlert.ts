import { appName, type Env } from "./api";

/// Operator notification when Sign in with Apple creates a brand new tenant.
///
/// Off unless *both* the `SIGNUP_ALERTS` send_email binding and
/// `SIGNUP_ALERT_TO` are configured, so a default deployment — which has
/// neither — sends nothing and needs no Email Routing setup at all. Anyone with
/// a verified Apple ID can create a tenant from the app, an MCP client, or the web dashboard, and
/// an operator should find out when it happens rather than
/// discovering it in a bill.
export function signupAlertsConfigured(env: Env): boolean {
  return Boolean(env.SIGNUP_ALERTS && env.SIGNUP_ALERT_TO?.trim());
}

export type SignupSource = "app" | "mcp" | "dashboard";

export interface NewTenantAlert {
  source: SignupSource;
  tenantId: string;
  /// Absent when Apple did not share an email for this sign-in.
  ownerEmail?: string | null;
  createdAt: string;
}

const SIGNUP_SURFACES: Record<SignupSource, string> = {
  app: "native app",
  mcp: "MCP client connection",
  dashboard: "web dashboard",
};

/// Never throws and never rejects. A signup must not fail, or even slow down,
/// because an alert could not be delivered — callers pass this to
/// `ctx.waitUntil`, which runs it after the response is already on its way.
export async function sendNewTenantAlert(env: Env, alert: NewTenantAlert): Promise<void> {
  if (!signupAlertsConfigured(env)) return;

  const to = env.SIGNUP_ALERT_TO!.trim();
  // Must be an address on a domain this account has Email Routing configured
  // for; Cloudflare rejects anything else at send time.
  const from = env.SIGNUP_ALERT_FROM?.trim() || to;
  const name = appName(env);

  try {
    // Imported dynamically rather than at module scope: `cloudflare:email` only
    // resolves inside the Workers runtime, and the test suite runs in plain
    // Node, where a top-level import would fail the entire file on load.
    const { EmailMessage } = await import("cloudflare:email");

    // appleEmail() validates the address at the boundary, but this function
    // hand-assembles a CRLF-delimited message, and a header built from a value
    // carrying a newline is an injected Bcc. headerSafe makes the sink safe
    // regardless of what reaches it.
    const surface = SIGNUP_SURFACES[alert.source];
    const subject = headerSafe(`${name}: new tenant ${alert.ownerEmail ?? `via ${surface}`}`);
    const body = [
      "A new tenant was created through Sign in with Apple.",
      "",
      `Signup surface: ${surface}`,
      `Owner email: ${alert.ownerEmail ?? "(none)"}`,
      `Tenant id:   ${alert.tenantId}`,
      `Created at:  ${alert.createdAt}`,
    ].join("\n");

    const raw = [
      `From: ${headerSafe(name)} <${headerSafe(from)}>`,
      `To: ${headerSafe(to)}`,
      `Subject: ${subject}`,
      `Date: ${new Date().toUTCString()}`,
      `Message-ID: <${crypto.randomUUID()}@${messageIdDomain(from)}>`,
      "MIME-Version: 1.0",
      "Content-Type: text/plain; charset=UTF-8",
      "Content-Transfer-Encoding: 8bit",
      "",
      body,
    ].join("\r\n");

    await env.SIGNUP_ALERTS!.send(new EmailMessage(from, to, raw));
  } catch (error) {
    // Logged, not surfaced: the tenant exists either way, and the caller has
    // already returned credentials to the client.
    console.warn("signup alert email failed", {
      tenantId: alert.tenantId,
      error: error instanceof Error ? error.message : String(error),
    });
  }
}

/// Strips anything that would end a header line. C0 controls and DEL have no
/// legitimate place in an address or a subject, so removing them cannot damage
/// a real value.
function headerSafe(value: string): string {
  return value.replace(/[\u0000-\u001f\u007f]/g, "");
}

function messageIdDomain(from: string): string {
  return headerSafe(from.split("@").pop() || "localhost").replace(/[<>\s]/g, "");
}
