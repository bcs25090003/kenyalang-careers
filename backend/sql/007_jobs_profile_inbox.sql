-- Jobs image + requirements, user about + ID doc, applications REJECTED + extras, formal inbox.
-- Idempotent: safe to run on every deploy; does not delete or rewrite existing business data except
-- mapping applications.status PASSED -> REJECTED when shrinking the enum (same as original 007 intent).

USE kenyalang_careers;

DROP PROCEDURE IF EXISTS kenyalang_migrate_007_jobs_profile_inbox;
DELIMITER $$
CREATE PROCEDURE kenyalang_migrate_007_jobs_profile_inbox()
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'jobs' AND COLUMN_NAME = 'image_base64'
  ) THEN
    ALTER TABLE jobs ADD COLUMN image_base64 LONGTEXT NULL;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'jobs' AND COLUMN_NAME = 'application_requirements'
  ) THEN
    ALTER TABLE jobs ADD COLUMN application_requirements TEXT NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'users' AND COLUMN_NAME = 'about_text'
  ) THEN
    ALTER TABLE users ADD COLUMN about_text TEXT NULL;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'users' AND COLUMN_NAME = 'id_doc_base64'
  ) THEN
    ALTER TABLE users ADD COLUMN id_doc_base64 LONGTEXT NULL;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'users' AND COLUMN_NAME = 'id_doc_filename'
  ) THEN
    ALTER TABLE users ADD COLUMN id_doc_filename VARCHAR(255) NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'applications' AND COLUMN_NAME = 'rejection_reason'
  ) THEN
    ALTER TABLE applications ADD COLUMN rejection_reason TEXT NULL;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'applications' AND COLUMN_NAME = 'applicant_extras_json'
  ) THEN
    ALTER TABLE applications ADD COLUMN applicant_extras_json LONGTEXT NULL;
  END IF;

  SET @app_status_type := (
    SELECT COLUMN_TYPE FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'applications' AND COLUMN_NAME = 'status'
    LIMIT 1
  );

  IF @app_status_type IS NOT NULL AND @app_status_type NOT LIKE '%REJECTED%' THEN
    ALTER TABLE applications
      MODIFY COLUMN status ENUM('NEW','INTERVIEW','HIRED','PASSED','REJECTED') NOT NULL DEFAULT 'NEW';
    UPDATE applications SET status = 'REJECTED' WHERE status = 'PASSED';
    ALTER TABLE applications
      MODIFY COLUMN status ENUM('NEW','INTERVIEW','HIRED','REJECTED') NOT NULL DEFAULT 'NEW';
  ELSEIF @app_status_type LIKE '%REJECTED%' AND @app_status_type LIKE '%PASSED%' THEN
    UPDATE applications SET status = 'REJECTED' WHERE status = 'PASSED';
    ALTER TABLE applications
      MODIFY COLUMN status ENUM('NEW','INTERVIEW','HIRED','REJECTED') NOT NULL DEFAULT 'NEW';
  END IF;
END$$
DELIMITER ;

CALL kenyalang_migrate_007_jobs_profile_inbox();
DROP PROCEDURE IF EXISTS kenyalang_migrate_007_jobs_profile_inbox;

CREATE TABLE IF NOT EXISTS formal_inbox (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  recipient_user_id BIGINT UNSIGNED NOT NULL,
  sender_user_id BIGINT UNSIGNED NOT NULL,
  job_id BIGINT UNSIGNED NULL,
  application_id BIGINT UNSIGNED NULL,
  kind ENUM('hire_congrats','formal_message','rejection_summary') NOT NULL DEFAULT 'formal_message',
  title VARCHAR(255) NOT NULL,
  body TEXT NOT NULL,
  is_read TINYINT(1) NOT NULL DEFAULT 0,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_formal_inbox_recipient (recipient_user_id, is_read),
  CONSTRAINT fk_finbox_recipient FOREIGN KEY (recipient_user_id) REFERENCES users(id),
  CONSTRAINT fk_finbox_sender FOREIGN KEY (sender_user_id) REFERENCES users(id),
  CONSTRAINT fk_finbox_job FOREIGN KEY (job_id) REFERENCES jobs(id) ON DELETE SET NULL,
  CONSTRAINT fk_finbox_app FOREIGN KEY (application_id) REFERENCES applications(id) ON DELETE SET NULL
);
