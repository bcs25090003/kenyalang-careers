USE kenyalang_careers;

CREATE TABLE IF NOT EXISTS interview_read_cursors (
  user_id BIGINT UNSIGNED NOT NULL,
  interview_id BIGINT UNSIGNED NOT NULL,
  last_read_message_id BIGINT UNSIGNED NOT NULL DEFAULT 0,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (user_id, interview_id),
  CONSTRAINT fk_irc_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
  CONSTRAINT fk_irc_interview FOREIGN KEY (interview_id) REFERENCES interviews(id) ON DELETE CASCADE
);
