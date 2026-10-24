CREATE TABLE events (
  id          INTEGER PRIMARY KEY,
  customer_id INTEGER,
  status      TEXT NOT NULL,
  note        TEXT
);
