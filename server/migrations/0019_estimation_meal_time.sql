-- Keep the meal time separate from upload, proposal and acceptance times.
-- Older pending requests can supply their original time when accepted.
ALTER TABLE pending_estimations ADD COLUMN logged_at TEXT;
