import { z } from "zod";
import type { Env } from "./api";
import { base64url, type Principal } from "./auth";

type PushEnvironment = "development" | "production";
type Device = { tenant_id: string; installation_id: string; credential_hash: string; device_token: string;
  environment: PushEnvironment; updated_at: string; last_push_at: number; delivered_version: string | null };
type Pending = { version: string; queued_at: number; due_at: number; attempts: number };
const registration = z.strictObject({ installationId: z.uuid(),
  deviceToken: z.string().regex(/^[a-f0-9]{32,512}$/).refine(value => value.length % 2 === 0),
  environment: z.enum(["development", "production"]) });
const response = (value: unknown, status = 200) => Response.json(value, { status, headers: { "Cache-Control": "no-store" } });

function configuration(env: Env, environment: PushEnvironment) {
  const keyId = environment === "production" ? env.APNS_KEY_ID : env.APNS_DEVELOPMENT_KEY_ID;
  const privateKey = environment === "production" ? env.APNS_PRIVATE_KEY : env.APNS_DEVELOPMENT_PRIVATE_KEY;
  const teamId = env.APPLE_TEAM_ID;
  const topic = env.APPLE_APP_CLIENT_ID;
  return keyId && privateKey && teamId && topic ? { keyId, privateKey, teamId, topic } : null;
}

export async function routePushDevice(req: Request, env: Env, principal: Principal): Promise<Response> {
  if (principal.kind !== "app") return response({ error: "App sign-in required" }, 403);
  if (req.method !== "PUT") return response({ error: "Method not allowed" }, 405);
  let input: z.infer<typeof registration>;
  try {
    if (Number(req.headers.get("content-length") ?? 0) > 2048) return response({ error: "Request too large" }, 413);
    const raw = await req.text();
    if (raw.length > 2048) return response({ error: "Request too large" }, 413);
    input = registration.parse(JSON.parse(raw));
  } catch { return response({ error: "Invalid device registration" }, 400); }
  const count = await env.DB.prepare("SELECT COUNT(*) AS n FROM push_devices WHERE tenant_id = ? AND installation_id != ?")
    .bind(principal.tenantId, input.installationId).first<{ n: number }>();
  if ((count?.n ?? 0) >= 10) return response({ error: "Device limit reached" }, 409);
  const enabled = configuration(env, input.environment) !== null;
  const now = new Date().toISOString();
  const validSession = "SELECT 1 FROM credentials WHERE token_hash = ? AND tenant_id = ? AND kind = 'app' AND revoked_at IS NULL AND expires_at > ?";
  const results = await env.DB.batch([
    // A device token belongs to one signed-in account at a time. Check the
    // session again inside the batch to avoid a registration racing sign-out.
    env.DB.prepare(`DELETE FROM push_devices WHERE device_token = ? AND environment = ?
      AND NOT (tenant_id = ? AND installation_id = ?) AND EXISTS (${validSession})`)
      .bind(input.deviceToken, input.environment, principal.tenantId, input.installationId, principal.tokenHash, principal.tenantId, now),
    env.DB.prepare(`INSERT INTO push_devices
      (tenant_id, installation_id, credential_hash, device_token, environment, enabled, updated_at)
      SELECT ?, ?, ?, ?, ?, ?, ? WHERE EXISTS (${validSession})
      ON CONFLICT(tenant_id, installation_id) DO UPDATE SET credential_hash = excluded.credential_hash,
        device_token = excluded.device_token, environment = excluded.environment, enabled = excluded.enabled,
        updated_at = excluded.updated_at`)
      .bind(principal.tenantId, input.installationId, principal.tokenHash, input.deviceToken, input.environment,
        enabled ? 1 : 0, now, principal.tokenHash, principal.tenantId, now),
  ]);
  return results[1].meta.changes ? response({ ok: true, enabled }) : response({ error: "Session ended" }, 401);
}

export async function notifyAgentResponse(env: Env, tenantId: string): Promise<void> {
  if (!env.FOOD_EVENTS) return;
  const pending = await env.DB.prepare("SELECT version FROM push_pending WHERE tenant_id = ?").bind(tenantId).first();
  if (!pending) return;
  try {
    await env.FOOD_EVENTS.getByName(tenantId).fetch("https://events.internal/publish-response", {
      method: "POST", headers: { "x-tenant-id": tenantId },
    });
  } catch { console.warn("Agent response wake-up deferred; outbox retained"); }
}

let cachedToken: { keyId: string; teamId: string; privateKey: string; token: string; issuedAt: number } | undefined;
export async function apnsProviderToken(config: NonNullable<ReturnType<typeof configuration>>, now = Date.now()): Promise<string> {
  if (cachedToken && cachedToken.keyId === config.keyId && cachedToken.teamId === config.teamId &&
      cachedToken.privateKey === config.privateKey && now - cachedToken.issuedAt < 50 * 60000 && now >= cachedToken.issuedAt) {
    return cachedToken.token;
  }
  const encode = (value: unknown) => base64url(new TextEncoder().encode(JSON.stringify(value)));
  const input = `${encode({ alg: "ES256", kid: config.keyId })}.${encode({ iss: config.teamId, iat: Math.floor(now / 1000) })}`;
  const pem = config.privateKey.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g, "");
  const key = await crypto.subtle.importKey("pkcs8", Uint8Array.from(atob(pem), c => c.charCodeAt(0)),
    { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const signature = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(input)));
  const token = `${input}.${base64url(signature)}`;
  cachedToken = { ...config, token, issuedAt: now };
  return token;
}

const minimumPushInterval = 20 * 60000;
export async function deliverAgentResponsePushes(env: Env, tenantId: string, now = Date.now()): Promise<number | null> {
  const pending = await env.DB.prepare("SELECT * FROM push_pending WHERE tenant_id = ?").bind(tenantId).first<Pending>();
  if (!pending) return null;
  if (pending.due_at > now) return pending.due_at;
  if (now - pending.queued_at > 86400000 || pending.attempts >= 8) {
    await env.DB.prepare("DELETE FROM push_pending WHERE tenant_id = ? AND version = ?").bind(tenantId, pending.version).run();
    return (await env.DB.prepare("SELECT due_at FROM push_pending WHERE tenant_id = ?").bind(tenantId).first<{ due_at: number }>())?.due_at ?? null;
  }
  const devices = await env.DB.prepare(`SELECT d.* FROM push_devices d JOIN credentials c ON c.token_hash = d.credential_hash
    WHERE d.tenant_id = ? AND d.enabled = 1 AND c.tenant_id = d.tenant_id AND c.kind = 'app'
      AND c.revoked_at IS NULL AND c.expires_at > ? LIMIT 10`)
    .bind(tenantId, new Date(now).toISOString()).all<Device>();
  let next: number | null = null;
  let failed = false;
  const deferUntil = (date: number) => { next = next === null ? date : Math.min(next, date); };
  for (const device of devices.results) {
    if (device.delivered_version === pending.version) continue;
    if (device.last_push_at && device.last_push_at + minimumPushInterval > now) {
      deferUntil(device.last_push_at + minimumPushInterval); continue;
    }
    const config = configuration(env, device.environment);
    if (!config) { deferUntil(now + 3600000); continue; }
    try {
      const host = device.environment === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com";
      const sent = await fetch(`https://${host}/3/device/${device.device_token}`, {
        method: "POST", headers: { authorization: `bearer ${await apnsProviderToken(config, now)}`,
          "apns-topic": config.topic, "apns-push-type": "background", "apns-priority": "5",
          "apns-collapse-id": "00food-agent-responses", "apns-expiration": String(Math.floor(now / 1000) + 86400),
          "content-type": "application/json" },
        body: JSON.stringify({ aps: { "content-available": 1 }, foodSync: true }),
        signal: AbortSignal.timeout(10000),
      });
      if (sent.ok) {
        await env.DB.prepare(`UPDATE push_devices SET last_push_at = ?, delivered_version = ?
          WHERE tenant_id = ? AND installation_id = ? AND device_token = ? AND updated_at = ?`)
          .bind(now, pending.version, tenantId, device.installation_id, device.device_token, device.updated_at).run();
      } else {
        const detail = await sent.json().catch(() => ({})) as { reason?: string };
        if (sent.status === 410 || (sent.status === 400 && ["BadDeviceToken", "DeviceTokenNotForTopic"].includes(detail.reason ?? ""))) {
          await env.DB.prepare(`DELETE FROM push_devices WHERE tenant_id = ? AND installation_id = ?
            AND device_token = ? AND updated_at = ?`)
            .bind(tenantId, device.installation_id, device.device_token, device.updated_at).run();
        } else { failed = true; console.warn("Background push deferred", sent.status); }
      }
    } catch { failed = true; console.warn("Background push transport deferred"); }
  }
  if (failed) deferUntil(now + Math.min(3600000, 30000 * 2 ** pending.attempts));
  if (next !== null) {
    await env.DB.prepare(`UPDATE push_pending SET due_at = ?, attempts = attempts + ? WHERE tenant_id = ? AND version = ?`)
      .bind(next, failed ? 1 : 0, tenantId, pending.version).run();
  } else {
    await env.DB.prepare("DELETE FROM push_pending WHERE tenant_id = ? AND version = ?").bind(tenantId, pending.version).run();
  }
  // Another response may have arrived during delivery. Never delete or postpone it.
  return (await env.DB.prepare("SELECT due_at FROM push_pending WHERE tenant_id = ?").bind(tenantId).first<{ due_at: number }>())?.due_at ?? null;
}
