import { json, type Env } from "./api";

export const tooManyRequests = (): Response => {
  const response = json({ error: "Too many requests. Try again in a minute." }, 429);
  response.headers.set("Retry-After", "60");
  return response;
};

const sourceKey = (req: Request): string => req.headers.get("cf-connecting-ip")?.trim() || "unknown";

async function allowed(limiter: RateLimit | undefined, key: string): Promise<boolean> {
  if (!limiter) return true;
  try { return (await limiter.limit({ key })).success; }
  catch { return true; }
}

export const sourceAllowed = (env: Env, req: Request): Promise<boolean> =>
  allowed(env.SOURCE_LIMITER, `source:${sourceKey(req)}`);
export const signInAllowed = (env: Env, req: Request): Promise<boolean> =>
  allowed(env.SIGN_IN_LIMITER, `sign-in:${sourceKey(req)}`);
export const tenantAllowed = (env: Env, tenantId: string): Promise<boolean> =>
  allowed(env.TENANT_LIMITER, `tenant:${tenantId}`);
