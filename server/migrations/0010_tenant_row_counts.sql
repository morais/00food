-- Per-account row counts for the library, log, and review-queue limits, kept
-- by triggers so every insert and delete path (including accept and account
-- deletion) stays in step without counting the tenant's rows on each create.
ALTER TABLE tenants ADD COLUMN food_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE tenants ADD COLUMN log_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE tenants ADD COLUMN estimate_count INTEGER NOT NULL DEFAULT 0;

UPDATE tenants SET
  food_count = (SELECT COUNT(*) FROM foods WHERE foods.tenant_id = tenants.id),
  log_count = (SELECT COUNT(*) FROM food_logs WHERE food_logs.tenant_id = tenants.id),
  estimate_count = (SELECT COUNT(*) FROM pending_estimations WHERE pending_estimations.tenant_id = tenants.id);

CREATE TRIGGER foods_counted_insert AFTER INSERT ON foods BEGIN
  UPDATE tenants SET food_count = food_count + 1 WHERE id = NEW.tenant_id;
END;
CREATE TRIGGER foods_counted_delete AFTER DELETE ON foods BEGIN
  UPDATE tenants SET food_count = food_count - 1 WHERE id = OLD.tenant_id;
END;
CREATE TRIGGER food_logs_counted_insert AFTER INSERT ON food_logs BEGIN
  UPDATE tenants SET log_count = log_count + 1 WHERE id = NEW.tenant_id;
END;
CREATE TRIGGER food_logs_counted_delete AFTER DELETE ON food_logs BEGIN
  UPDATE tenants SET log_count = log_count - 1 WHERE id = OLD.tenant_id;
END;
CREATE TRIGGER pending_estimations_counted_insert AFTER INSERT ON pending_estimations BEGIN
  UPDATE tenants SET estimate_count = estimate_count + 1 WHERE id = NEW.tenant_id;
END;
CREATE TRIGGER pending_estimations_counted_delete AFTER DELETE ON pending_estimations BEGIN
  UPDATE tenants SET estimate_count = estimate_count - 1 WHERE id = OLD.tenant_id;
END;
