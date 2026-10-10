ALTER TABLE daily_feedback_requests ADD COLUMN display_units TEXT NOT NULL DEFAULT 'metric'
  CHECK (display_units IN ('metric', 'us', 'uk'));
