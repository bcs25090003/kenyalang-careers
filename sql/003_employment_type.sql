-- Idempotent: add jobs.employment_type only if missing.
-- Fresh installs already have this column from 001_init.sql; legacy DBs may not.

USE kenyalang_careers;

DROP PROCEDURE IF EXISTS kenyalang_patch_003_employment_type;
DELIMITER $$
CREATE PROCEDURE kenyalang_patch_003_employment_type()
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'jobs' AND COLUMN_NAME = 'employment_type'
  ) THEN
    ALTER TABLE jobs
      ADD COLUMN employment_type ENUM('FULL_TIME','PART_TIME','INTERNSHIP') NOT NULL DEFAULT 'FULL_TIME'
      AFTER salary_text;
  END IF;
END$$
DELIMITER ;

CALL kenyalang_patch_003_employment_type();
DROP PROCEDURE IF EXISTS kenyalang_patch_003_employment_type;
