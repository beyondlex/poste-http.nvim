-- @connection postgres://{{db_user}}:***@{{db_host}}:{{db_port}}/{{db_name}}

### Active users
SELECT * FROM users WHERE active = true;

### User count by status
SELECT status, COUNT(*) as count
FROM users
GROUP BY status;

### Slow query investigation
EXPLAIN ANALYZE
SELECT * FROM orders
WHERE status = 'pending'
ORDER BY created_at DESC
LIMIT 100;
