-- 改善する例の候補DDL。variant 側の隔離コピーにだけ適用する（元DBには適用しない）。
CREATE INDEX ix_events_customer_id ON events(customer_id);
