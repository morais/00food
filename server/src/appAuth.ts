import { z } from "zod";
import { appleEmail, revokeAppleToken, verifyNativeAppleLogin } from "./apple";
import { constantTimeEqual, findOrCreateTenant, issueCredential, revokeCredential, tenantForPrincipal, type Principal } from "./auth";
import { json, type Env } from "./api";
import { closeAllFoodEventStreams } from "./foodEvents";

const LoginInput = z.strictObject({
  identityToken: z.string().min(100).max(12000),
  authorizationCode: z.string().min(1).max(2048),
  nonce: z.string().min(16).max(256),
});

export async function signInWithApple(req: Request, env: Env): Promise<Response> {
  if (!env.APPLE_APP_CLIENT_ID || !env.APPLE_PRIVATE_KEY) return json({ error: "Apple sign-in is not configured" }, 503);
  if (Number(req.headers.get("content-length") ?? 0) > 16000) return json({ error: "Request too large" }, 413);
  const raw = await req.text();
  if (raw.length > 16000) return json({ error: "Request too large" }, 413);
  let input: z.infer<typeof LoginInput>;
  try { input = LoginInput.parse(JSON.parse(raw)); }
  catch { return json({ error: "Invalid Apple sign-in request" }, 400); }
  try {
    const { claims } = await verifyNativeAppleLogin(env, input.identityToken, input.authorizationCode, input.nonce);
    const tenant = await findOrCreateTenant(env, claims.sub, appleEmail(claims));
    const credential = await issueCredential(env, tenant.id, "app", "iOS app");
    return json({ token: credential.token, expiresAt: credential.expiresAt,
      tenant: { id: tenant.id, email: tenant.email } }, 201);
  } catch (cause) {
    console.warn("Apple app sign-in failed", cause instanceof Error ? cause.message : "unknown error");
    return json({ error: "Apple sign-in could not be verified" }, 401);
  }
}

export async function signOut(env: Env, principal: Principal): Promise<Response> {
  await revokeCredential(env, principal);
  return json({ ok: true });
}

export async function deleteAccount(req: Request, env: Env, principal: Principal): Promise<Response> {
  let input: z.infer<typeof LoginInput>;
  try {
    if (Number(req.headers.get("content-length") ?? 0) > 16000) return json({ error: "Request too large" }, 413);
    const raw = await req.text();
    if (raw.length > 16000) return json({ error: "Request too large" }, 413);
    input = LoginInput.parse(JSON.parse(raw));
  } catch { return json({ error: "A fresh Apple sign-in is required" }, 400); }
  const tenant = await tenantForPrincipal(env, principal);
  if (!tenant?.apple_subject) return json({ error: "Account not found" }, 404);
  let accessToken: string;
  try {
    const verified = await verifyNativeAppleLogin(env, input.identityToken, input.authorizationCode, input.nonce);
    if (!constantTimeEqual(verified.claims.sub, tenant.apple_subject)) return json({ error: "This is a different Apple account" }, 403);
    accessToken = verified.accessToken;
    await revokeAppleToken(env, env.APPLE_APP_CLIENT_ID!, accessToken);
  } catch (cause) {
    console.warn("Apple account deletion re-authentication failed", cause instanceof Error ? cause.message : "unknown error");
    return json({ error: "Could not verify and revoke Apple sign-in. Please try again." }, 502);
  }
  await deleteTenantData(env, tenant.id, tenant.apple_subject);
  await closeAllFoodEventStreams(env, tenant.id);
  return json({ ok: true });
}

/// Removes every row and photo belonging to the account. Each table is named
/// explicitly rather than relying on foreign-key cascades, so a schema change
/// cannot silently leave personal data behind.
export async function deleteTenantData(env: Env, tenantId: string, appleSubject: string): Promise<void> {
  if (env.PHOTOS) {
    let cursor: string | undefined;
    do {
      const page = await env.PHOTOS.list({ prefix: `${tenantId}/`, cursor });
      if (page.objects.length) await env.PHOTOS.delete(page.objects.map((object) => object.key));
      cursor = page.truncated ? page.cursor : undefined;
    } while (cursor);
  }
  await env.DB.batch([
    env.DB.prepare("DELETE FROM daily_feedback_deliveries WHERE tenant_id = ?").bind(tenantId),
    env.DB.prepare("DELETE FROM mcp_event_deliveries WHERE tenant_id = ?").bind(tenantId),
    env.DB.prepare("DELETE FROM mcp_event_subscriptions WHERE tenant_id = ?").bind(tenantId),
    env.DB.prepare("DELETE FROM daily_feedback_requests WHERE tenant_id = ?").bind(tenantId),
    env.DB.prepare("DELETE FROM food_logs WHERE tenant_id = ?").bind(tenantId),
    env.DB.prepare("DELETE FROM food_events WHERE tenant_id = ?").bind(tenantId),
    env.DB.prepare("DELETE FROM mcp_resource_subscriptions WHERE tenant_id = ?").bind(tenantId),
    env.DB.prepare("DELETE FROM pending_estimations WHERE tenant_id = ?").bind(tenantId),
    env.DB.prepare("DELETE FROM profiles WHERE tenant_id = ?").bind(tenantId),
    env.DB.prepare("DELETE FROM foods WHERE tenant_id = ?").bind(tenantId),
    env.DB.prepare("DELETE FROM oauth_flows WHERE tenant_id = ?").bind(tenantId),
    env.DB.prepare("DELETE FROM oauth_codes WHERE tenant_id = ?").bind(tenantId),
    env.DB.prepare("DELETE FROM review_credentials WHERE tenant_id = ?").bind(tenantId),
    env.DB.prepare("DELETE FROM credentials WHERE tenant_id = ?").bind(tenantId),
    env.DB.prepare("DELETE FROM tenants WHERE id = ? AND apple_subject = ?").bind(tenantId, appleSubject),
  ]);
}
