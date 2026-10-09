-- Retain the legacy column for installed builds; percentage is authoritative.
ALTER TABLE profiles ADD COLUMN deficit_percent INTEGER NOT NULL DEFAULT 10
  CHECK (deficit_percent IN (0, 10, 15, 20));
UPDATE profiles SET deficit_percent = CASE
  WHEN deficit_kcal = 0 THEN 0
  WHEN deficit_kcal < 375 THEN 10
  WHEN deficit_kcal < 525 THEN 15
  ELSE 20 END;
