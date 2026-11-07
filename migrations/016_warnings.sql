-- Official weather warnings (DWD CAP, municipality union). Only warning cell ids, texts and times: no coordinates, no place names.
-- One row per CAP message and language. alert_key = identifier without the language suffix (.DEU/.ENG), shared by both languages;
-- chain_id = alert_key of the first message of an update chain. status: active | cancelled | superseded.
CREATE TABLE IF NOT EXISTS warn_alert (
  identifier VARCHAR(160) NOT NULL,
  lang CHAR(2) NOT NULL,
  alert_key VARCHAR(160) NOT NULL,
  chain_id VARCHAR(160) NOT NULL,
  kind VARCHAR(16) NOT NULL,
  severity TINYINT NOT NULL,
  event VARCHAR(64) NOT NULL,
  sent DATETIME NOT NULL,
  onset DATETIME NOT NULL,
  expires DATETIME NOT NULL,
  headline VARCHAR(256) NOT NULL,
  body TEXT NOT NULL,
  instruction TEXT NOT NULL,
  status VARCHAR(12) NOT NULL DEFAULT 'active',
  updated_at DATETIME NOT NULL,
  PRIMARY KEY (identifier, lang),
  KEY ix_warn_alert_expires (expires),
  KEY ix_warn_alert_key (alert_key),
  KEY ix_warn_alert_chain (chain_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS warn_alert_cell (
  identifier VARCHAR(160) NOT NULL,
  warncell_id CHAR(9) NOT NULL,
  PRIMARY KEY (identifier, warncell_id),
  KEY ix_warn_cell (warncell_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Warning subscriptions (used from W2): only warning cell ids, no coordinates.
CREATE TABLE IF NOT EXISTS warn_sub (
  sub_id CHAR(36) NOT NULL PRIMARY KEY,
  types_mask TINYINT NOT NULL,
  min_sev_weather TINYINT NOT NULL DEFAULT 3,
  min_sev_frost TINYINT NOT NULL DEFAULT 1,
  min_sev_ice TINYINT NOT NULL DEFAULT 2,
  time_sensitive TINYINT NOT NULL DEFAULT 0,
  CONSTRAINT fk_warn_sub FOREIGN KEY (sub_id) REFERENCES push_sub (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS warn_sub_cell (
  sub_id CHAR(36) NOT NULL,
  warncell_id CHAR(9) NOT NULL,
  PRIMARY KEY (sub_id, warncell_id),
  KEY ix_warn_sub_cell (warncell_id),
  CONSTRAINT fk_warn_sub_cell FOREIGN KEY (sub_id) REFERENCES push_sub (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS warn_sent (
  sub_id CHAR(36) NOT NULL,
  chain_id VARCHAR(160) NOT NULL,
  kind VARCHAR(16) NOT NULL,
  last_severity TINYINT NOT NULL,
  last_onset DATETIME NOT NULL,
  last_sent_at DATETIME NOT NULL,
  PRIMARY KEY (sub_id, chain_id),
  KEY ix_warn_sent_kind (sub_id, kind),
  CONSTRAINT fk_warn_sent FOREIGN KEY (sub_id) REFERENCES push_sub (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS warn_state (
  name VARCHAR(32) NOT NULL PRIMARY KEY,
  value_at DATETIME NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
