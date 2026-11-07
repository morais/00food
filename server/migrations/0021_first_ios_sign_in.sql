-- Record future native app sign-ins only. Historical backfill is deferred;
-- NULL means no recorded observation, not proof that iOS was never used.
ALTER TABLE tenants ADD COLUMN first_ios_sign_in_at TEXT;
