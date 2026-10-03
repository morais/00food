import { base64url, constantTimeEqual, decodeBase64url, sha256Hex } from "./auth";
import type { Env } from "./api";

const issuer = "https://appleid.apple.com";
const keysURL = `${issuer}/auth/keys`;
const tokenURL = `${issuer}/auth/token`;

type AppleKey = { kty: string; kid: string; alg?: string; use?: string; n: string; e: string };
export type AppleClaims = {
  iss: string; aud: string; sub: string; iat: number; exp: number; nonce?: string;
  email?: string; email_verified?: boolean | string;
};

let keyCache: { keys: AppleKey[]; expires: number; fetched: number } | null = null;
const keyLifetimeMs = 3600000;
// An unknown key id triggers at most one early refetch per minute, so Apple's
// key rotation is picked up promptly without letting forged tokens with random
// key ids turn every request into a fetch.
const refetchIntervalMs = 60000;

function decodeJson<T>(encoded: string): T {
  return JSON.parse(new TextDecoder().decode(decodeBase64url(encoded))) as T;
}

async function appleKeys(forceRefresh = false): Promise<AppleKey[]> {
  const now = Date.now();
  if (keyCache && keyCache.expires > now && !forceRefresh) return keyCache.keys;
  const response = await fetch(keysURL);
  if (!response.ok) throw new Error("Apple signing keys unavailable");
  const data = await response.json() as { keys?: AppleKey[] };
  if (!Array.isArray(data.keys) || !data.keys.length) throw new Error("Apple returned no signing keys");
  keyCache = { keys: data.keys, expires: now + keyLifetimeMs, fetched: now };
  return data.keys;
}

async function appleKey(kid: string): Promise<AppleKey | undefined> {
  const find = (keys: AppleKey[]) => keys.find((key) => key.kid === kid && key.kty === "RSA");
  const cached = find(await appleKeys());
  if (cached || (keyCache && Date.now() - keyCache.fetched < refetchIntervalMs)) return cached;
  return find(await appleKeys(true));
}

export function resetAppleKeysForTest(): void { keyCache = null; }

export async function verifyAppleIdToken(
  identityToken: string,
  expectedAudience: string,
  expectedNonce: string,
): Promise<AppleClaims> {
  if (identityToken.length > 12000) throw new Error("Identity token too large");
  const parts = identityToken.split(".");
  if (parts.length !== 3) throw new Error("Malformed identity token");
  const [headerPart, payloadPart, signaturePart] = parts;
  const header = decodeJson<{ alg?: string; kid?: string }>(headerPart);
  if (header.alg !== "RS256" || !header.kid) throw new Error("Unsupported Apple signature");
  const jwk = await appleKey(header.kid);
  if (!jwk) throw new Error("Unknown Apple signing key");
  const key = await crypto.subtle.importKey("jwk", { kty: "RSA", n: jwk.n, e: jwk.e, ext: true },
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]);
  const signed = new TextEncoder().encode(`${headerPart}.${payloadPart}`);
  const signature = new Uint8Array(decodeBase64url(signaturePart));
  const valid = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, signature, signed);
  if (!valid) throw new Error("Invalid Apple signature");
  const claims = decodeJson<AppleClaims>(payloadPart);
  const now = Math.floor(Date.now() / 1000);
  if (claims.iss !== issuer || claims.aud !== expectedAudience || typeof claims.sub !== "string" || !claims.sub) {
    throw new Error("Apple identity claims do not match this app");
  }
  if (!Number.isFinite(claims.exp) || !Number.isFinite(claims.iat) || claims.exp <= now || claims.iat > now + 300 || claims.iat < now - 600) {
    throw new Error("Apple identity token is expired or stale");
  }
  if (!claims.nonce || !constantTimeEqual(claims.nonce, expectedNonce)) throw new Error("Apple nonce mismatch");
  if (claims.email && claims.email_verified !== true && claims.email_verified !== "true") {
    throw new Error("Apple email is not verified");
  }
  return claims;
}

function pemBytes(pem: string): Uint8Array {
  const content = pem.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g, "");
  if (!content) throw new Error("Apple Sign In key is missing");
  return Uint8Array.from(atob(content), (character) => character.charCodeAt(0));
}

async function appleClientSecret(env: Env, clientId: string): Promise<string> {
  if (!env.APPLE_TEAM_ID || !env.APPLE_KEY_ID || !env.APPLE_PRIVATE_KEY) throw new Error("Apple Sign In key is not configured");
  const now = Math.floor(Date.now() / 1000);
  const encode = (value: unknown) => base64url(new TextEncoder().encode(JSON.stringify(value)));
  const input = `${encode({ alg: "ES256", kid: env.APPLE_KEY_ID, typ: "JWT" })}.${encode({
    iss: env.APPLE_TEAM_ID, iat: now, exp: now + 300, aud: issuer, sub: clientId,
  })}`;
  const keyBytes = new Uint8Array(pemBytes(env.APPLE_PRIVATE_KEY));
  const key = await crypto.subtle.importKey("pkcs8", keyBytes,
    { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const signature = new Uint8Array(await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(input),
  ));
  return `${input}.${base64url(signature)}`;
}

export async function exchangeAppleCode(
  env: Env,
  code: string,
  clientId: string,
  redirectUri?: string,
): Promise<{ idToken: string; accessToken: string }> {
  if (!code || code.length > 2048) throw new Error("Invalid Apple authorization code");
  const form = new URLSearchParams({
    client_id: clientId,
    client_secret: await appleClientSecret(env, clientId),
    code,
    grant_type: "authorization_code",
  });
  if (redirectUri) form.set("redirect_uri", redirectUri);
  const response = await fetch(tokenURL, {
    method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: form,
  });
  if (!response.ok) throw new Error("Apple authorization code exchange failed");
  const result = await response.json() as { id_token?: unknown; access_token?: unknown };
  if (typeof result.id_token !== "string" || typeof result.access_token !== "string") {
    throw new Error("Apple returned incomplete tokens");
  }
  return { idToken: result.id_token, accessToken: result.access_token };
}

export async function revokeAppleToken(env: Env, clientId: string, accessToken: string): Promise<void> {
  const response = await fetch(`${issuer}/auth/revoke`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: clientId, client_secret: await appleClientSecret(env, clientId),
      token: accessToken, token_type_hint: "access_token",
    }),
  });
  if (!response.ok) throw new Error("Apple token revocation failed");
}

export async function verifyNativeAppleLogin(
  env: Env,
  identityToken: string,
  authorizationCode: string,
  rawNonce: string,
): Promise<{ claims: AppleClaims; accessToken: string }> {
  if (!env.APPLE_APP_CLIENT_ID) throw new Error("Apple app identifier is not configured");
  if (!/^[A-Za-z0-9._-]{16,256}$/.test(rawNonce)) throw new Error("Invalid Apple nonce");
  const expectedNonce = await sha256Hex(rawNonce);
  const claims = await verifyAppleIdToken(identityToken, env.APPLE_APP_CLIENT_ID, expectedNonce);
  const exchanged = await exchangeAppleCode(env, authorizationCode, env.APPLE_APP_CLIENT_ID);
  const exchangedClaims = await verifyAppleIdToken(exchanged.idToken, env.APPLE_APP_CLIENT_ID, expectedNonce);
  if (!constantTimeEqual(exchangedClaims.sub, claims.sub)) throw new Error("Apple identity changed during exchange");
  return { claims: exchangedClaims, accessToken: exchanged.accessToken };
}

export function appleEmail(claims: AppleClaims): string | null {
  const email = claims.email?.trim().toLowerCase();
  return email && email.length <= 320 && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) ? email : null;
}
