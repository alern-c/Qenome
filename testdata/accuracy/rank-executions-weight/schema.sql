CREATE TABLE events (
  id INTEGER PRIMARY KEY,
  customer_id INTEGER NOT NULL,
  note TEXT NOT NULL
);
INSERT INTO events (customer_id, note) VALUES (1, 'n'), (2, 'n');
ANALYZE;
