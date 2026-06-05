-- @connection my-blog
-- @database blog

###
SELECT * FROM authors WHERE 

###
USE blog;

###
show tables;

###
select * from posts;
###
desc posts;
###
select body from posts;

###
select s.*, c.* from posts s left join comments c on c.post_id = c.id;

###
select * from comments;

### All posts with author and category
SELECT p.title,
       a.username AS author,
       c.name AS category,
       p.status,
       p.published_at
FROM posts p
JOIN authors a    ON a.id = p.author_id
JOIN categories c ON c.id = p.category_id
ORDER BY p.created_at DESC;

### Posts with tags
SELECT p.title,
       GROUP_CONCAT(t.name SEPARATOR ', ') AS tags
FROM posts p
JOIN post_tags pt ON pt.post_id = p.id
JOIN tags t       ON t.id = pt.tag_id
GROUP BY p.id, p.title;

### Comment stats per post
SELECT p.title,
       COUNT(c.id) AS total_comments,
       SUM(c.approved) AS approved,
       COUNT(c.id) - SUM(c.approved) AS pending
FROM posts p
LEFT JOIN comments c ON c.post_id = p.id
GROUP BY p.id, p.title
HAVING total_comments > 0;

### Switch to inventory database
USE inventory;

### Stock overview by warehouse
SELECT w.name AS warehouse,
       w.city,
       COUNT(s.item_id) AS item_types,
       SUM(s.quantity) AS total_units
FROM warehouses w
LEFT JOIN stock s ON s.warehouse_id = w.id
GROUP BY w.id, w.name, w.city
ORDER BY total_units DESC;

### Low stock items (quantity < 100)
SELECT i.sku,
       i.name,
       s.quantity,
       w.name AS warehouse
FROM stock s
JOIN items i      ON i.id = s.item_id
JOIN warehouses w ON w.id = s.warehouse_id
WHERE s.quantity < 100
ORDER BY s.quantity ASC;

### Active shipments
SELECT sh.id AS shipment_id,
       wf.name AS `from`,
       wt.name AS `to`,
       sh.status,
       GROUP_CONCAT(CONCAT(i.name, ' x', si.quantity) SEPARATOR ', ') AS items
FROM shipments sh
JOIN warehouses wf ON wf.id = sh.from_warehouse
JOIN warehouses wt ON wt.id = sh.to_warehouse
LEFT JOIN shipment_items si ON si.shipment_id = sh.id
LEFT JOIN items i ON i.id = si.item_id
WHERE sh.status != 'delivered'
GROUP BY sh.id, wf.name, wt.name, sh.status;
