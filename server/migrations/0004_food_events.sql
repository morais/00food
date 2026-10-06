ALTER TABLE pending_estimations ADD COLUMN agent_reasoning TEXT;
ALTER TABLE pending_estimations ADD COLUMN user_clarification TEXT;
ALTER TABLE pending_estimations ADD COLUMN clarification_id TEXT;

CREATE TABLE food_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  event_key TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('food_logged', 'estimate_requested', 'clarification_added')),
  subject_id TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  created_at TEXT NOT NULL,
  UNIQUE(tenant_id, event_key)
);
CREATE INDEX food_events_tenant_cursor ON food_events(tenant_id, id);
CREATE INDEX food_events_created ON food_events(created_at);

CREATE TABLE mcp_resource_subscriptions (
  token_hash TEXT NOT NULL REFERENCES credentials(token_hash) ON DELETE CASCADE,
  tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  resource_uri TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY(token_hash, resource_uri)
);
