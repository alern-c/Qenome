.bail on

CREATE TEMP TABLE checks(name TEXT, expected TEXT, actual TEXT);

INSERT INTO checks VALUES
  ('rows',                 '200000', (SELECT count(*) FROM events)),
  ('id_min',               '1',      (SELECT min(id) FROM events)),
  ('id_max',               '200000', (SELECT max(id) FROM events)),
  ('id_distinct',          '200000', (SELECT count(DISTINCT id) FROM events)),
  ('customer_id_notnull',  '199800', (SELECT count(customer_id) FROM events)),
  ('customer_id_null',     '200',    (SELECT count(*) FROM events WHERE customer_id IS NULL)),
  ('customer_id_distinct', '2000',   (SELECT count(DISTINCT customer_id) FROM events)),
  ('customer_id_min',      '1',      (SELECT min(customer_id) FROM events)),
  ('customer_id_max',      '2000',   (SELECT max(customer_id) FROM events)),
  ('customer_id_outside',  '0',      (SELECT count(*) FROM events
                                      WHERE customer_id IS NOT NULL AND (customer_id < 1 OR customer_id > 2000))),
  ('status_ok',            '66666',  (SELECT count(*) FROM events WHERE status = 'ok')),
  ('status_warn',          '66667',  (SELECT count(*) FROM events WHERE status = 'warn')),
  ('status_failed',        '66667',  (SELECT count(*) FROM events WHERE status = 'failed')),
  ('status_unknown',       '0',      (SELECT count(*) FROM events WHERE status NOT IN ('ok', 'warn', 'failed'))),
  ('note_null',            '40000',  (SELECT count(*) FROM events WHERE note IS NULL)),
  ('note_notnull',         '160000', (SELECT count(note) FROM events)),
  ('user_indexes',         '0',      (SELECT count(*) FROM sqlite_schema WHERE type = 'index' AND sql IS NOT NULL));

SELECT name, expected, actual, CASE WHEN expected = actual THEN 'ok' ELSE 'FAIL' END AS status FROM checks;

CREATE TEMP TABLE _must_pass(ok INTEGER NOT NULL CHECK (ok = 1));
INSERT INTO _must_pass(ok) SELECT 0 FROM checks WHERE expected <> actual LIMIT 1;
