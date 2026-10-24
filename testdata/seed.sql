INSERT INTO events(id, customer_id, status, note)
SELECT x,
       CASE WHEN x%997 = 0 THEN NULL ELSE (x%2000)+1 END,
       CASE x%3 WHEN 0 THEN 'ok' WHEN 1 THEN 'warn' ELSE 'failed' END,
       CASE WHEN x%5 = 0 THEN NULL ELSE 'note-'||x END
FROM (WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<200000) SELECT x FROM n);
