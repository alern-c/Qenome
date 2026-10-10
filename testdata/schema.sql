-- Qenome のダミーDB（工程1）のスキーマ。
-- 索引はここでは作らない。索引の効果を測る候補DDLは testdata/cases/*.index.sql にある。
CREATE TABLE events (
  id          INTEGER PRIMARY KEY,  -- 1..200000 の連番
  customer_id INTEGER,              -- 1..2000 を巡回。id%997 = 0 の行は NULL
  status      TEXT NOT NULL,        -- 'ok' / 'warn' / 'failed' を巡回
  note        TEXT                  -- 'note-'||id。id%5 = 0 の行は NULL
);
