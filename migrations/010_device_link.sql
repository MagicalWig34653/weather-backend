CREATE TABLE IF NOT EXISTS push_link_code (
  code_hash BINARY(32) NOT NULL,
  install_id CHAR(36) NOT NULL,
  attested TINYINT(1) NOT NULL DEFAULT 0,
  created_at DATETIME NOT NULL,
  expires_at DATETIME NOT NULL,
  used_at DATETIME NULL,
  PRIMARY KEY (code_hash),
  KEY idx_push_link_code_install (install_id),
  KEY idx_push_link_code_expires (expires_at),
  CONSTRAINT fk_push_link_code_install FOREIGN KEY (install_id) REFERENCES push_install (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS dashboard_device (
  id CHAR(36) NOT NULL,
  install_id CHAR(36) NOT NULL,
  label VARCHAR(40) NOT NULL,
  paired_at DATETIME NOT NULL,
  expires_at DATETIME NULL,
  last_action_at DATETIME NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_dashboard_device_install (install_id),
  CONSTRAINT fk_dashboard_device_install FOREIGN KEY (install_id) REFERENCES push_install (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS dashboard_device_event (
  id BIGINT NOT NULL AUTO_INCREMENT,
  device_id CHAR(36) NOT NULL,
  at DATETIME NOT NULL,
  kind VARCHAR(16) NOT NULL,
  outcome VARCHAR(16) NOT NULL,
  reason VARCHAR(64) NULL,
  PRIMARY KEY (id),
  KEY idx_dashboard_device_event_device (device_id, id),
  CONSTRAINT fk_dashboard_device_event_device FOREIGN KEY (device_id) REFERENCES dashboard_device (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS dashboard_command (
  id CHAR(36) NOT NULL,
  device_id CHAR(36) NOT NULL,
  kind VARCHAR(16) NOT NULL,
  dry_run TINYINT(1) NULL,
  status VARCHAR(8) NOT NULL,
  created_at DATETIME NOT NULL,
  started_at DATETIME NULL,
  finished_at DATETIME NULL,
  result VARCHAR(2048) NULL,
  error VARCHAR(32) NULL,
  PRIMARY KEY (id),
  KEY idx_dashboard_command_status (status, created_at),
  KEY idx_dashboard_command_device (device_id, created_at),
  CONSTRAINT fk_dashboard_command_device FOREIGN KEY (device_id) REFERENCES dashboard_device (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

ALTER TABLE config_audit MODIFY action ENUM('set','reset','restart','login','setup','reset_cli','device_pair','device_unpair','device_action','push_pause','cache_clear') NOT NULL;

ALTER TABLE config_audit ADD COLUMN IF NOT EXISTS device_ref CHAR(8) NULL;

ALTER TABLE config_audit ADD COLUMN IF NOT EXISTS outcome VARCHAR(32) NULL
