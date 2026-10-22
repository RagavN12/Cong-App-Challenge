CREATE TABLE IF NOT EXISTS friend_profiles (
  user_id TEXT PRIMARY KEY,
  display_name TEXT NOT NULL CHECK (length(display_name) BETWEEN 1 AND 50),
  invite_code TEXT NOT NULL UNIQUE CHECK (length(invite_code) = 12),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS friend_requests (
  id TEXT PRIMARY KEY,
  requester_id TEXT NOT NULL REFERENCES friend_profiles(user_id) ON DELETE CASCADE,
  recipient_id TEXT NOT NULL REFERENCES friend_profiles(user_id) ON DELETE CASCADE,
  status TEXT NOT NULL CHECK (status IN ('pending', 'accepted')),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CHECK (requester_id <> recipient_id),
  UNIQUE (requester_id, recipient_id)
);

CREATE INDEX IF NOT EXISTS friend_requests_recipient_status
  ON friend_requests(recipient_id, status);

CREATE INDEX IF NOT EXISTS friend_requests_requester_status
  ON friend_requests(requester_id, status);

CREATE TABLE IF NOT EXISTS friend_usage (
  user_id TEXT NOT NULL REFERENCES friend_profiles(user_id) ON DELETE CASCADE,
  week_start TEXT NOT NULL CHECK (length(week_start) = 10),
  watt_hours REAL NOT NULL CHECK (watt_hours >= 0 AND watt_hours <= 1000000),
  tokens INTEGER NOT NULL CHECK (tokens >= 0 AND tokens <= 1000000000),
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (user_id, week_start)
);
