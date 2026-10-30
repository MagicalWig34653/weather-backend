CREATE TABLE radar_run (
  run_id CHAR(14) NOT NULL,
  nominal_time DATETIME NOT NULL,
  status ENUM('claimed','published','failed') NOT NULL,
  claimed_by VARCHAR(64) NULL,
  lease_until DATETIME NOT NULL,
  attempts SMALLINT UNSIGNED NOT NULL DEFAULT 1,
  created_at DATETIME NOT NULL DEFAULT UTC_TIMESTAMP(),
  published_at DATETIME NULL,
  PRIMARY KEY (run_id),
  KEY idx_radar_run_status_time (status, nominal_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE radar_slot (
  run_id CHAR(14) NOT NULL,
  slot_id CHAR(14) NOT NULL,
  slot_index TINYINT UNSIGNED NOT NULL,
  slot_time DATETIME NOT NULL,
  content_type VARCHAR(32) NOT NULL,
  sha256 CHAR(64) NOT NULL,
  size INT UNSIGNED NOT NULL,
  bytes MEDIUMBLOB NOT NULL,
  PRIMARY KEY (run_id, slot_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
