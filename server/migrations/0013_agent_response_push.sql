CREATE TABLE push_devices (
  tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  installation_id TEXT NOT NULL,
  credential_hash TEXT NOT NULL REFERENCES credentials(token_hash) ON DELETE CASCADE,
  device_token TEXT NOT NULL,
  environment TEXT NOT NULL CHECK (environment IN ('development', 'production')),
  enabled INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL,
  last_push_at INTEGER NOT NULL DEFAULT 0,
  delivered_version TEXT,
  PRIMARY KEY (tenant_id, installation_id),
  UNIQUE (device_token, environment)
);
CREATE INDEX push_devices_credential ON push_devices(credential_hash);

CREATE TABLE push_pending (
  tenant_id TEXT PRIMARY KEY REFERENCES tenants(id) ON DELETE CASCADE,
  version TEXT NOT NULL,
  queued_at INTEGER NOT NULL,
  due_at INTEGER NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX push_pending_due ON push_pending(due_at);

-- Queue the wake-up in the same transaction as the agent's reply. Only an
-- active app session with a registered device needs a push; MCP tokens do not.
CREATE TRIGGER food_response_push AFTER UPDATE ON pending_estimations
WHEN NEW.state = 'proposed' AND (
  OLD.state IS NOT NEW.state OR OLD.proposed_name IS NOT NEW.proposed_name OR
  OLD.proposed_serving IS NOT NEW.proposed_serving OR OLD.proposed_kcal IS NOT NEW.proposed_kcal OR
  OLD.agent_reasoning IS NOT NEW.agent_reasoning OR OLD.agent_note IS NOT NEW.agent_note OR
  OLD.proposed_fruit_veg_portions IS NOT NEW.proposed_fruit_veg_portions)
BEGIN
  INSERT INTO push_pending (tenant_id, version, queued_at, due_at)
  SELECT NEW.tenant_id, lower(hex(randomblob(16))), unixepoch() * 1000, unixepoch() * 1000
  WHERE EXISTS (SELECT 1 FROM push_devices d JOIN credentials c ON c.token_hash = d.credential_hash
    WHERE d.tenant_id = NEW.tenant_id AND d.enabled = 1 AND c.tenant_id = d.tenant_id
      AND c.kind = 'app' AND c.revoked_at IS NULL AND c.expires_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
  ON CONFLICT(tenant_id) DO UPDATE SET version = excluded.version, queued_at = excluded.queued_at,
    due_at = excluded.due_at, attempts = 0;
END;

CREATE TRIGGER daily_response_push AFTER UPDATE ON daily_feedback_requests
WHEN NEW.state = 'ready' AND (OLD.state IS NOT NEW.state OR OLD.feedback_text IS NOT NEW.feedback_text)
BEGIN
  INSERT INTO push_pending (tenant_id, version, queued_at, due_at)
  SELECT NEW.tenant_id, lower(hex(randomblob(16))), unixepoch() * 1000, unixepoch() * 1000
  WHERE EXISTS (SELECT 1 FROM push_devices d JOIN credentials c ON c.token_hash = d.credential_hash
    WHERE d.tenant_id = NEW.tenant_id AND d.enabled = 1 AND c.tenant_id = d.tenant_id
      AND c.kind = 'app' AND c.revoked_at IS NULL AND c.expires_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
  ON CONFLICT(tenant_id) DO UPDATE SET version = excluded.version, queued_at = excluded.queued_at,
    due_at = excluded.due_at, attempts = 0;
END;
