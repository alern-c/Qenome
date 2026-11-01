CREATE TABLE events (
  id INTEGER PRIMARY KEY,
  customer_id INTEGER NOT NULL,
  note TEXT NOT NULL
);
CREATE INDEX idx_events_customer ON events(customer_id);
WITH RECURSIVE c(x) AS (
  SELECT 1
  UNION ALL
  SELECT x + 1 FROM c WHERE x < 200
)
INSERT INTO events (customer_id, note)
SELECT x, 'n' FROM c;
ANALYZE;
