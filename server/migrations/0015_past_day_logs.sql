-- Keep the time a log was added separate from the meal date, including offline
-- replay and late entries. This also lets Health export new backdated meals.
ALTER TABLE food_logs ADD COLUMN created_at TEXT;
UPDATE food_logs SET created_at = logged_at;

ALTER TABLE daily_feedback_requests ADD COLUMN needs_refresh INTEGER NOT NULL DEFAULT 0;
CREATE TRIGGER daily_feedback_food_added AFTER INSERT ON food_logs BEGIN
  UPDATE daily_feedback_requests SET needs_refresh = 1
  WHERE tenant_id = NEW.tenant_id AND local_date = NEW.local_date;
END;
