WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 5000)
INSERT INTO customers(id, email, region)
SELECT i, 'user' || i || '@example.test', CASE WHEN i % 3 = 0 THEN 'eu' ELSE 'us' END FROM n;
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 50000)
INSERT INTO orders(id, customer_id, amount)
SELECT i, (i % 5000) + 1, i % 100 FROM n;
ANALYZE;
