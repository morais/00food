CREATE TABLE daily_feedback_requests (
  id TEXT PRIMARY KEY,
  tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  local_date TEXT NOT NULL,
  time_zone TEXT NOT NULL,
  health_json TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('pending', 'ready')),
  feedback_text TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE(tenant_id, local_date)
);
CREATE INDEX daily_feedback_recent ON daily_feedback_requests(tenant_id, local_date DESC);
CREATE INDEX daily_feedback_pending ON daily_feedback_requests(tenant_id, state, created_at);

CREATE TABLE daily_feedback_deliveries (
  id TEXT PRIMARY KEY,
  tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  request_id TEXT NOT NULL REFERENCES daily_feedback_requests(id) ON DELETE CASCADE,
  subscription_id TEXT NOT NULL REFERENCES mcp_event_subscriptions(id) ON DELETE CASCADE,
  attempts INTEGER NOT NULL DEFAULT 0,
  next_attempt_at TEXT NOT NULL,
  delivered_at TEXT,
  failed_at TEXT,
  UNIQUE(request_id, subscription_id)
);
CREATE INDEX daily_feedback_deliveries_due ON daily_feedback_deliveries(tenant_id, delivered_at, failed_at, next_attempt_at);
