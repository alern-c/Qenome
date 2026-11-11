SELECT id, note FROM events WHERE customer_id = ? ORDER BY created_at LIMIT 10;
