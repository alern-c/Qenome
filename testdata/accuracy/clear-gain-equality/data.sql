WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 50000)
INSERT INTO events(id, customer_id, status, created_at, note, name)
SELECT i, (i % 2000) + 1, CASE WHEN i % 2 = 0 THEN 'ok' ELSE 'failed' END, i,
  'note-' || i, 'name-' || i
FROM n;
ANALYZE;
