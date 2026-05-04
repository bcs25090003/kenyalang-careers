-- Idempotent: add jobs.pay_basis (how salary_text should be interpreted).

USE kenyalang_careers;

DROP PROCEDURE IF EXISTS kenyalang_patch_008_pay_basis;
DELIMITER $$
CREATE PROCEDURE kenyalang_patch_008_pay_basis()
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'jobs' AND COLUMN_NAME = 'pay_basis'
  ) THEN
    ALTER TABLE jobs
      ADD COLUMN pay_basis ENUM('HOURLY','DAILY','MONTHLY','OTHER','UNSPECIFIED') NOT NULL DEFAULT 'UNSPECIFIED'
      AFTER employment_type;
  END IF;
END$$
DELIMITER ;

CALL kenyalang_patch_008_pay_basis();
DROP PROCEDURE IF EXISTS kenyalang_patch_008_pay_basis;
