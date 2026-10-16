-- Keep existing reviews and webhook deliveries while allowing separate
-- completed-day and midday requests for the same local date.
PRAGMA defer_foreign_keys = ON;
DROP TRIGGER daily_feedback_food_added;
CREATE TABLE daily_feedback_requests_next (
  id TEXT PRIMARY KEY,
  tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  local_date TEXT NOT NULL,
  time_zone TEXT NOT NULL,
  health_json TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('pending', 'ready')),
  feedback_text TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  needs_refresh INTEGER NOT NULL DEFAULT 0,
  display_units TEXT NOT NULL DEFAULT 'metric' CHECK (display_units IN ('metric','us','uk')),
  user_instructions TEXT NOT NULL DEFAULT '' CHECK (length(user_instructions) <= 2000),
  review_kind TEXT NOT NULL DEFAULT 'daily' CHECK (review_kind IN ('daily','midday')),
  captured_at TEXT,
  resting_estimate_kcal INTEGER,
  context_json TEXT,
  UNIQUE(tenant_id, local_date, review_kind)
);
INSERT INTO daily_feedback_requests_next
  (id, tenant_id, local_date, time_zone, health_json, state, feedback_text, created_at,
   updated_at, needs_refresh, display_units, user_instructions)
SELECT id, tenant_id, local_date, time_zone, health_json, state, feedback_text, created_at,
       updated_at, needs_refresh, display_units, user_instructions FROM daily_feedback_requests;
-- DROP cascades child rows, so preserve and restore every delivery, including
-- retry status and signing subscription associations, in this migration.
CREATE TABLE daily_feedback_deliveries_preserved AS SELECT * FROM daily_feedback_deliveries;
DROP TABLE daily_feedback_requests;
ALTER TABLE daily_feedback_requests_next RENAME TO daily_feedback_requests;
INSERT INTO daily_feedback_deliveries SELECT * FROM daily_feedback_deliveries_preserved;
DROP TABLE daily_feedback_deliveries_preserved;
CREATE INDEX daily_feedback_recent ON daily_feedback_requests(tenant_id, local_date DESC);
CREATE INDEX daily_feedback_pending ON daily_feedback_requests(tenant_id, state, created_at);
CREATE TRIGGER daily_feedback_requests_versioned_insert AFTER INSERT ON daily_feedback_requests BEGIN
  UPDATE tenants SET data_version = data_version + 1 WHERE id = NEW.tenant_id;
END;

CREATE TRIGGER daily_feedback_requests_versioned_update AFTER UPDATE ON daily_feedback_requests BEGIN
  UPDATE tenants SET data_version = data_version + 1 WHERE id = NEW.tenant_id;
END;

CREATE TRIGGER daily_feedback_requests_versioned_delete AFTER DELETE ON daily_feedback_requests BEGIN
  UPDATE tenants SET data_version = data_version + 1 WHERE id = OLD.tenant_id;
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

CREATE TRIGGER daily_feedback_food_added AFTER INSERT ON food_logs BEGIN
  UPDATE daily_feedback_requests SET needs_refresh = 1
  WHERE tenant_id = NEW.tenant_id AND local_date = NEW.local_date AND review_kind = 'daily';
END;
PRAGMA defer_foreign_keys = OFF;
