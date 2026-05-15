ALTER TABLE devices
    ADD COLUMN expires_at timestamp without time zone,
    ADD COLUMN grace_period_expires_at timestamp without time zone;
