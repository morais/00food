import type { Env } from "./api";

export type CredentialKind = "app" | "mcp";
export type Scope = "food:read" | "food:write";
export interface Principal {
  tenantId: string;
  kind: CredentialKind;
  scopes: Scope[];
  tokenHash: string;
}

type CredentialRow = {
  token_hash: string;
  tenant_id: string;
  kind: CredentialKind;
  audience: string;
  scopes: string;
  expires_at: string;
  revoked_at: string | null;
  last_used_at: string | null;
};
type TenantRow = { id: string; apple_subject: string | null; email: string | null };

export function randomToken(bytes = 32): string {
  const data = crypto.getRandomValues(new Uint8Array(bytes));
  return base64url(data);
}

export function base64url(data: Uint8Array): string {
  let binary = "";
  for (const byte of data) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

export function decodeBase64url(value: string): Uint8Array {
  const base64 = value.replace(/-/g, "+").replace(/_/g, "/");
  return Uint8Array.from(atob(base64.padEnd(Math.ceil(base64.length / 4) * 4, "=")), (ch) => ch.charCodeAt(0));
}

export async function sha256Hex(value: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
  return [...digest].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function sha256Base64url(value: string): Promise<string> {
  return base64url(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value))));
}

export function constantTimeEqual(left: string, right: string): boolean {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index++) difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
  return difference === 0;
}

export function publicOrigin(env: Env): string {
  const origin = env.PUBLIC_ORIGIN?.replace(/\/$/, "");
  if (!origin || !/^https:\/\/[^/?#]+$/.test(origin) && !/^http:\/\/localhost(?::\d+)?$/.test(origin)) {
    throw new Error("PUBLIC_ORIGIN must be an HTTPS origin, or localhost for development");
  }
  return origin;
}

export function audience(env: Env, kind: CredentialKind): string {
  return publicOrigin(env) + (kind === "app" ? "/v1" : "/mcp");
}

const lastUsedResolutionMs = 3600000;

export function lastUseIsStale(lastUsedAt: string | null, now = Date.now()): boolean {
  const previous = lastUsedAt ? Date.parse(lastUsedAt) : NaN;
  return !Number.isFinite(previous) || now - previous >= lastUsedResolutionMs;
}

export async function authenticate(req: Request, env: Env, kind: CredentialKind): Promise<Principal | null> {
  const raw = req.headers.get("authorization")?.match(/^Bearer (fd_(?:app|mcp)_[A-Za-z0-9_-]{43})$/i)?.[1];
  if (!raw || !raw.startsWith(`fd_${kind}_`)) return null;
  const hash = await sha256Hex(raw);
  const row = await env.DB.prepare("SELECT * FROM credentials WHERE token_hash = ?")
    .bind(hash).first<CredentialRow>();
  if (!row || row.kind !== kind || row.audience !== audience(env, kind) || row.revoked_at || row.expires_at <= new Date().toISOString()) return null;
  const scopes = row.scopes.split(" ").filter((value): value is Scope => value === "food:read" || value === "food:write");
  // Agents make many calls in a row; recording each one would be a D1 write
  // per request. An hourly resolution is plenty for the connections screen.
  if (kind === "mcp" && lastUseIsStale(row.last_used_at)) {
    await env.DB.prepare("UPDATE credentials SET last_used_at = ? WHERE token_hash = ? AND tenant_id = ?")
      .bind(new Date().toISOString(), hash, row.tenant_id).run();
  }
  return { tenantId: row.tenant_id, kind, scopes, tokenHash: hash };
}

export async function issueCredential(
  env: Env,
  tenantId: string,
  kind: CredentialKind,
  label: string,
  scopes: Scope[] = ["food:read", "food:write"],
): Promise<{ token: string; expiresAt: string }> {
  const token = `fd_${kind}_${randomToken()}`;
  const tokenHash = await sha256Hex(token);
  const id = crypto.randomUUID();
  const now = new Date();
  const expiresAt = new Date(now.getTime() + (kind === "app" ? 90 : 30) * 86400000).toISOString();
  await env.DB.prepare(`INSERT INTO credentials
    (id, token_hash, tenant_id, kind, audience, scopes, label, created_at, expires_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`).bind(
    id, tokenHash, tenantId, kind, audience(env, kind), scopes.join(" "), label.slice(0, 120), now.toISOString(), expiresAt,
  ).run();
  return { token, expiresAt };
}

export async function revokeCredential(env: Env, principal: Principal): Promise<void> {
  await env.DB.prepare("UPDATE credentials SET revoked_at = ? WHERE token_hash = ? AND tenant_id = ?")
    .bind(new Date().toISOString(), principal.tokenHash, principal.tenantId).run();
}

export async function findOrCreateTenant(env: Env, appleSubject: string, email: string | null): Promise<TenantRow> {
  const id = crypto.randomUUID();
  const now = new Date().toISOString();
  await env.DB.prepare(`INSERT OR IGNORE INTO tenants
    (id, apple_subject, email, created_at, updated_at) VALUES (?, ?, ?, ?, ?)`).bind(
    id, appleSubject, email, now, now,
  ).run();
  const tenant = await env.DB.prepare("SELECT id, apple_subject, email FROM tenants WHERE apple_subject = ?")
    .bind(appleSubject).first<TenantRow>();
  if (!tenant) throw new Error("Could not resolve Apple account");
  if (email && email !== tenant.email) {
    await env.DB.prepare("UPDATE tenants SET email = ?, updated_at = ? WHERE id = ?")
      .bind(email, now, tenant.id).run();
    tenant.email = email;
  }
  return tenant;
}

export async function tenantForPrincipal(env: Env, principal: Principal): Promise<TenantRow | null> {
  return env.DB.prepare("SELECT id, apple_subject, email FROM tenants WHERE id = ?")
    .bind(principal.tenantId).first<TenantRow>();
}
