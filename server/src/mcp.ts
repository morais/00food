import { z } from "zod";
import { type Principal } from "./auth";
import { appName, estimationView, findEstimation, foodView, json, proposeEstimation, proposalInput,
  setFoodFruitVegPortions, type Env } from "./api";
import { authChallenge } from "./oauth";
import { dailyFeedbackContext, dailyFeedbackView, findDailyFeedback, saveDailyFeedback,
  type DailyFeedbackRow } from "./dailyFeedback";
import { closeFoodEventStream, foodEventsUri, listFoodEvents, recentFoodEvents } from "./foodEvents";
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
    description: "Read one day's foods and tracked calories alongside the previous seven days of available Health water, active and resting energy, weight, and body fat. Missing Health values are null; pending foods are not in calorie totals.",
    inputSchema: z.toJSONSchema(z.strictObject({ id: uuid }), { io: "input" }), readOnly: true,
  },
  {
    name: "submit_daily_feedback", title: "Submit Daily Feedback",
    description: "Write a brief, supportive reflection on the completed day. Use directional language, note missing or pending data, and avoid diagnoses or prescriptive calorie advice.",
    inputSchema: z.toJSONSchema(z.strictObject({ id: uuid, feedback: z.string().trim().min(1).max(4000) }),
      { io: "input" }), readOnly: false,
  },
].map(tool => ({ ...tool, annotations: { title: tool.title, readOnlyHint: tool.readOnly,
  openWorldHint: false, destructiveHint: false, idempotentHint: tool.readOnly } }));

const ok = (id: unknown, result: unknown): Response => json({ jsonrpc: "2.0", id, result });
const error = (id: unknown, code: number, message: string): Response => json({ jsonrpc: "2.0", id, error: { code, message } });
const content = (value: unknown): unknown => ({ content: [{ type: "text", text: JSON.stringify(value) }] });

export async function routeMcp(req: Request, env: Env, principal: Principal): Promise<Response> {
  if (req.headers.get("origin") && req.headers.get("origin") !== new URL(req.url).origin) {
    return new Response(null, { status: 403 });
  }
  if (req.method === "GET") {
    if (!principal.scopes.includes("food:read")) return authChallenge(env, 403, ["food:read"]);
    if (!req.headers.get("accept")?.includes("text/event-stream")) return new Response(null, { status: 406 });
    const subscription = await env.DB.prepare(`SELECT 1 FROM mcp_resource_subscriptions
      WHERE token_hash = ? AND tenant_id = ? AND resource_uri = ?`)
      .bind(principal.tokenHash, principal.tenantId, foodEventsUri).first();
    if (!env.FOOD_EVENTS) return new Response("Event stream unavailable", { status: 503 });
    return env.FOOD_EVENTS.getByName(principal.tenantId).fetch("https://events.internal/listen", {
      headers: { "x-token-hash": principal.tokenHash, "x-active": subscription ? "true" : "false" },
    });
  }
  if (req.method !== "POST") return new Response(null, { status: 405, headers: { Allow: "POST, GET" } });
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
    const requiredScope = eventName === "day.feedback_requested" ? "daily:read" : "food:read";
    if (!principal.scopes.includes(requiredScope)) return authChallenge(env, 403, [requiredScope]);
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
    protocolVersion: "2025-11-25", capabilities: { tools: { listChanged: false }, resources: { subscribe: true, listChanged: false } },
    serverInfo: { name: appName(env), version: "0.1.0" },
  });
  if (request.method === "ping") return ok(requestId, {});
  if (request.method === "tools/list") return respond({ tools });
  if (request.method === "resources/list") {
    if (!principal.scopes.includes("food:read")) return authChallenge(env, 403, ["food:read"]);
    return ok(requestId, { resources: [{ uri: foodEventsUri, name: "Food events",
      description: "New food logs, pending estimate requests, and user clarifications. Read after a change notification.",
      mimeType: "application/json" }] });
  }
  if (request.method === "resources/read" || request.method === "resources/subscribe" || request.method === "resources/unsubscribe") {
    if (!principal.scopes.includes("food:read")) return authChallenge(env, 403, ["food:read"]);
    const params = request.params as { uri?: unknown } | undefined;
    if (params?.uri !== foodEventsUri) return error(requestId, -32602, "Unknown resource URI");
    if (request.method === "resources/read") {
      return ok(requestId, { contents: [{ uri: foodEventsUri, mimeType: "application/json",
        text: JSON.stringify(await recentFoodEvents(env, principal.tenantId)) }] });
    }
    if (request.method === "resources/subscribe") {
      await env.DB.prepare(`INSERT OR IGNORE INTO mcp_resource_subscriptions
        (token_hash, tenant_id, resource_uri, created_at) VALUES (?, ?, ?, ?)`)
        .bind(principal.tokenHash, principal.tenantId, foodEventsUri, new Date().toISOString()).run();
      if (env.FOOD_EVENTS) await env.FOOD_EVENTS.getByName(principal.tenantId).fetch("https://events.internal/activate", {
        method: "POST", headers: { "x-token-hash": principal.tokenHash },
      });
    } else {
      await env.DB.prepare(`DELETE FROM mcp_resource_subscriptions
        WHERE token_hash = ? AND tenant_id = ? AND resource_uri = ?`)
        .bind(principal.tokenHash, principal.tenantId, foodEventsUri).run();
      await closeFoodEventStream(env, principal.tenantId, principal.tokenHash);
    }
    return ok(requestId, {});
  }
  if (request.method !== "tools/call") return error(requestId, -32601, "Method not found");
  const params = request.params as { name?: unknown; arguments?: unknown } | undefined;
  if (!params || typeof params.name !== "string") return error(requestId, -32602, "Missing tool name");
  const tool = tools.find(item => item.name === params.name);
  if (!tool) return error(requestId, -32602, "Unknown tool");
  const dailyTool = tool.name === "list_pending_daily_feedback" || tool.name === "get_daily_feedback_request"
    || tool.name === "submit_daily_feedback";
  const requiredScope = dailyTool ? tool.readOnly ? "daily:read" : "daily:write"
    : tool.readOnly ? "food:read" : "food:write";
  if (!principal.scopes.includes(requiredScope)) {
    return authChallenge(env, 403, [requiredScope]);
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
