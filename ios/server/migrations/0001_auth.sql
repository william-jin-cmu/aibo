-- Accounts, sessions and email sign-in codes. Each user owns one cloud agent
-- (a Companion Durable Object addressed by agent_id).
CREATE TABLE users (
  id TEXT PRIMARY KEY,
  agent_id TEXT NOT NULL UNIQUE,
  email TEXT UNIQUE,
  apple_sub TEXT UNIQUE,
  name TEXT,
  created_at INTEGER NOT NULL
);

CREATE TABLE sessions (
  token_hash TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL,
  last_seen_at INTEGER NOT NULL
);
CREATE INDEX sessions_user ON sessions(user_id);

CREATE TABLE email_codes (
  email TEXT PRIMARY KEY,
  code_hash TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  sent_at INTEGER NOT NULL
);
