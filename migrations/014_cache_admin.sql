-- Operator cache tools: manual ingest jobs (leader-executed, like dashboard_command) and the in-process cache fill level per replica.
CREATE TABLE IF NOT EXISTS dashboard_refresh (
  id CHAR(36) NOT NULL,
  layer VARCHAR(16) NOT NULL,
  status VARCHAR(8) NOT NULL,
  created_at DATETIME NOT NULL,
  started_at DATETIME NULL,
  finished_at DATETIME NULL,
  result VARCHAR(120) NULL,
  error VARCHAR(32) NULL,
  PRIMARY KEY (id),
  KEY idx_dashboard_refresh_status (status, created_at),
  KEY idx_dashboard_refresh_layer (layer, status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

ALTER TABLE config_replica ADD COLUMN IF NOT EXISTS cache_bytes BIGINT NULL, ADD COLUMN IF NOT EXISTS cache_entries INT NULL, ADD COLUMN IF NOT EXISTS cache_max BIGINT NULL;

ALTER TABLE config_audit MODIFY action ENUM('set','reset','restart','login','setup','reset_cli','device_pair','device_unpair','device_action','push_pause','cache_clear','cache_refresh','device_pairing_open','device_pairing_close') NOT NULL;

-- Slot listing and preview look up slots by time.
ALTER TABLE layer_slot ADD INDEX IF NOT EXISTS idx_layer_slot_time (layer, slot_time);
ALTER TABLE radar_slot ADD INDEX IF NOT EXISTS idx_radar_slot_time (slot_time);
