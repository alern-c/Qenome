CREATE TABLE events (
  id INTEGER PRIMARY KEY,
  customer_id INTEGER NOT NULL,
  status TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  note TEXT,
  name TEXT
);
CREATE INDEX idx_lower_name ON events(lower(name));
