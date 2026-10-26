CREATE TABLE events (
  id INTEGER PRIMARY KEY,
  customer_id INTEGER NOT NULL,
  status TEXT NOT NULL
);
INSERT INTO events (customer_id, status) VALUES
  (1, 'ok'),
  (1, 'ok'),
  (2, 'no'),
  (3, 'ok'),
  (4, 'ok');
