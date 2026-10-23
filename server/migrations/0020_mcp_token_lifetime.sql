-- Extend active MCP connections to one year from issuance. Never revive an
-- expired or revoked connection, shorten a longer lifetime, or change app login.
UPDATE credentials
SET expires_at = strftime('%Y-%m-%dT%H:%M:%fZ', created_at, '+365 days')
WHERE kind = 'mcp'
  AND revoked_at IS NULL
  AND julianday(expires_at) > julianday('now')
  AND julianday(created_at, '+365 days') > julianday(expires_at);
