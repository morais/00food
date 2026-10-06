CREATE TABLE mcp_event_subscriptions (
  id TEXT PRIMARY KEY,
  tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL REFERENCES credentials(token_hash) ON DELETE CASCADE,
  name TEXT NOT NULL,
  arguments_json TEXT NOT NULL,
  callback_url TEXT NOT NULL,
  signing_secret TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX mcp_event_subscriptions_tenant ON mcp_event_subscriptions(tenant_id, name, expires_at);

CREATE TABLE mcp_event_deliveries (
  id TEXT PRIMARY KEY,
  tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  event_id INTEGER NOT NULL REFERENCES food_events(id) ON DELETE CASCADE,
  subscription_id TEXT NOT NULL REFERENCES mcp_event_subscriptions(id) ON DELETE CASCADE,
  attempts INTEGER NOT NULL DEFAULT 0,
  next_attempt_at TEXT NOT NULL,
  delivered_at TEXT,
  failed_at TEXT,
  UNIQUE(event_id, subscription_id)
);
CREATE INDEX mcp_event_deliveries_due ON mcp_event_deliveries(tenant_id, delivered_at, failed_at, next_attempt_at);
