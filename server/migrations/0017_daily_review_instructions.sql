-- Freeze the person's review preferences with each request, including retries.
ALTER TABLE daily_feedback_requests ADD COLUMN user_instructions TEXT NOT NULL DEFAULT ''
  CHECK (length(user_instructions) <= 2000);
