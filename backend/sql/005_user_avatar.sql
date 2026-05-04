-- users.avatar_base64. Safe to run multiple times.

USE kenyalang_careers;

DROP PROCEDURE IF EXISTS kenyalang_patch_005_avatar;
DELIMITER $$
CREATE PROCEDURE kenyalang_patch_005_avatar()
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'users' AND COLUMN_NAME = 'avatar_base64'
  ) THEN
    ALTER TABLE users ADD COLUMN avatar_base64 LONGTEXT NULL;
  END IF;
END$$
DELIMITER ;

CALL kenyalang_patch_005_avatar();
DROP PROCEDURE IF EXISTS kenyalang_patch_005_avatar;
