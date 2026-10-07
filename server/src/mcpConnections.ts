import { json, type Env } from "./api";
import type { Principal } from "./auth";
import { closeFoodEventStream } from "./foodEvents";

type ConnectionRow = {
  id: string;
  label: string;
  scopes: string;
  created_at: string;
  last_used_at: string | null;
  expires_at: string;
  active_events: string | null;
};

export async function listMcpConnections(env: Env, principal: Principal): Promise<Response> {
  if (principal.kind !== "app") return json({ error: "Forbidden" }, 403);
  const now = new Date().toISOString();
  const rows = await env.DB.prepare(`SELECT c.id, c.label, c.scopes, c.created_at, c.last_used_at, c.expires_at,
      (SELECT GROUP_CONCAT(DISTINCT s.name) FROM mcp_event_subscriptions s
        WHERE s.token_hash = c.token_hash AND s.tenant_id = c.tenant_id AND s.expires_at > ?) AS active_events
    FROM credentials c WHERE c.tenant_id = ? AND c.kind = 'mcp'
      AND c.revoked_at IS NULL AND c.expires_at > ?
    ORDER BY c.created_at DESC`).bind(now, principal.tenantId, now).all<ConnectionRow>();
  return json({ connections: rows.results.map((row) => ({
    id: row.id,
    clientName: row.label.startsWith("MCP · ") ? row.label.slice("MCP · ".length) : row.label,
    scopes: row.scopes.split(" ").filter(Boolean),
    connectedAt: row.created_at,
    lastUsedAt: row.last_used_at,
    expiresAt: row.expires_at,
    activeEvents: row.active_events?.split(",").sort() ?? [],
  })) });
}

export async function disconnectMcpConnection(env: Env, principal: Principal, id: string): Promise<Response> {
  if (principal.kind !== "app") return json({ error: "Forbidden" }, 403);
  if (!/^[a-f0-9-]{32,36}$/.test(id)) return json({ error: "Not found" }, 404);
  const row = await env.DB.prepare("SELECT token_hash FROM credentials WHERE id = ? AND tenant_id = ? AND kind = 'mcp'")
    .bind(id, principal.tenantId).first<{ token_hash: string }>();
  const result = await env.DB.prepare(`UPDATE credentials SET revoked_at = ?
    WHERE id = ? AND tenant_id = ? AND kind = 'mcp' AND revoked_at IS NULL AND expires_at > ?`)
    .bind(new Date().toISOString(), id, principal.tenantId, new Date().toISOString()).run();
  if (result.meta.changes === 1 && row) {
    await env.DB.prepare("DELETE FROM mcp_event_subscriptions WHERE token_hash = ? AND tenant_id = ?")
      .bind(row.token_hash, principal.tenantId).run();
    await closeFoodEventStream(env, principal.tenantId, row.token_hash);
  }
  return result.meta.changes === 1 ? json({ ok: true }) : json({ error: "Not found" }, 404);
}
