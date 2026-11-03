CREATE TABLE IF NOT EXISTS dashboard_credential (
  id TINYINT UNSIGNED NOT NULL,
  credential_id VARBINARY(1024) NOT NULL,
  public_key BLOB NOT NULL,
  sign_count INT UNSIGNED NOT NULL DEFAULT 0,
  created_at DATETIME NOT NULL,
  last_used_at DATETIME NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_dashboard_credential_id (credential_id),
  CONSTRAINT chk_dashboard_credential_single CHECK (id = 1)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS dashboard_challenge (
  id BINARY(16) NOT NULL,
  kind ENUM('setup','login') NOT NULL,
  challenge VARBINARY(64) NOT NULL,
  expires_at DATETIME NOT NULL,
  PRIMARY KEY (id),
  KEY idx_dashboard_challenge_expires (expires_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS dashboard_session (
  id_hash BINARY(32) NOT NULL,
  csrf_hash BINARY(32) NOT NULL,
  created_at DATETIME NOT NULL,
  last_seen_at DATETIME NOT NULL,
  expires_at DATETIME NOT NULL,
  PRIMARY KEY (id_hash),
  KEY idx_dashboard_session_expires (expires_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS stats_daily (
  day DATE NOT NULL,
  metric VARCHAR(32) NOT NULL,
  label VARCHAR(48) NOT NULL DEFAULT '',
  value BIGINT UNSIGNED NOT NULL DEFAULT 0,
  PRIMARY KEY (day, metric, label)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS config_override (
  config_key VARCHAR(64) NOT NULL,
  value VARCHAR(600) NOT NULL,
  updated_at DATETIME NOT NULL,
  revision BIGINT NOT NULL,
  PRIMARY KEY (config_key)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS config_generation (
  id TINYINT UNSIGNED NOT NULL,
  generation BIGINT NOT NULL DEFAULT 0,
  config_revision BIGINT NOT NULL DEFAULT 0,
  requested_at DATETIME NULL,
  PRIMARY KEY (id),
  CONSTRAINT chk_config_generation_single CHECK (id = 1)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

INSERT IGNORE INTO config_generation (id, generation, config_revision) VALUES (1, 0, 0);

CREATE TABLE IF NOT EXISTS config_replica (
  replica_id VARCHAR(64) NOT NULL,
  slot INT NULL,
  applied_generation BIGINT NOT NULL,
  started_at DATETIME NOT NULL,
  last_seen_at DATETIME NOT NULL,
  PRIMARY KEY (replica_id),
  KEY idx_config_replica_seen (last_seen_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS config_audit (
  id BIGINT NOT NULL AUTO_INCREMENT,
  at DATETIME NOT NULL,
  action ENUM('set','reset','restart','login','setup','reset_cli') NOT NULL,
  config_key VARCHAR(64) NULL,
  old_value VARCHAR(200) NULL,
  new_value VARCHAR(200) NULL,
  PRIMARY KEY (id),
  KEY idx_config_audit_at (at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
