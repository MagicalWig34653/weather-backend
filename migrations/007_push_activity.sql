ALTER TABLE push_install
  ADD COLUMN IF NOT EXISTS la_start_token VARCHAR(200) NULL;

ALTER TABLE push_sub
  ADD COLUMN IF NOT EXISTS live_activity TINYINT(1) NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS push_activity (
  subscription_id CHAR(36) NOT NULL,
  activity_token VARCHAR(200) NULL,
  started_at DATETIME NOT NULL,
  ends_at DATETIME NOT NULL,
  PRIMARY KEY (subscription_id),
  KEY idx_push_activity_ends (ends_at),
  CONSTRAINT fk_push_activity_sub FOREIGN KEY (subscription_id) REFERENCES push_sub (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
