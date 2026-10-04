import { z } from "zod";
import { type Principal } from "./auth";
import { appName, estimationView, findEstimation, foodView, json, proposeEstimation, proposalInput, type Env } from "./api";
import { authChallenge } from "./oauth";

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
    description: "Propose a directional calorie estimate for one serving. State a useful serving size and any uncertainty in note. The person must review it before it is logged and reused.",
    inputSchema: z.toJSONSchema(proposalInput.extend({ id: uuid }), { io: "input" }), readOnly: false,
  },
  {
    name: "list_known_foods", title: "List Known Foods",
    description: "See previously approved foods and their calorie estimates; use these as context for a similar pending item.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false }, readOnly: true,
  },
].map(tool => ({ ...tool, annotations: { title: tool.title, readOnlyHint: tool.readOnly,
  openWorldHint: false, destructiveHint: false, idempotentHint: tool.readOnly } }));

const ok = (id: unknown, result: unknown): Response => json({ jsonrpc: "2.0", id, result });
const error = (id: unknown, code: number, message: string): Response => json({ jsonrpc: "2.0", id, error: { code, message } });
const content = (value: unknown): unknown => ({ content: [{ type: "text", text: JSON.stringify(value) }] });

export async function routeMcp(req: Request, env: Env, principal: Principal): Promise<Response> {
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
  if (request.method === "initialize") return ok(requestId, {
    protocolVersion: "2025-11-25", capabilities: { tools: { listChanged: false } },
    serverInfo: { name: appName(env), version: "0.1.0" },
  });
  if (request.method === "ping") return ok(requestId, {});
  if (request.method === "tools/list") return ok(requestId, { tools });
  if (request.method !== "tools/call") return error(requestId, -32601, "Method not found");
  const params = request.params as { name?: unknown; arguments?: unknown } | undefined;
  if (!params || typeof params.name !== "string") return error(requestId, -32602, "Missing tool name");
  const tool = tools.find(item => item.name === params.name);
  if (!tool) return error(requestId, -32602, "Unknown tool");
  if (tool.readOnly && !principal.scopes.includes("food:read") || !tool.readOnly && !principal.scopes.includes("food:write")) {
    return authChallenge(env, 403, [tool.readOnly ? "food:read" : "food:write"]);
  }
  const args = params.arguments || {};
  try {
    switch (tool.name) {
    case "list_pending_foods": {
      const rows = await env.DB.prepare(`SELECT * FROM pending_estimations WHERE tenant_id = ?
        ORDER BY created_at DESC LIMIT 100`).bind(principal.tenantId).all();
      return ok(requestId, content({ foods: rows.results.map(r => estimationView(r as never)) }));
    }
    case "get_pending_food": {
      const { id } = z.strictObject({ id: uuid }).parse(args);
      const row = await findEstimation(env, principal.tenantId, id);
      if (!row) return ok(requestId, { isError: true, content: [{ type: "text", text: "Food not found" }] });
      return ok(requestId, content({ food: estimationView(row) }));
    }
    case "view_food_photo": {
      const { id } = z.strictObject({ id: uuid }).parse(args);
      const row = await findEstimation(env, principal.tenantId, id);
      if (!row?.photo_key || !env.PHOTOS) return ok(requestId, { isError: true, content: [{ type: "text", text: "Photo not found" }] });
      const photo = await env.PHOTOS.get(row.photo_key);
      if (!photo) return ok(requestId, { isError: true, content: [{ type: "text", text: "Photo not found" }] });
      const bytes = new Uint8Array(await photo.arrayBuffer());
      let binary = "";
      for (let offset = 0; offset < bytes.length; offset += 8192) {
        binary += String.fromCharCode(...bytes.subarray(offset, offset + 8192));
      }
      return ok(requestId, { content: [{ type: "image", data: btoa(binary), mimeType: "image/jpeg" }] });
    }
    case "propose_food_estimate": {
      const { id, ...proposal } = proposalInput.extend({ id: uuid }).parse(args);
      const response = await proposeEstimation(env, principal.tenantId, id, proposal);
      return ok(requestId, content(await response.json()));
    }
    case "list_known_foods": {
      const rows = await env.DB.prepare(`SELECT * FROM foods WHERE tenant_id = ?
        ORDER BY use_count DESC, last_used_at DESC LIMIT 100`).bind(principal.tenantId).all();
      return ok(requestId, content({ foods: rows.results.map(r => foodView(r as never)) }));
    }
    }
  } catch (cause) {
    if (cause instanceof z.ZodError) return error(requestId, -32602, "Invalid tool input");
    console.error("MCP food tool failed", cause instanceof Error ? cause.message : "unknown error");
    return ok(requestId, { isError: true, content: [{ type: "text", text: "Could not process food" }] });
  }
  return error(requestId, -32601, "Unknown tool");
}
