-- 効果のない例: status を lower() で包むため、status の索引を条件に使えない。
-- 代表バインド: 型 TEXT、値 'ok'（?1 へ束縛する）
SELECT note FROM events WHERE lower(status) = ?;
