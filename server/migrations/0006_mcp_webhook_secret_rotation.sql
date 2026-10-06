ALTER TABLE mcp_event_subscriptions ADD COLUMN previous_secret TEXT;
ALTER TABLE mcp_event_subscriptions ADD COLUMN previous_secret_expires_at TEXT;
