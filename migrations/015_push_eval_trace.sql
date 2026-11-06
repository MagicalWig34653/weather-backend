-- Last evaluation result per Live Activity subscription (diagnosis only): the run in which the reason last changed, the reason as a
-- fixed word and the class of slot 0 (-1 = unknown pixel). Written by the push leader only when the value changes.
ALTER TABLE push_sub ADD COLUMN IF NOT EXISTS eval_run VARCHAR(16) NULL, ADD COLUMN IF NOT EXISTS eval_reason VARCHAR(24) NULL, ADD COLUMN IF NOT EXISTS eval_class TINYINT NULL;

-- Time of the last change of a subscription by its owner (diagnosis: creation is `created_at`).
ALTER TABLE push_sub ADD COLUMN IF NOT EXISTS changed_at DATETIME NULL;
