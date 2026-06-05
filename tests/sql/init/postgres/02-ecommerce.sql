\c ecommerce

-- ============================================================
-- Schema
-- ============================================================

CREATE TABLE users (
    id          SERIAL PRIMARY KEY,
    email       VARCHAR(255) NOT NULL UNIQUE,
    name        VARCHAR(100) NOT NULL,
    status      VARCHAR(20)  NOT NULL DEFAULT 'active',
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE users IS 'Application users with account status';
COMMENT ON COLUMN users.email IS 'Verified email address (unique)';
COMMENT ON COLUMN users.status IS 'active, inactive, or suspended';

CREATE TABLE products (
    id          SERIAL PRIMARY KEY,
    name        VARCHAR(200) NOT NULL,
    price       NUMERIC(10,2) NOT NULL,
    stock       INT NOT NULL DEFAULT 0,
    category    VARCHAR(100),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE products IS 'Product catalog with pricing';
COMMENT ON COLUMN products.price IS 'Current selling price';
COMMENT ON COLUMN products.stock IS 'Available inventory count';

CREATE TABLE orders (
    id          SERIAL PRIMARY KEY,
    user_id     INT NOT NULL REFERENCES users(id),
    status      VARCHAR(20)  NOT NULL DEFAULT 'pending',
    total       NUMERIC(10,2) NOT NULL DEFAULT 0,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE TABLE order_items (
    id          SERIAL PRIMARY KEY,
    order_id    INT NOT NULL REFERENCES orders(id),
    product_id  INT NOT NULL REFERENCES products(id),
    quantity    INT NOT NULL,
    unit_price  NUMERIC(10,2) NOT NULL
);

CREATE INDEX idx_orders_user_id ON orders(user_id);
CREATE INDEX idx_orders_status  ON orders(status);
CREATE INDEX idx_order_items_order_id ON order_items(order_id);
CREATE INDEX idx_products_category    ON products(category);

-- ============================================================
-- Seed data
-- ============================================================

-- 5 hand-crafted users + 50 generated users
INSERT INTO users (email, name, status) VALUES
  ('alice@example.com',   'Alice Chen',    'active'),
  ('bob@example.com',     'Bob Wang',      'active'),
  ('carol@example.com',   'Carol Li',      'inactive'),
  ('dave@example.com',    'Dave Zhang',    'active'),
  ('eve@example.com',     'Eve Liu',       'active');

INSERT INTO users (email, name, status, created_at)
SELECT
  'user' || i || '@example.com',
  'User ' || i,
  CASE WHEN i % 7 = 0 THEN 'inactive' WHEN i % 11 = 0 THEN 'suspended' ELSE 'active' END,
  NOW() - (i || ' hours')::interval
FROM generate_series(1, 50) AS i;

-- 20 hand-crafted products across categories
INSERT INTO products (name, price, stock, category, created_at) VALUES
  ('Mechanical Keyboard',   129.99,  50,  'peripherals', NOW() - INTERVAL '180 days'),
  ('Wireless Mouse',         49.99, 120,  'peripherals', NOW() - INTERVAL '170 days'),
  ('USB-C Hub',              39.99,  80,  'accessories', NOW() - INTERVAL '160 days'),
  ('Monitor Stand',          79.99,  30,  'furniture',   NOW() - INTERVAL '150 days'),
  ('Webcam HD',              89.99,  60,  'peripherals', NOW() - INTERVAL '140 days'),
  ('Laptop Sleeve',          29.99, 200,  'accessories', NOW() - INTERVAL '130 days'),
  ('Desk Lamp',              45.00,  40,  'furniture',   NOW() - INTERVAL '120 days'),
  ('Noise-cancel Headset',  199.99,  25,  'audio',       NOW() - INTERVAL '110 days'),
  ('Ergonomic Chair',       399.99,  15,  'furniture',   NOW() - INTERVAL '100 days'),
  ('Trackball Mouse',        69.99,  45,  'peripherals', NOW() - INTERVAL '90 days'),
  ('HDMI Cable 2m',          12.99, 500,  'accessories', NOW() - INTERVAL '85 days'),
  ('Bluetooth Speaker',      59.99,  70,  'audio',       NOW() - INTERVAL '80 days'),
  ('Portable SSD 1TB',      109.99,  35,  'storage',     NOW() - INTERVAL '75 days'),
  ('USB Flash Drive 64GB',    9.99, 300,  'storage',     NOW() - INTERVAL '70 days'),
  ('Wireless Charger',       34.99,  90,  'accessories', NOW() - INTERVAL '65 days'),
  ('Standing Desk',         549.99,  10,  'furniture',   NOW() - INTERVAL '60 days'),
  ('Wrist Rest',             19.99, 150,  'peripherals', NOW() - INTERVAL '55 days'),
  ('Monitor 27" 4K',        449.99,  20,  'displays',    NOW() - INTERVAL '50 days'),
  ('Webcam Light',           24.99,  80,  'peripherals', NOW() - INTERVAL '45 days'),
  ('DAC Amplifier',         159.99,  18,  'audio',       NOW() - INTERVAL '40 days');

-- 50 orders with varied statuses
INSERT INTO orders (user_id, status, total, created_at)
SELECT
  (random() * 54 + 1)::int,                          -- user_id 1..55
  (ARRAY['pending','shipped','completed','cancelled','refunded'])[1 + (random()*4)::int],
  round((random() * 500 + 10)::numeric, 2),
  NOW() - (i * 6 || ' hours')::interval
FROM generate_series(1, 50) AS i;

-- ~100 order items (1-3 per order)
INSERT INTO order_items (order_id, product_id, quantity, unit_price)
SELECT
  oid,
  (random() * 19 + 1)::int,                          -- product_id 1..20
  (random() * 4 + 1)::int,                           -- quantity 1..5
  round((random() * 400 + 5)::numeric, 2)
FROM (
  SELECT oid, generate_series(1, items) AS n
  FROM (
    SELECT i AS oid, 1 + (random() * 2)::int AS items
    FROM generate_series(1, 50) AS i
  ) sub
) expanded;
