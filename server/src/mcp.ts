import { z } from "zod";
import { publicOrigin, type Principal, type Scope } from "./auth";
import { appName, estimationView, findEstimation, foodView, json, proposeEstimation, proposalInput,
  setFoodFruitVegPortions, type Env } from "./api";
import { authChallenge } from "./oauth";
import { dailyFeedbackContext, dailyFeedbackView, dailyReviewGuidance, findDailyFeedback, saveDailyFeedback,
  type DailyFeedbackRow } from "./dailyFeedback";
import { foodEventsUri, listFoodEvents, recentFoodEvents } from "./foodEvents";
import { eventDefinitions, McpEventsError, subscribeWebhookEvent, unsubscribeWebhookEvent } from "./mcpWebhookEvents";

const uuid = z.uuid();
const tools = [
  {
    name: "list_pending_foods", title: "List Foods Awaiting Estimates",
    description: "List the signed-in person's unreviewed food descriptions and photos. Estimate only those with state pending.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false }, readOnly: true,
  },
  {
    name: "get_pending_food", title: "Get Food Awaiting Estimate",
    description: "Get one pending food's description and whether a photo is available. When it has a photo, inspect that photo too and use both together for the estimate.",
    inputSchema: z.toJSONSchema(z.strictObject({ id: uuid }), { io: "input" }), readOnly: true,
  },
  {
    name: "view_food_photo", title: "View Food Photo",
    description: "Return the photo for one pending food as an image. Use it together with that food's description from get_pending_food. The photo is private and removed after user review.",
    inputSchema: z.toJSONSchema(z.strictObject({ id: uuid }), { io: "input" }), readOnly: true,
  },
  {
    name: "propose_food_estimate", title: "Propose Food Estimate",
    description: "Propose a directional calorie estimate and 0–5 fruit/vegetable portions for one serving. Count meaningful produce portions, not a garnish; use 0 when uncertain. Explain the choices in reasoning. The person reviews them before logging.",
    inputSchema: z.toJSONSchema(proposalInput.extend({ id: uuid, reasoning: z.string().trim().min(1).max(2000),
      fruitVegPortions: z.number().int().min(0).max(5) }), { io: "input" }), readOnly: false,
  },
  {
    name: "list_known_foods", title: "List Known Foods",
    description: "See previously approved foods, calorie estimates, and fruit/vegetable portions; use these as context for a similar pending item.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false }, readOnly: true,
  },
  {
    name: "set_food_fruit_veg_portions", title: "Set Food Fruit and Vegetable Portions",
    description: "Correct a saved food's rough 0–5 fruit/vegetable portions per serving. Existing logs of that food are updated too. Use only when the person asks to classify or correct a food.",
    inputSchema: z.toJSONSchema(z.strictObject({ id: uuid,
      fruitVegPortions: z.number().int().min(0).max(5) }), { io: "input" }), readOnly: false,
  },
  {
    name: "list_food_events", title: "List Food Events",
    description: "Read new food logs, estimate requests, and user clarifications after a cursor. Call after a food-events resource notification or on reconnect. Follow estimate requests and clarifications with get_pending_food.",
    inputSchema: z.toJSONSchema(z.strictObject({ after: z.number().int().min(0).default(0) }), { io: "input" }), readOnly: true,
  },
  {
    name: "list_pending_daily_feedback", title: "List Pending Daily Feedback",
    description: "List completed days awaiting a short daily reflection. Call get_daily_feedback_request for the full seven-day food and Health context.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false }, readOnly: true,
  },
  {
    name: "get_daily_feedback_request", title: "Get Daily Feedback Request",
    description: "Read one day's foods, tracked calories and percentage-of-TDEE budget alongside the previous seven days of available Health water, active and resting energy, weight, and body fat. Follow the returned reviewGuidance. Fruit/veg progress is capped at 5 (meaning at least 5); water is recorded minimum intake and is not capped at 2 L. Missing Health values are null; pending foods are not in calorie totals.",
    inputSchema: z.toJSONSchema(z.strictObject({ id: uuid }), { io: "input" }), readOnly: true,
  },
  {
    name: "submit_daily_feedback", title: "Submit Daily Feedback",
    description: "Write a reflection on the completed day after reading get_daily_feedback_request. " + dailyReviewGuidance.join(" "),
    inputSchema: z.toJSONSchema(z.strictObject({ id: uuid, feedback: z.string().trim().min(1).max(4000) }),
      { io: "input" }), readOnly: false,
  },
].map(tool => ({ ...tool,
  securitySchemes: [{ type: "oauth2" as const, scopes: [scopeForTool(tool)] }],
  annotations: { title: tool.title, readOnlyHint: tool.readOnly,
    openWorldHint: false, destructiveHint: false, idempotentHint: tool.readOnly } }));

function scopeForTool(tool: { name: string; readOnly: boolean }): Scope {
  const daily = tool.name === "list_pending_daily_feedback" || tool.name === "get_daily_feedback_request"
    || tool.name === "submit_daily_feedback";
  return daily ? tool.readOnly ? "daily:read" : "daily:write"
    : tool.readOnly ? "food:read" : "food:write";
}

const ok = (id: unknown, result: unknown): Response => json({ jsonrpc: "2.0", id, result });
const error = (id: unknown, code: number, message: string): Response => json({ jsonrpc: "2.0", id, error: { code, message } });
const content = (value: unknown): unknown => ({ content: [{ type: "text", text: JSON.stringify(value) }] });

export async function routeMcp(req: Request, env: Env, principal: Principal): Promise<Response> {
  if (req.headers.get("origin") && req.headers.get("origin") !== new URL(req.url).origin) {
    return new Response(null, { status: 403 });
  }
  // No server-to-client SSE stream: an open stream keeps the account's Durable
  // Object billed the whole time. Streamable HTTP lets a server refuse GET with
  // 405; agents get events by webhook or catch up with list_food_events.
  if (req.method !== "POST") return new Response(null, { status: 405, headers: { Allow: "POST" } });
  if (Number(req.headers.get("content-length") || 0) > 25000) return error(null, -32600, "Request too large");
  let request: Record<string, unknown>;
  try {
    const raw = await req.text();
    if (raw.length > 25000) return error(null, -32600, "Request too large");
    request = JSON.parse(raw) as Record<string, unknown>;
    if (!request || typeof request !== "object" || Array.isArray(request)) throw Error();
  } catch { return error(null, -32700, "Invalid JSON"); }
  if (request.jsonrpc !== "2.0" || typeof request.method !== "string") return error(request.id ?? null, -32600, "Invalid JSON-RPC request");
  if (request.method.startsWith("notifications/")) return new Response(null, { status: 202 });
  const requestId = request.id;
  if (requestId === undefined || requestId === null) return error(null, -32600, "Request id required");
  const modern = req.headers.get("MCP-Protocol-Version") === "2026-07-28" || request.method === "server/discover";
  const respond = (result: Record<string, unknown>) => ok(requestId, modern ? { resultType: "complete", ...result } : result);
  const respondTool = (result: unknown) => respond(result as Record<string, unknown>);
  if (request.method === "server/discover") return ok(requestId, {
    resultType: "complete", supportedVersions: ["2026-07-28", "2025-11-25"],
    capabilities: { tools: {}, events: {} },
    _meta: { serverInfo: { name: appName(env), version: "0.2.0" } },
  });
  if (request.method === "events/list") {
    if (!principal.scopes.includes("food:read") && !principal.scopes.includes("daily:read")) {
      return authChallenge(env, 403, ["food:read", "daily:read"]);
    }
    return ok(requestId, { events: eventDefinitions });
  }
  if (request.method === "events/subscribe" || request.method === "events/unsubscribe") {
    const eventName = (request.params as { name?: unknown } | undefined)?.name;
    const requiredScope: Scope = eventName === "day.feedback_requested" ? "daily:read" : "food:read";
    if (!principal.scopes.includes(requiredScope)) {
      return authChallenge(env, 403, [...new Set([...principal.scopes, requiredScope])]);
    }
    try {
      const result = request.method === "events/subscribe"
        ? await subscribeWebhookEvent(env, principal, request.params)
        : await unsubscribeWebhookEvent(env, principal, request.params);
      console.info("MCP event subscription completed", request.method);
      return ok(requestId, result);
    } catch (cause) {
      if (cause instanceof McpEventsError) {
        console.warn("MCP event subscription rejected", request.method, cause.code, cause.reason ?? cause.message);
        return json({ jsonrpc: "2.0", id: requestId,
          error: { code: cause.code, message: cause.message, ...(cause.reason ? { data: { reason: cause.reason } } : {}) } });
      }
      if (cause instanceof z.ZodError) {
        console.warn("MCP event subscription rejected", request.method, -32602,
          cause.issues.map(issue => ({ path: issue.path.join("."), code: issue.code,
            ...("keys" in issue ? { keys: issue.keys } : {}) })));
        return error(requestId, -32602, "Invalid event subscription");
      }
      console.error("MCP event subscription failed", cause instanceof Error ? cause.message : "unknown error");
      return error(requestId, -32603, "Event subscription failed");
    }
  }
  if (request.method === "initialize") return ok(requestId, {
    protocolVersion: "2025-11-25", capabilities: { tools: { listChanged: false }, resources: { subscribe: false, listChanged: false } },
    serverInfo: { name: appName(env), version: "0.1.0" },
  });
  if (request.method === "ping") return ok(requestId, {});
  if (request.method === "tools/list") return respond({ tools });
  if (request.method === "resources/list") {
    if (!principal.scopes.includes("food:read")) return authChallenge(env, 403, ["food:read"]);
    return ok(requestId, { resources: [{ uri: foodEventsUri, name: "Food events",
      description: "New food logs, pending estimate requests, and user clarifications. Read to catch up; for push, subscribe to webhook events.",
      mimeType: "application/json" }] });
  }
  if (request.method === "resources/read") {
    if (!principal.scopes.includes("food:read")) return authChallenge(env, 403, ["food:read"]);
    const params = request.params as { uri?: unknown } | undefined;
    if (params?.uri !== foodEventsUri) return error(requestId, -32602, "Unknown resource URI");
    return ok(requestId, { contents: [{ uri: foodEventsUri, mimeType: "application/json",
      text: JSON.stringify(await recentFoodEvents(env, principal.tenantId)) }] });
  }
  if (request.method !== "tools/call") return error(requestId, -32601, "Method not found");
  const params = request.params as { name?: unknown; arguments?: unknown } | undefined;
  if (!params || typeof params.name !== "string") return error(requestId, -32602, "Missing tool name");
  const tool = tools.find(item => item.name === params.name);
  if (!tool) return error(requestId, -32602, "Unknown tool");
  const requiredScope = scopeForTool(tool);
  if (!principal.scopes.includes(requiredScope)) {
    const upgradeScopes = [...new Set([...principal.scopes, requiredScope])];
    if (!modern) return authChallenge(env, 403, upgradeScopes);
    const challenge = `Bearer resource_metadata="${publicOrigin(env)}/.well-known/oauth-protected-resource", `
      + `scope="${upgradeScopes.join(" ")}", error="insufficient_scope", `
      + `error_description="Additional 00Food permission required"`;
    return respondTool({ isError: true,
      content: [{ type: "text", text: `Additional ${requiredScope} permission required` }],
      _meta: { "mcp/www_authenticate": [challenge] } });
  }
  const args = params.arguments || {};
  try {
    switch (tool.name) {
    case "list_pending_foods": {
      const rows = await env.DB.prepare(`SELECT * FROM pending_estimations WHERE tenant_id = ?
        ORDER BY created_at DESC LIMIT 100`).bind(principal.tenantId).all();
      return respondTool(content({ foods: rows.results.map(r => estimationView(r as never)) }));
    }
    case "get_pending_food": {
      const { id } = z.strictObject({ id: uuid }).parse(args);
      const row = await findEstimation(env, principal.tenantId, id);
      if (!row) return respondTool({ isError: true, content: [{ type: "text", text: "Food not found" }] });
      return respondTool(content({ food: estimationView(row) }));
    }
    case "view_food_photo": {
      const { id } = z.strictObject({ id: uuid }).parse(args);
      const row = await findEstimation(env, principal.tenantId, id);
      if (!row?.photo_key || !env.PHOTOS) return respondTool({ isError: true, content: [{ type: "text", text: "Photo not found" }] });
      const photo = await env.PHOTOS.get(row.photo_key);
      if (!photo) return respondTool({ isError: true, content: [{ type: "text", text: "Photo not found" }] });
      const bytes = new Uint8Array(await photo.arrayBuffer());
      let binary = "";
      for (let offset = 0; offset < bytes.length; offset += 8192) {
        binary += String.fromCharCode(...bytes.subarray(offset, offset + 8192));
      }
      return respondTool({ content: [{ type: "image", data: btoa(binary), mimeType: "image/jpeg" }] });
    }
    case "propose_food_estimate": {
      const { id, ...proposal } = proposalInput.extend({ id: uuid, reasoning: z.string().trim().min(1).max(2000),
        fruitVegPortions: z.number().int().min(0).max(5) }).parse(args);
      const response = await proposeEstimation(env, principal.tenantId, id, proposal);
      return respondTool(content(await response.json()));
    }
    case "list_known_foods": {
      const rows = await env.DB.prepare(`SELECT * FROM foods WHERE tenant_id = ?
        ORDER BY use_count DESC, last_used_at DESC LIMIT 100`).bind(principal.tenantId).all();
      return respondTool(content({ foods: rows.results.map(r => foodView(r as never)) }));
    }
    case "set_food_fruit_veg_portions": {
      const { id, fruitVegPortions } = z.strictObject({ id: uuid,
        fruitVegPortions: z.number().int().min(0).max(5) }).parse(args);
      const food = await setFoodFruitVegPortions(env, principal.tenantId, id, fruitVegPortions);
      return respondTool(content(food ? { food } : { error: "Food not found" }));
    }
    case "list_food_events": {
      const { after } = z.strictObject({ after: z.number().int().min(0).default(0) }).parse(args);
      return respondTool(content(await listFoodEvents(env, principal.tenantId, after)));
    }
    case "list_pending_daily_feedback": {
      const rows = await env.DB.prepare(`SELECT * FROM daily_feedback_requests
        WHERE tenant_id = ? AND state = 'pending' ORDER BY local_date DESC LIMIT 30`)
        .bind(principal.tenantId).all<DailyFeedbackRow>();
      return respondTool(content({ requests: rows.results.map(dailyFeedbackView) }));
    }
    case "get_daily_feedback_request": {
      const { id } = z.strictObject({ id: uuid }).parse(args);
      const row = await findDailyFeedback(env, principal.tenantId, id);
      if (!row) return respondTool({ isError: true, content: [{ type: "text", text: "Feedback request not found" }] });
      return respondTool(content({ request: dailyFeedbackView(row), context: await dailyFeedbackContext(env, row) }));
    }
    case "submit_daily_feedback": {
      const { id, feedback } = z.strictObject({ id: uuid,
        feedback: z.string().trim().min(1).max(4000) }).parse(args);
      const row = await saveDailyFeedback(env, principal.tenantId, id, feedback);
      if (!row) return respondTool({ isError: true, content: [{ type: "text", text: "Feedback request not found" }] });
      return respondTool(content({ request: dailyFeedbackView(row) }));
    }
    }
  } catch (cause) {
    if (cause instanceof z.ZodError) return error(requestId, -32602, "Invalid tool input");
    console.error("MCP food tool failed", cause instanceof Error ? cause.message : "unknown error");
    return respondTool({ isError: true, content: [{ type: "text", text: "Could not process food" }] });
  }
  return error(requestId, -32601, "Unknown tool");
}
