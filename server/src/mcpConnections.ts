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
};

export async function listMcpConnections(env: Env, principal: Principal): Promise<Response> {
  if (principal.kind !== "app") return json({ error: "Forbidden" }, 403);
  const rows = await env.DB.prepare(`SELECT id, label, scopes, created_at, last_used_at, expires_at
    FROM credentials WHERE tenant_id = ? AND kind = 'mcp'
      AND revoked_at IS NULL AND expires_at > ?
    ORDER BY created_at DESC`).bind(principal.tenantId, new Date().toISOString()).all<ConnectionRow>();
  return json({ connections: rows.results.map((row) => ({
    id: row.id,
    clientName: row.label.startsWith("MCP · ") ? row.label.slice("MCP · ".length) : row.label,
    scopes: row.scopes.split(" ").filter(Boolean),
    connectedAt: row.created_at,
    lastUsedAt: row.last_used_at,
    expiresAt: row.expires_at,
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
  if (result.meta.changes === 1 && row) await closeFoodEventStream(env, principal.tenantId, row.token_hash);
  return result.meta.changes === 1 ? json({ ok: true }) : json({ error: "Not found" }, 404);
}
