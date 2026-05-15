ALTER TABLE devices
    DROP COLUMN IF EXISTS expires_at,
    DROP COLUMN IF EXISTS grace_period_expires_at;
