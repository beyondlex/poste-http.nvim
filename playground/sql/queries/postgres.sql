-- @connection pg-ecommerce
-- @database ecommerce



###
SELECT 1;

### 
use ecommerce;

show tables;
desc users;


### List all users
SELECT * FROM users;

### Active users only
SELECT id, name, email, created_at
FROM users
WHERE status = 'active'
ORDER BY created_at DESC;

###
select * from products;

### Revenue by product
SELECT p.name AS product,
       SUM(oi.quantity * oi.unit_price) AS revenue,
       SUM(oi.quantity) AS units_sold
FROM order_items oi
JOIN products p ON p.id = oi.product_id
GROUP BY p.name
ORDER BY revenue DESC;

###
select quantity, unit_price from order_items;

### Orders with item details
SELECT o.id AS order_id,
       u.name AS customer,
       o.status,
       o.total,
       COUNT(oi.id) AS item_count
FROM orders o
JOIN users u ON u.id = o.user_id
LEFT JOIN order_items oi ON oi.order_id = o.id
GROUP BY o.id, u.name, o.status, o.total
ORDER BY o.created_at DESC;

### Switch to analytics database
USE analytics;

### Recent events
SELECT event_type, user_id, payload->>'url' AS url, created_at
FROM events
ORDER BY created_at DESC
LIMIT 20;

### events
select * from events;

### Session durations
SELECT s.id,
       s.user_id,
       EXTRACT(EPOCH FROM (s.ended_at - s.started_at)) / 60 AS duration_min,
       COUNT(pv.id) AS pages_viewed
FROM sessions s
LEFT JOIN page_views pv ON pv.session_id = s.id
GROUP BY s.id, s.user_id, s.started_at, s.ended_at
ORDER BY duration_min DESC NULLS LAST;

### Event funnel: view -> cart -> purchase
SELECT
  COUNT(*) FILTER (WHERE event_type = 'page_view') AS views,
  COUNT(*) FILTER (WHERE event_type = 'add_cart')  AS add_to_cart,
  COUNT(*) FILTER (WHERE event_type = 'purchase')  AS purchases
FROM events;
