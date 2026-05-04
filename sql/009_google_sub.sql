-- Idempotent: users.google_sub + unique index for Google Sign-In.
USE kenyalang_careers;

DROP PROCEDURE IF EXISTS kenyalang_patch_009_google_sub;
DELIMITER $$
CREATE PROCEDURE kenyalang_patch_009_google_sub()
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'users' AND COLUMN_NAME = 'google_sub'
  ) THEN
    ALTER TABLE users ADD COLUMN google_sub VARCHAR(255) NULL;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'users' AND INDEX_NAME = 'uq_users_google_sub'
  ) THEN
    CREATE UNIQUE INDEX uq_users_google_sub ON users (google_sub);
  END IF;
END$$
DELIMITER ;

CALL kenyalang_patch_009_google_sub();
DROP PROCEDURE IF EXISTS kenyalang_patch_009_google_sub;
