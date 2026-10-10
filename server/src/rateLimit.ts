import { json, type Env } from "./api";

export const tooManyRequests = (): Response => {
  const response = json({ error: "Too many requests. Try again in a minute." }, 429);
  response.headers.set("Retry-After", "60");
  return response;
};

const signInPosts = new Set(["/v1/auth/apple", "/oauth/register", "/oauth/token", "/auth/apple/callback",
  "/auth/review/callback", "/oauth/consent", "/dashboard/login/review", "/dashboard/logout"]);
const signInPages = new Set(["/oauth/authorize", "/oauth/login", "/dashboard/login"]);

/// Routes that start a sign-in or mint a credential share the stricter limiter.
export const isSignInRoute = (path: string, method: string): boolean =>
  signInPages.has(path) || method === "POST" && signInPosts.has(path);

const sourceKey = (req: Request): string => req.headers.get("cf-connecting-ip")?.trim() || "unknown";

const isLocal = (env: Env): boolean => /^http:\/\/localhost(?::\d+)?\/?$/.test(env.PUBLIC_ORIGIN ?? "");

// General limiters fail open so a limiter outage does not take the API down.
// The sign-in limiter guards credential-minting routes, so it fails closed
// unless the Worker is running locally without the binding.
async function allowed(env: Env, limiter: RateLimit | undefined, key: string, failClosed = false): Promise<boolean> {
  if (!limiter) {
    if (failClosed && !isLocal(env)) {
      console.error("Rate limiter binding missing; refusing", key.split(":")[0]);
      return false;
    }
    return true;
  }
  try { return (await limiter.limit({ key })).success; }
  catch (cause) {
    console.warn("Rate limiter failed", key.split(":")[0], cause instanceof Error ? cause.message : "unknown error");
    return !failClosed;
  }
}

export const sourceAllowed = (env: Env, req: Request): Promise<boolean> =>
  allowed(env, env.SOURCE_LIMITER, `source:${sourceKey(req)}`);
export const signInAllowed = (env: Env, req: Request): Promise<boolean> =>
  allowed(env, env.SIGN_IN_LIMITER, `sign-in:${sourceKey(req)}`, true);
export const tenantAllowed = (env: Env, tenantId: string): Promise<boolean> =>
  allowed(env, env.TENANT_LIMITER, `tenant:${tenantId}`);
