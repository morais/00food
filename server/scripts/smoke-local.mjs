// Run against `wrangler dev --local` after applying local migrations.
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { createHash, randomBytes, randomUUID } from "node:crypto";

const origin = "http://localhost:8787";
const tenant = randomUUID();
const otherTenant = randomUUID();
const appToken = `fd_app_${randomBytes(32).toString("base64url")}`;
const otherToken = `fd_app_${randomBytes(32).toString("base64url")}`;
const mcpToken = `fd_mcp_${randomBytes(32).toString("base64url")}`;
const hash = value => createHash("sha256").update(value).digest("hex");
const now = new Date().toISOString();
const expires = new Date(Date.now() + 3600000).toISOString();
const sql = `INSERT INTO tenants (id, apple_subject, created_at, updated_at) VALUES ('${tenant}','local-${tenant}','${now}','${now}');
INSERT INTO tenants (id, apple_subject, created_at, updated_at) VALUES ('${otherTenant}','local-${otherTenant}','${now}','${now}');
INSERT INTO credentials (token_hash,id,tenant_id,kind,audience,scopes,label,created_at,expires_at)
VALUES ('${hash(appToken)}','${randomUUID()}','${tenant}','app','${origin}/v1','food:read food:write','Local smoke','${now}','${expires}');
INSERT INTO credentials (token_hash,id,tenant_id,kind,audience,scopes,label,created_at,expires_at)
VALUES ('${hash(mcpToken)}','${randomUUID()}','${tenant}','mcp','${origin}/mcp','food:read food:write','Local smoke','${now}','${expires}');`;
const otherSQL = `INSERT INTO credentials (token_hash,id,tenant_id,kind,audience,scopes,label,created_at,expires_at)
VALUES ('${hash(otherToken)}','${randomUUID()}','${otherTenant}','app','${origin}/v1','food:read food:write','Local smoke','${now}','${expires}');`;
execFileSync("npx", ["wrangler", "d1", "execute", "00food", "--local", "--command", sql], { stdio: "ignore" });
execFileSync("npx", ["wrangler", "d1", "execute", "00food", "--local", "--command", otherSQL], { stdio: "ignore" });

async function request(path, method = "GET", body, token = appToken) {
  const response = await fetch(origin + path, {
    method, headers: { Authorization: `Bearer ${token}`,
      ...(body === undefined ? {} : { "Content-Type": "application/json" }) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const payload = await response.json();
  if (!response.ok) throw Error(`${method} ${path}: ${response.status} ${JSON.stringify(payload)}`);
  return payload;
}
function assert(value, message) { if (!value) throw Error(message); }

const initial = await request("/v1/snapshot");
assert(initial.profile === null && initial.foods.length === 0 && initial.startedAt === now,
  "new account snapshot or creation date is wrong");
await request("/v1/profile", "PUT", { heightCm: 170, weightKg: 70, estimateProfile: "neutral", deficitKcal: 300 });
const food = (await request("/v1/foods", "POST", { id: randomUUID(), name: "Test banana", serving: "1 medium", kcal: 105 })).food;
const otherLog = await fetch(origin + "/v1/logs", { method: "POST", headers: {
  Authorization: `Bearer ${otherToken}`, "Content-Type": "application/json",
}, body: JSON.stringify({ foodId: food.id, localDate: "2026-10-03" }) });
assert(otherLog.status === 404, "another account could log a private food");
const appMcp = await fetch(origin + "/mcp", { method: "POST", headers: { Authorization: `Bearer ${appToken}` } });
assert(appMcp.status === 401, "app credential was accepted by MCP");
const mcpApp = await fetch(origin + "/v1/snapshot", { headers: { Authorization: `Bearer ${mcpToken}` } });
assert(mcpApp.status === 401, "MCP credential was accepted by app API");
const logId = randomUUID();
await request("/v1/logs", "POST", { id: logId, foodId: food.id, quantity: 1, localDate: "2026-10-03" });
await request("/v1/logs", "POST", { id: logId, foodId: food.id, quantity: 1, localDate: "2026-10-03" });
const afterLog = await request("/v1/snapshot");
assert(afterLog.foods[0].useCount === 1 && afterLog.logs.length === 1, "log retry was not idempotent");
const estimate = (await request("/v1/estimations", "POST", {
  id: randomUUID(), description: "Small bowl of berries", localDate: "2026-10-03",
})).estimation;
const otherPhoto = await fetch(`${origin}/v1/estimations/${estimate.id}/photo`, {
  method: "PUT", headers: { Authorization: `Bearer ${otherToken}`, "Content-Type": "image/jpeg" },
  body: Buffer.from([0xff, 0xd8, 0xff, 0xd9]),
});
assert(otherPhoto.status === 404, "another account could replace a private photo");
const jpeg = readFileSync(new URL("../test/fixtures/one-pixel.jpg", import.meta.url));
const upload = await fetch(`${origin}/v1/estimations/${estimate.id}/photo`, {
  method: "PUT", headers: { Authorization: `Bearer ${appToken}`, "Content-Type": "image/jpeg" }, body: jpeg,
});
assert(upload.ok, `photo upload failed (${upload.status}): ${upload.ok ? "" : await upload.text()}`);
const pending = await request("/mcp", "POST", { jsonrpc: "2.0", id: 3, method: "tools/call",
  params: { name: "get_pending_food", arguments: { id: estimate.id } } }, mcpToken);
assert(JSON.stringify(pending.result?.content).includes("Small bowl of berries") &&
  JSON.stringify(pending.result?.content).includes("hasPhoto"),
  "agent could not inspect the combined description and photo request");
const image = await request("/mcp", "POST", { jsonrpc: "2.0", id: 2, method: "tools/call",
  params: { name: "view_food_photo", arguments: { id: estimate.id } } }, mcpToken);
assert(image.result?.content?.[0]?.type === "image" && image.result.content[0].mimeType === "image/jpeg",
  "agent could not inspect photo");
const toolResult = await request("/mcp", "POST", { jsonrpc: "2.0", id: 1, method: "tools/call",
  params: { name: "propose_food_estimate", arguments: {
    id: estimate.id, name: "Berries", serving: "1 small bowl", kcal: 80, note: "Rough portion estimate",
  } } }, mcpToken);
assert(toolResult.result?.content?.length, "agent proposal failed");
await request(`/v1/estimations/${estimate.id}/accept`, "POST");
const final = await request("/v1/snapshot");
assert(final.foods.length === 2 && final.logs.length === 2 && final.estimations.length === 0,
  "review did not save food and log");
console.log("00Food local smoke passed: profile, repeat log, tenant isolation, credential separation, photo, MCP proposal, review");
