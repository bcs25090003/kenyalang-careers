USE kenyalang_careers;

-- INTERVIEWS
CREATE TABLE IF NOT EXISTS interviews (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  job_id BIGINT UNSIGNED NULL,
  employer_user_id BIGINT UNSIGNED NOT NULL,
  seeker_user_id BIGINT UNSIGNED NOT NULL,
  platform VARCHAR(64) NOT NULL,
  datetime_text VARCHAR(128) NOT NULL,
  proposed_datetime_text VARCHAR(128) NULL,
  link_text TEXT NULL,
  status VARCHAR(64) NOT NULL DEFAULT 'Pending Seeker',
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_interviews_employer (employer_user_id),
  KEY idx_interviews_seeker (seeker_user_id),
  KEY idx_interviews_job (job_id),
  CONSTRAINT fk_interviews_job FOREIGN KEY (job_id) REFERENCES jobs(id),
  CONSTRAINT fk_interviews_employer FOREIGN KEY (employer_user_id) REFERENCES users(id),
  CONSTRAINT fk_interviews_seeker FOREIGN KEY (seeker_user_id) REFERENCES users(id)
);

-- INTERVIEW MESSAGES (CHAT)
CREATE TABLE IF NOT EXISTS interview_messages (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  interview_id BIGINT UNSIGNED NOT NULL,
  sender_user_id BIGINT UNSIGNED NOT NULL,
  message_text TEXT NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_msgs_interview (interview_id),
  CONSTRAINT fk_msgs_interview FOREIGN KEY (interview_id) REFERENCES interviews(id) ON DELETE CASCADE,
  CONSTRAINT fk_msgs_sender FOREIGN KEY (sender_user_id) REFERENCES users(id)
);

