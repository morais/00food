-- The sweep deletes revoked credentials; without this it scans the table.
CREATE INDEX credentials_revoked ON credentials(revoked_at) WHERE revoked_at IS NOT NULL;
