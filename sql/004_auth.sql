-- Auth + profile extensions. Safe to run multiple times (adds missing columns/indexes/tables only).

USE kenyalang_careers;

DROP PROCEDURE IF EXISTS kenyalang_patch_004_auth;
DELIMITER $$
CREATE PROCEDURE kenyalang_patch_004_auth()
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'users' AND COLUMN_NAME = 'password_hash'
  ) THEN
    ALTER TABLE users ADD COLUMN password_hash VARCHAR(255) NULL;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'users' AND COLUMN_NAME = 'phone'
  ) THEN
    ALTER TABLE users ADD COLUMN phone VARCHAR(64) NULL;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'users' AND COLUMN_NAME = 'gov_id'
  ) THEN
    ALTER TABLE users ADD COLUMN gov_id VARCHAR(64) NULL;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'users' AND COLUMN_NAME = 'address'
  ) THEN
    ALTER TABLE users ADD COLUMN address VARCHAR(255) NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'seeker_profiles' AND COLUMN_NAME = 'ic_doc_filename'
  ) THEN
    ALTER TABLE seeker_profiles ADD COLUMN ic_doc_filename VARCHAR(255) NULL;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'seeker_profiles' AND COLUMN_NAME = 'ic_doc_base64'
  ) THEN
    ALTER TABLE seeker_profiles ADD COLUMN ic_doc_base64 LONGTEXT NULL;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'seeker_profiles' AND COLUMN_NAME = 'transcript_doc_filename'
  ) THEN
    ALTER TABLE seeker_profiles ADD COLUMN transcript_doc_filename VARCHAR(255) NULL;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'seeker_profiles' AND COLUMN_NAME = 'transcript_doc_base64'
  ) THEN
    ALTER TABLE seeker_profiles ADD COLUMN transcript_doc_base64 LONGTEXT NULL;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'seeker_profiles' AND COLUMN_NAME = 'profile_avatar_base64'
  ) THEN
    ALTER TABLE seeker_profiles ADD COLUMN profile_avatar_base64 LONGTEXT NULL;
  END IF;
END$$
DELIMITER ;

CALL kenyalang_patch_004_auth();
DROP PROCEDURE IF EXISTS kenyalang_patch_004_auth;

CREATE TABLE IF NOT EXISTS password_resets (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id BIGINT UNSIGNED NOT NULL,
  token VARCHAR(96) NOT NULL,
  expires_at TIMESTAMP NOT NULL,
  PRIMARY KEY (id),
  KEY idx_pwreset_user (user_id),
  CONSTRAINT fk_pwreset_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

DROP PROCEDURE IF EXISTS kenyalang_patch_004_indexes;
DELIMITER $$
CREATE PROCEDURE kenyalang_patch_004_indexes()
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'users' AND INDEX_NAME = 'uq_users_gov_id'
  ) THEN
    CREATE UNIQUE INDEX uq_users_gov_id ON users (gov_id);
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'users' AND INDEX_NAME = 'uq_users_phone'
  ) THEN
    CREATE UNIQUE INDEX uq_users_phone ON users (phone);
  END IF;
END$$
DELIMITER ;

CALL kenyalang_patch_004_indexes();
DROP PROCEDURE IF EXISTS kenyalang_patch_004_indexes;
