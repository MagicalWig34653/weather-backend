-- Push state reported by every radar replica with its heartbeat (fixed labels only, no secrets or identifiers).
-- NULL = the replica reported nothing (older version). push_env: 'production' | 'sandbox' | 'both'.
ALTER TABLE config_replica ADD COLUMN push_on TINYINT NULL, ADD COLUMN push_env VARCHAR(12) NULL, ADD COLUMN push_la TINYINT NULL;
