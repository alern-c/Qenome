-- 20万行を決定論的に投入する。random() は使わず、同じ手順で同じDBを作る。
-- 主キーを明示するため、再実行すると重複で失敗する。投入前にDBを作り直すこと
-- （手順は testdata/README.md の「再生成手順」）。
INSERT INTO events(id, customer_id, status, note)
SELECT x,
       CASE WHEN x%997 = 0 THEN NULL ELSE (x%2000)+1 END,
       CASE x%3 WHEN 0 THEN 'ok' WHEN 1 THEN 'warn' ELSE 'failed' END,
       CASE WHEN x%5 = 0 THEN NULL ELSE 'note-'||x END
FROM (WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<200000) SELECT x FROM n);
