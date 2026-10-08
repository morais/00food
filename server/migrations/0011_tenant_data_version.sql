-- A per-account version that changes whenever anything in /v1/snapshot
-- changes, so the app can revalidate with If-None-Match and get a 304
-- instead of re-reading every food and log. The counting triggers from 0010
-- are replaced so a single UPDATE of the tenant row does both jobs.
ALTER TABLE tenants ADD COLUMN data_version INTEGER NOT NULL DEFAULT 0;

DROP TRIGGER foods_counted_insert;
CREATE TRIGGER foods_counted_insert AFTER INSERT ON foods BEGIN
  UPDATE tenants SET food_count = food_count + 1, data_version = data_version + 1 WHERE id = NEW.tenant_id;
END;
DROP TRIGGER foods_counted_delete;
CREATE TRIGGER foods_counted_delete AFTER DELETE ON foods BEGIN
  UPDATE tenants SET food_count = food_count - 1, data_version = data_version + 1 WHERE id = OLD.tenant_id;
END;
CREATE TRIGGER foods_versioned_update AFTER UPDATE ON foods BEGIN
  UPDATE tenants SET data_version = data_version + 1 WHERE id = NEW.tenant_id;
END;

DROP TRIGGER food_logs_counted_insert;
CREATE TRIGGER food_logs_counted_insert AFTER INSERT ON food_logs BEGIN
  UPDATE tenants SET log_count = log_count + 1, data_version = data_version + 1 WHERE id = NEW.tenant_id;
END;
DROP TRIGGER food_logs_counted_delete;
CREATE TRIGGER food_logs_counted_delete AFTER DELETE ON food_logs BEGIN
  UPDATE tenants SET log_count = log_count - 1, data_version = data_version + 1 WHERE id = OLD.tenant_id;
END;
CREATE TRIGGER food_logs_versioned_update AFTER UPDATE ON food_logs BEGIN
  UPDATE tenants SET data_version = data_version + 1 WHERE id = NEW.tenant_id;
END;

DROP TRIGGER pending_estimations_counted_insert;
CREATE TRIGGER pending_estimations_counted_insert AFTER INSERT ON pending_estimations BEGIN
  UPDATE tenants SET estimate_count = estimate_count + 1, data_version = data_version + 1 WHERE id = NEW.tenant_id;
END;
DROP TRIGGER pending_estimations_counted_delete;
CREATE TRIGGER pending_estimations_counted_delete AFTER DELETE ON pending_estimations BEGIN
  UPDATE tenants SET estimate_count = estimate_count - 1, data_version = data_version + 1 WHERE id = OLD.tenant_id;
END;
CREATE TRIGGER pending_estimations_versioned_update AFTER UPDATE ON pending_estimations BEGIN
  UPDATE tenants SET data_version = data_version + 1 WHERE id = NEW.tenant_id;
END;

CREATE TRIGGER profiles_versioned_insert AFTER INSERT ON profiles BEGIN
  UPDATE tenants SET data_version = data_version + 1 WHERE id = NEW.tenant_id;
END;

CREATE TRIGGER profiles_versioned_update AFTER UPDATE ON profiles BEGIN
  UPDATE tenants SET data_version = data_version + 1 WHERE id = NEW.tenant_id;
END;

CREATE TRIGGER profiles_versioned_delete AFTER DELETE ON profiles BEGIN
  UPDATE tenants SET data_version = data_version + 1 WHERE id = OLD.tenant_id;
END;

CREATE TRIGGER daily_feedback_requests_versioned_insert AFTER INSERT ON daily_feedback_requests BEGIN
  UPDATE tenants SET data_version = data_version + 1 WHERE id = NEW.tenant_id;
END;

CREATE TRIGGER daily_feedback_requests_versioned_update AFTER UPDATE ON daily_feedback_requests BEGIN
  UPDATE tenants SET data_version = data_version + 1 WHERE id = NEW.tenant_id;
END;

CREATE TRIGGER daily_feedback_requests_versioned_delete AFTER DELETE ON daily_feedback_requests BEGIN
  UPDATE tenants SET data_version = data_version + 1 WHERE id = OLD.tenant_id;
END;
