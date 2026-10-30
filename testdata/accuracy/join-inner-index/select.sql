SELECT o.id, o.amount FROM customers c JOIN orders o ON o.customer_id = c.id WHERE c.email = ?;
