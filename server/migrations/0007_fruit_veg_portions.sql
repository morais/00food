ALTER TABLE foods ADD COLUMN fruit_veg_portions INTEGER NOT NULL DEFAULT 0
  CHECK (fruit_veg_portions BETWEEN 0 AND 5);
ALTER TABLE food_logs ADD COLUMN fruit_veg_portions INTEGER NOT NULL DEFAULT 0
  CHECK (fruit_veg_portions BETWEEN 0 AND 5);
ALTER TABLE pending_estimations ADD COLUMN proposed_fruit_veg_portions INTEGER
  CHECK (proposed_fruit_veg_portions BETWEEN 0 AND 5);
