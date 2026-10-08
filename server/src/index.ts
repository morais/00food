import { routeApi, json, type Env } from "./api";
import { routeMcp } from "./mcp";
export { FoodEventStream } from "./FoodEventStream";
import { authenticate, publicOrigin } from "./auth";
import { deleteAccount, signInWithApple, signOut } from "./appAuth";
import { disconnectMcpConnection, listMcpConnections } from "./mcpConnections";
import { sweepExpiredAuthData } from "./cleanup";
import { isSignInRoute, signInAllowed, sourceAllowed, tenantAllowed, tooManyRequests } from "./rateLimit";
import {
  appleCallback, authChallenge, authorizationServerMetadata, beginAuthorization,
  decideConsent, exchangeCode, protectedResourceMetadata, registerClient, showConsent,
  showReviewLogin, reviewCallback,
} from "./oauth";

export default {
  async fetch(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const path = new URL(req.url).pathname;
    const method = req.method;
    if (path === "/health" && method === "GET") return json({ ok: true });
    if (!(await sourceAllowed(env, req))) return tooManyRequests();
    if (isSignInRoute(path, method) && !(await signInAllowed(env, req))) return tooManyRequests();
    if (path === "/.well-known/oauth-protected-resource" && method === "GET") return protectedResourceMetadata(env);
    if (path === "/.well-known/oauth-protected-resource/mcp" && method === "GET") return protectedResourceMetadata(env);
    if (path === "/.well-known/oauth-authorization-server" && method === "GET") return authorizationServerMetadata(env);
    if (path === "/oauth/register" && method === "POST") return registerClient(req, env);
    if (path === "/oauth/authorize" && method === "GET") return beginAuthorization(req, env);
    if (path === "/oauth/login" && method === "GET") return showReviewLogin(req, env);
    if (path === "/auth/apple/callback" && method === "POST") return appleCallback(req, env, ctx);
    if (path === "/auth/review/callback" && method === "POST") return reviewCallback(req, env);
    if (path === "/oauth/consent" && method === "GET") return showConsent(req, env);
    if (path === "/oauth/consent" && method === "POST") return decideConsent(req, env);
    if (path === "/oauth/token" && method === "POST") return exchangeCode(req, env);
    if (path === "/v1/auth/apple" && method === "POST") return signInWithApple(req, env, ctx);
    if (path === "/mcp") {
      const principal = await authenticate(req, env, "mcp");
      if (!principal) return authChallenge(env);
      if (!(await tenantAllowed(env, principal.tenantId))) return tooManyRequests();
      return routeMcp(req, env, principal);
    }
    if (path.startsWith("/v1/")) {
      const principal = await authenticate(req, env, "app");
      if (!principal) return json({ error: "Unauthorized" }, 401);
      if (!(await tenantAllowed(env, principal.tenantId))) return tooManyRequests();
      if (path === "/v1/auth/logout" && method === "POST") return signOut(env, principal);
      if (path === "/v1/auth/delete-account" && method === "POST") return deleteAccount(req, env, principal, ctx);
      if (path === "/v1/account/mcp-connections" && method === "GET") return listMcpConnections(env, principal);
      const connection = /^\/v1\/account\/mcp-connections\/([a-f0-9-]{36})$/.exec(path);
      if (connection && method === "DELETE") return disconnectMcpConnection(env, principal, connection[1]);
      return routeApi(req, env, principal);
    }
    if (path === "/") return Response.redirect(`${publicOrigin(env)}/health`, 302);
    return json({ error: "Not found" }, 404);
  },
  async scheduled(_controller: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    ctx.waitUntil(sweepExpiredAuthData(env).catch((cause) => {
      console.error("Scheduled cleanup failed", cause instanceof Error ? cause.message : "unknown error");
    }));
  },
};
