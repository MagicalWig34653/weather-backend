-- Known DWD municipality warning cell ids (seeded once from the official list with tools/seed_warncells.sh; never filled by clients).
-- The server rejects unknown ids (409 warncell_unknown) only once the list is complete enough (see WarnCellCatalog.minimumSeed).
CREATE TABLE IF NOT EXISTS warn_cell_known (
  warncell_id CHAR(9) NOT NULL PRIMARY KEY
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
