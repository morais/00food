import type { Env } from "./api";

/// Deletes OAuth flows, authorization codes, and credentials that can never be
/// used again. Expired rows are already refused on read; this only reclaims
/// storage. Each statement seeks an `expires_at` index, so a sweep that finds
/// nothing writes nothing.
export async function sweepExpiredAuthData(env: Env, now = new Date()): Promise<void> {
  const cutoff = now.toISOString();
  await env.DB.batch([
    env.DB.prepare("DELETE FROM oauth_flows WHERE expires_at <= ?").bind(cutoff),
    env.DB.prepare("DELETE FROM oauth_codes WHERE expires_at <= ?").bind(cutoff),
    env.DB.prepare("DELETE FROM credentials WHERE expires_at <= ?").bind(cutoff),
    env.DB.prepare("DELETE FROM credentials WHERE revoked_at IS NOT NULL").bind(),
    env.DB.prepare("DELETE FROM review_credentials WHERE expires_at <= ? OR revoked_at IS NOT NULL").bind(cutoff),
  ]);
}

// No cron trigger by default: the Workers Free plan allows only five per
// account. Instead, the sign-in routes that create these rows occasionally
// sweep under waitUntil, so cleanup keeps pace with growth. The scheduled
// handler stays wired, so uncommenting the cron in wrangler.toml is all a paid
// account needs.
const sweepChance = 0.05;

export function maybeSweep(env: Env, ctx: ExecutionContext): void {
  if (Math.random() >= sweepChance) return;
  ctx.waitUntil(sweepExpiredAuthData(env).catch((cause) => {
    console.warn("Expired auth data sweep failed", cause instanceof Error ? cause.message : "unknown error");
  }));
}
