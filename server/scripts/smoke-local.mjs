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
const dailyMcpToken = `fd_mcp_${randomBytes(32).toString("base64url")}`;
const hash = value => createHash("sha256").update(value).digest("hex");
const now = new Date().toISOString();
const expires = new Date(Date.now() + 3600000).toISOString();
const sql = `INSERT INTO tenants (id, apple_subject, created_at, updated_at) VALUES ('${tenant}','local-${tenant}','${now}','${now}');
INSERT INTO tenants (id, apple_subject, created_at, updated_at) VALUES ('${otherTenant}','local-${otherTenant}','${now}','${now}');
INSERT INTO credentials (token_hash,id,tenant_id,kind,audience,scopes,label,created_at,expires_at)
VALUES ('${hash(appToken)}','${randomUUID()}','${tenant}','app','${origin}/v1','food:read food:write','Local smoke','${now}','${expires}');
INSERT INTO credentials (token_hash,id,tenant_id,kind,audience,scopes,label,created_at,expires_at)
VALUES ('${hash(mcpToken)}','${randomUUID()}','${tenant}','mcp','${origin}/mcp','food:read food:write','Local smoke','${now}','${expires}');`;
const dailySQL = `INSERT INTO credentials (token_hash,id,tenant_id,kind,audience,scopes,label,created_at,expires_at)
VALUES ('${hash(dailyMcpToken)}','${randomUUID()}','${tenant}','mcp','${origin}/mcp','food:read daily:read daily:write','Local daily smoke','${now}','${expires}');`;
const otherSQL = `INSERT INTO credentials (token_hash,id,tenant_id,kind,audience,scopes,label,created_at,expires_at)
VALUES ('${hash(otherToken)}','${randomUUID()}','${otherTenant}','app','${origin}/v1','food:read food:write','Local smoke','${now}','${expires}');`;
for (const command of [sql, otherSQL, dailySQL]) {
  try {
    execFileSync("npx", ["wrangler", "d1", "execute", "00food", "--local", "--command", command]);
  } catch (error) {
    throw Error(`Could not seed local smoke data: ${error.stderr?.toString() ?? error.message}`);
  }
}

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
const savedProfile = (await request("/v1/profile", "PUT", {
  heightCm: 170, weightKg: 70, estimateProfile: "neutral", deficitKcal: 300, birthYear: 1988,
})).profile;
assert(savedProfile.birthYear === 1988, "birth year was not saved");
await request("/v1/profile", "PUT", {
  heightCm: 170, weightKg: 70, estimateProfile: "neutral", deficitKcal: 300,
});
assert((await request("/v1/snapshot")).profile.birthYear === 1988,
  "older profile clients cleared the birth year");
const food = (await request("/v1/foods", "POST", { id: randomUUID(), name: "Test banana",
  serving: "1 medium", kcal: 105, fruitVegPortions: 1 })).food;
assert(food.fruitVegPortions === 1, "manual food lost its fruit/veg portion count");
const otherLog = await fetch(origin + "/v1/logs", { method: "POST", headers: {
  Authorization: `Bearer ${otherToken}`, "Content-Type": "application/json",
}, body: JSON.stringify({ foodId: food.id, localDate: "2026-10-03" }) });
assert(otherLog.status === 404, "another account could log a private food");
const appMcp = await fetch(origin + "/mcp", { method: "POST", headers: { Authorization: `Bearer ${appToken}` } });
assert(appMcp.status === 401, "app credential was accepted by MCP");
const mcpApp = await fetch(origin + "/v1/snapshot", { headers: { Authorization: `Bearer ${mcpToken}` } });
assert(mcpApp.status === 401, "MCP credential was accepted by app API");
const discovered = await request("/mcp", "POST", { jsonrpc: "2.0", id: 15,
  method: "server/discover" }, mcpToken);
assert(discovered.result?.capabilities?.events && discovered.result?.supportedVersions?.includes("2026-07-28"),
  "MCP 2.0 event discovery failed");
const modernTools = await fetch(origin + "/mcp", { method: "POST", headers: {
  Authorization: `Bearer ${mcpToken}`, "Content-Type": "application/json",
  "MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/list",
}, body: JSON.stringify({ jsonrpc: "2.0", id: 17, method: "tools/list" }) });
assert((await modernTools.json()).result?.resultType === "complete", "MCP 2.0 tools were not listed");
const catalog = await request("/mcp", "POST", { jsonrpc: "2.0", id: 16,
  method: "events/list" }, mcpToken);
assert(catalog.result?.events?.some(event => event.name === "food.estimate_requested") &&
  catalog.result?.events?.some(event => event.name === "food.clarification_added"),
"MCP webhook event catalog is incomplete");
const stream = await fetch(origin + "/mcp", { headers: { Authorization: `Bearer ${mcpToken}`,
  Accept: "text/event-stream" } });
assert(stream.ok && stream.headers.get("content-type")?.includes("text/event-stream"), "MCP event stream failed");
const reader = stream.body.getReader();
await reader.read(); // Initial SSE comment.
const subscription = await request("/mcp", "POST", { jsonrpc: "2.0", id: 10,
  method: "resources/subscribe", params: { uri: "food://events" } }, mcpToken);
assert(subscription.result && !subscription.error, "food event subscription failed");
const logId = randomUUID();
await request("/v1/logs", "POST", { id: logId, foodId: food.id, quantity: 1, localDate: "2026-10-03" });
let frame = "";
for (let chunk = 0; chunk < 20 && !frame.includes("\n\n"); chunk++) {
  const notification = await Promise.race([reader.read(), new Promise((_, reject) =>
    setTimeout(() => reject(Error("Food event notification timed out")), 5000))]);
  frame += new TextDecoder().decode(notification.value);
}
assert(frame.includes("notifications/resources/updated"), "food log did not notify MCP subscriber");
await reader.cancel();
await request("/v1/logs", "POST", { id: logId, foodId: food.id, quantity: 1, localDate: "2026-10-03" });
const events = await request("/mcp", "POST", { jsonrpc: "2.0", id: 11, method: "tools/call",
  params: { name: "list_food_events", arguments: { after: 0 } } }, mcpToken);
const loggedEvents = JSON.parse(events.result.content[0].text).events.filter(event => event.subjectId === logId);
assert(loggedEvents.length === 1, "retry duplicated the food log event");
const afterLog = await request("/v1/snapshot");
assert(afterLog.foods[0].useCount === 1 && afterLog.logs.length === 1, "log retry was not idempotent");
assert(afterLog.logs[0].fruitVegPortions === 1, "logged fruit/veg portions were not saved");
const yesterday = new Date(Date.now() - 86400000).toISOString().slice(0, 10);
const dailyLog = (await request("/v1/logs", "POST", {
  id: randomUUID(), foodId: food.id, quantity: 1, localDate: yesterday,
})).log;
const dailyId = randomUUID();
const dailyBody = { id: dailyId, localDate: yesterday, timeZone: "UTC", healthDays: [{
  localDate: yesterday, activeKcal: 420, restingKcal: 1650, waterMl: 1500,
  weightKg: 76.2, bodyFatPercent: 27.1,
}] };
const dailyRequest = (await request("/v1/daily-feedback", "POST", dailyBody)).request;
assert(dailyRequest.id === dailyId && dailyRequest.state === "pending", "daily request was not saved");
const dailyRetry = (await request("/v1/daily-feedback", "POST", { ...dailyBody, id: randomUUID() })).request;
assert(dailyRetry.id === dailyId, "daily retry duplicated the day");
assert((await request("/v1/snapshot")).dailyFeedback.some(item => item.id === dailyId),
  "daily request was missing from snapshot");
assert((await request("/v1/daily-feedback")).requests.some(item => item.id === dailyId),
  "daily request endpoint omitted the day");
assert(!(await request("/v1/daily-feedback", "GET", undefined, otherToken)).requests.some(item => item.id === dailyId),
  "another account saw the daily request");
const deniedDaily = await fetch(origin + "/mcp", { method: "POST", headers: {
  Authorization: `Bearer ${mcpToken}`, "Content-Type": "application/json",
}, body: JSON.stringify({ jsonrpc: "2.0", id: 41, method: "tools/call",
  params: { name: "get_daily_feedback_request", arguments: { id: dailyId } } }) });
assert(deniedDaily.status === 403, "old MCP credential could read Health summary");
const pendingDaily = await request("/mcp", "POST", { jsonrpc: "2.0", id: 42,
  method: "tools/call", params: { name: "list_pending_daily_feedback", arguments: {} } }, dailyMcpToken);
assert(JSON.parse(pendingDaily.result.content[0].text).requests.some(item => item.id === dailyId),
  "agent could not find pending daily feedback");
const contextResult = await request("/mcp", "POST", { jsonrpc: "2.0", id: 43,
  method: "tools/call", params: { name: "get_daily_feedback_request", arguments: { id: dailyId } } }, dailyMcpToken);
const dailyContext = JSON.parse(contextResult.result.content[0].text).context;
const feedbackDay = dailyContext.days.find(day => day.localDate === yesterday);
assert(feedbackDay.health.waterMl === 1500 && feedbackDay.health.activeKcal === 420 &&
  feedbackDay.health.restingKcal === 1650 && feedbackDay.health.weightKg === 76.2 &&
  feedbackDay.health.bodyFatPercent === 27.1 &&
  feedbackDay.foods.some(item => item.id === dailyLog.id && item.kcal === 105),
  "daily context lost foods or Health values");
await request("/mcp", "POST", { jsonrpc: "2.0", id: 44,
  method: "tools/call", params: { name: "submit_daily_feedback", arguments: {
    id: dailyId, feedback: "A directional review of the day.",
  } } }, dailyMcpToken);
assert((await request("/v1/daily-feedback")).requests.find(item => item.id === dailyId)?.state === "ready",
  "agent feedback was not saved");
const portionUpdate = await request("/mcp", "POST", { jsonrpc: "2.0", id: 18,
  method: "tools/call", params: { name: "set_food_fruit_veg_portions",
    arguments: { id: food.id, fruitVegPortions: 2 } } }, mcpToken);
assert(JSON.parse(portionUpdate.result.content[0].text).food.fruitVegPortions === 2,
  "agent could not correct saved food portions");
assert((await request("/v1/snapshot")).logs[0].fruitVegPortions === 2,
  "correcting a saved food did not update its earlier log");
const hidden = await request(`/v1/foods/${food.id}/dismiss`, "POST");
assert(hidden.food.dismissedAt, "food was not hidden from frequent foods");
const secondLog = (await request("/v1/logs", "POST", {
  id: randomUUID(), foodId: food.id, quantity: 1, localDate: "2026-10-03",
})).log;
const restored = await request("/v1/snapshot");
assert(restored.foods[0].dismissedAt === null, "logging a hidden food did not restore it");
await request(`/v1/logs/${secondLog.id}`, "DELETE");
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
    fruitVegPortions: 1,
    reasoning: "The small bowl appears to hold about one cup of berries.",
  } } }, mcpToken);
assert(toolResult.result?.content?.length, "agent proposal failed");
assert(JSON.parse(toolResult.result.content[0].text).estimation.reasoning?.includes("one cup"),
  "agent reasoning was not saved");
const clarificationId = randomUUID();
await request(`/v1/estimations/${estimate.id}/clarifications`, "POST", {
  id: clarificationId, text: "The bowl has sweetened yogurt underneath.",
});
await request(`/v1/estimations/${estimate.id}/clarifications`, "POST", {
  id: clarificationId, text: "The bowl has sweetened yogurt underneath.",
});
const clarified = await request("/mcp", "POST", { jsonrpc: "2.0", id: 12, method: "tools/call",
  params: { name: "get_pending_food", arguments: { id: estimate.id } } }, mcpToken);
const clarifiedFood = JSON.parse(clarified.result.content[0].text).food;
assert(clarifiedFood.state === "pending" && clarifiedFood.clarification?.includes("yogurt"),
  "agent did not receive clarification");
const eventsAfterClarification = await request("/mcp", "POST", { jsonrpc: "2.0", id: 13, method: "tools/call",
  params: { name: "list_food_events", arguments: { after: 0 } } }, mcpToken);
assert(JSON.parse(eventsAfterClarification.result.content[0].text).events.filter(event =>
  event.kind === "clarification_added" && event.subjectId === estimate.id).length === 1,
"clarification retry duplicated its event");
await request("/mcp", "POST", { jsonrpc: "2.0", id: 14, method: "tools/call",
  params: { name: "propose_food_estimate", arguments: {
    id: estimate.id, name: "Berries and yogurt", serving: "1 small bowl", kcal: 190,
    fruitVegPortions: 1,
    reasoning: "Berries plus sweetened yogurt add up to roughly 190 kcal.",
  } } }, mcpToken);
await request(`/v1/estimations/${estimate.id}/accept`, "POST");
const final = await request("/v1/snapshot");
assert(final.foods.length === 2 && final.logs.length === 3 && final.estimations.length === 0,
  "review did not save food and log");
assert(final.foods.some(item => item.name === "Berries and yogurt" && item.fruitVegPortions === 1) &&
  final.logs.some(item => item.foodName === "Berries and yogurt" && item.fruitVegPortions === 1),
  "review did not keep the agent's fruit/veg portions");
const combinedDescription = "Toast with butter, one slice";
const combined = (await request("/v1/estimations", "POST", {
  id: randomUUID(), description: combinedDescription,
  photoBase64: jpeg.toString("base64"), localDate: "2026-10-03",
})).estimation;
assert(combined.description === combinedDescription && combined.hasPhoto,
  "combined photo and description were not saved together");
const combinedFood = await request("/mcp", "POST", { jsonrpc: "2.0", id: 4, method: "tools/call",
  params: { name: "get_pending_food", arguments: { id: combined.id } } }, mcpToken);
const combinedForAgent = JSON.parse(combinedFood.result?.content?.[0]?.text ?? "{}").food;
assert(combinedForAgent?.description === combinedDescription && combinedForAgent?.hasPhoto === true,
  "agent did not receive the combined text/photo item");
const combinedImage = await request("/mcp", "POST", { jsonrpc: "2.0", id: 5, method: "tools/call",
  params: { name: "view_food_photo", arguments: { id: combined.id } } }, mcpToken);
assert(combinedImage.result?.content?.[0]?.type === "image", "agent could not inspect the combined photo");
await request(`/v1/estimations/${combined.id}`, "DELETE");
console.log("00Food local smoke passed: produce portions, repeat log, hide and restore food, isolation, photo/text, MCP review");
