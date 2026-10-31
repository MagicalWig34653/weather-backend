CREATE TABLE IF NOT EXISTS push_install (
  id CHAR(36) NOT NULL,
  secret_hash CHAR(64) NOT NULL,
  token VARCHAR(200) NOT NULL,
  env ENUM('sandbox','production') NOT NULL,
  locale CHAR(2) NOT NULL,
  created_at DATETIME NOT NULL,
  last_seen_at DATETIME NOT NULL,
  token_updated_at DATETIME NOT NULL,
  PRIMARY KEY (id),
  KEY idx_push_install_seen (last_seen_at),
  KEY idx_push_install_token (token, env)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS push_sub (
  id CHAR(36) NOT NULL,
  install_id CHAR(36) NOT NULL,
  grid_version SMALLINT UNSIGNED NOT NULL,
  cell_x SMALLINT UNSIGNED NOT NULL,
  cell_y SMALLINT UNSIGNED NOT NULL,
  threshold TINYINT UNSIGNED NOT NULL,
  lead_min TINYINT UNSIGNED NOT NULL,
  enabled TINYINT(1) NOT NULL DEFAULT 1,
  state TINYINT UNSIGNED NOT NULL DEFAULT 0,
  last_sent_at DATETIME NULL,
  created_at DATETIME NOT NULL,
  PRIMARY KEY (id),
  KEY idx_push_sub_install (install_id),
  KEY idx_push_sub_cell (grid_version, cell_x, cell_y),
  CONSTRAINT fk_push_sub_install FOREIGN KEY (install_id) REFERENCES push_install (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS push_outbox (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  sub_id CHAR(36) NOT NULL,
  dedupe_key VARCHAR(64) NOT NULL,
  collapse_id VARCHAR(64) NOT NULL,
  payload_json VARCHAR(2048) NOT NULL,
  expires_at DATETIME NOT NULL,
  attempts SMALLINT UNSIGNED NOT NULL DEFAULT 0,
  next_attempt_at DATETIME NOT NULL,
  status ENUM('pending','sent','dropped') NOT NULL DEFAULT 'pending',
  created_at DATETIME NOT NULL,
  finished_at DATETIME NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_push_outbox_dedupe (dedupe_key),
  KEY idx_push_outbox_due (status, next_attempt_at),
  KEY idx_push_outbox_sub (sub_id),
  CONSTRAINT fk_push_outbox_sub FOREIGN KEY (sub_id) REFERENCES push_sub (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS push_state (
  name VARCHAR(32) NOT NULL,
  value VARCHAR(64) NOT NULL,
  PRIMARY KEY (name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
