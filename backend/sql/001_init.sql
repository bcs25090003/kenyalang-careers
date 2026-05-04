CREATE DATABASE IF NOT EXISTS kenyalang_careers;
USE kenyalang_careers;

-- USERS (minimal for now; you can later replace with Firebase Auth / your own auth)
CREATE TABLE IF NOT EXISTS users (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  email VARCHAR(255) NULL,
  name VARCHAR(255) NULL,
  role ENUM('SEEKER','EMPLOYER') NOT NULL DEFAULT 'SEEKER',
  google_sub VARCHAR(255) NULL,
  verified_company TINYINT(1) NOT NULL DEFAULT 0,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_users_email (email)
);

-- JOBS
 CREATE TABLE IF NOT EXISTS jobs(
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  employer_user_id BIGINT UNSIGNED NULL,
  title VARCHAR(255) NOT NULL,
  company_name VARCHAR(255) NOT NULL,
  hiring_manager_name VARCHAR(255) NOT NULL,
  location VARCHAR(255) NOT NULL,
  salary_text VARCHAR(255) NOT NULL,
  employment_type ENUM('FULL_TIME','PART_TIME','INTERNSHIP') NOT NULL DEFAULT 'FULL_TIME',
  pay_basis ENUM('HOURLY','DAILY','MONTHLY','OTHER','UNSPECIFIED') NOT NULL DEFAULT 'UNSPECIFIED',
  scope TEXT NOT NULL,
  max_applicants INT NOT NULL DEFAULT 50,
  available_slots INT NOT NULL DEFAULT 10,
  applied_count INT NOT NULL DEFAULT 0,
  hired_count INT NOT NULL DEFAULT 0,
  status ENUM('OPEN','CLOSED','FILLED') NOT NULL DEFAULT 'OPEN',
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_jobs_status (status),
  CONSTRAINT fk_jobs_employer FOREIGN KEY (employer_user_id) REFERENCES users(id)
);

-- SEEKER PROFILE (simplified)
CREATE TABLE IF NOT EXISTS seeker_profiles (
  user_id BIGINT UNSIGNED NOT NULL,
  ic_number VARCHAR(64) NULL,
  age VARCHAR(16) NULL,
  phone VARCHAR(64) NULL,
  address VARCHAR(255) NULL,
  education TEXT NULL,
  experience TEXT NULL,
  skills TEXT NULL,
  personal_word TEXT NULL,
  open_to_work TINYINT(1) NOT NULL DEFAULT 0,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (user_id),
  CONSTRAINT fk_profiles_user FOREIGN KEY (user_id) REFERENCES users(id)
);

-- APPLICATIONS
CREATE TABLE IF NOT EXISTS applications (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  job_id BIGINT UNSIGNED NOT NULL,
  seeker_user_id BIGINT UNSIGNED NOT NULL,
  status ENUM('NEW','INTERVIEW','HIRED','PASSED') NOT NULL DEFAULT 'NEW',
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_app_job_seeker (job_id, seeker_user_id),
  KEY idx_app_job (job_id),
  KEY idx_app_seeker (seeker_user_id),
  CONSTRAINT fk_app_job FOREIGN KEY (job_id) REFERENCES jobs(id),
  CONSTRAINT fk_app_seeker FOREIGN KEY (seeker_user_id) REFERENCES users(id)
);

-- NOTIFICATIONS
CREATE TABLE IF NOT EXISTS notifications (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id BIGINT UNSIGNED NOT NULL,
  type VARCHAR(64) NOT NULL DEFAULT 'info',
  title VARCHAR(255) NOT NULL,
  body TEXT NULL,
  is_read TINYINT(1) NOT NULL DEFAULT 0,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_notif_user_read (user_id, is_read),
  CONSTRAINT fk_notif_user FOREIGN KEY (user_id) REFERENCES users(id)
);

