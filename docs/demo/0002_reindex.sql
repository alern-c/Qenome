DROP INDEX ix_events_customer_id;
CREATE INDEX ix_events_status_customer ON events(status, customer_id);
