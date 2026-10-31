CREATE INDEX idx_recent_customer ON events(customer_id) WHERE created_at > 10000;
