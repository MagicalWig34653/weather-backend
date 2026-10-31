CREATE TABLE IF NOT EXISTS layer_run (
  layer VARCHAR(16) NOT NULL,
  run_id CHAR(14) NOT NULL,
  nominal_time DATETIME NOT NULL,
  status ENUM('claimed','published','failed') NOT NULL,
  claimed_by VARCHAR(64) NULL,
  lease_until DATETIME NOT NULL,
  attempts SMALLINT UNSIGNED NOT NULL DEFAULT 1,
  created_at DATETIME NOT NULL DEFAULT UTC_TIMESTAMP(),
  published_at DATETIME NULL,
  PRIMARY KEY (layer, run_id),
  KEY idx_layer_run_status_time (layer, status, nominal_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS layer_slot (
  layer VARCHAR(16) NOT NULL,
  run_id CHAR(14) NOT NULL,
  slot_id CHAR(14) NOT NULL,
  slot_index SMALLINT UNSIGNED NOT NULL,
  slot_time DATETIME NOT NULL,
  content_type VARCHAR(32) NOT NULL,
  sha256 CHAR(64) NOT NULL,
  size INT UNSIGNED NOT NULL,
  bytes MEDIUMBLOB NOT NULL,
  PRIMARY KEY (layer, run_id, slot_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
