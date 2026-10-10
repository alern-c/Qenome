-- 改善する例: customer_id の等値条件。列をそのまま比較するため、customer_id の索引を使える。
-- 代表バインド: 型 INTEGER、値 1234（?1 へ束縛する）
SELECT id, status, note FROM events WHERE customer_id = ?;
