-- Fixed-vocabulary parameter of an operator command (warn_test: "<type>:<level>", e.g. "frost:1"). NULL for all other kinds.
ALTER TABLE dashboard_command ADD COLUMN IF NOT EXISTS param VARCHAR(16) NULL AFTER dry_run;
