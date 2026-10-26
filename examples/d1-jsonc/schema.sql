DROP TABLE IF EXISTS events;

CREATE TABLE events (
  id          INTEGER PRIMARY KEY,
  customer_id INTEGER,
  status      TEXT NOT NULL,
  note        TEXT
);

WITH RECURSIVE counter(value) AS (
  SELECT 1
  UNION ALL
  SELECT value + 1 FROM counter WHERE value < 200000
)
INSERT INTO events (id, customer_id, status, note)
SELECT
  value,
  CASE WHEN value % 997 = 0 THEN NULL ELSE (value % 2000) + 1 END,
  CASE value % 3 WHEN 0 THEN 'ok' WHEN 1 THEN 'warn' ELSE 'failed' END,
  CASE WHEN value % 5 = 0 THEN NULL ELSE 'note-' || value END
FROM counter;
