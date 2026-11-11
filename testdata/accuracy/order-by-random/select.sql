SELECT id, note FROM events WHERE customer_id = ? ORDER BY random() LIMIT 10;
