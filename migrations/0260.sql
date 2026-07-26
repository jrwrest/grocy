-- Multi-household, phase 6: abuse protection for self-registration.
--
-- /register is a public, unauthenticated, write endpoint. Without a limit it can
-- be hammered to fill the disk with households, which is the real risk on a box
-- with finite storage (this one has ~13 GB free and also runs other services).
--
-- Deliberately no third-party CAPTCHA: that means an account, a key, and an
-- external dependency on the critical path of signup. Per-IP rate limiting, a
-- honeypot field, a minimum submit time and a hard household cap cost nothing
-- and need no external service.

CREATE TABLE registration_attempts (
	id INTEGER PRIMARY KEY,
	ip_address TEXT NOT NULL,
	successful TINYINT NOT NULL DEFAULT 0,
	row_created_timestamp DATETIME DEFAULT (datetime('now', 'localtime'))
);

CREATE INDEX registration_attempts_ip_time ON registration_attempts (ip_address, row_created_timestamp);
CREATE INDEX registration_attempts_time ON registration_attempts (row_created_timestamp);
