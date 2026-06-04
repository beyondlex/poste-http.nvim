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

CREATE TABLE products (
    id          SERIAL PRIMARY KEY,
    name        VARCHAR(200) NOT NULL,
    price       NUMERIC(10,2) NOT NULL,
    stock       INT NOT NULL DEFAULT 0,
    category    VARCHAR(100),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

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

INSERT INTO users (email, name, status) VALUES
  ('alice@example.com',   'Alice Chen',    'active'),
  ('bob@example.com',     'Bob Wang',      'active'),
  ('carol@example.com',   'Carol Li',      'inactive'),
  ('dave@example.com',    'Dave Zhang',    'active'),
  ('eve@example.com',     'Eve Liu',       'active');

INSERT INTO products (name, price, stock, category) VALUES
  ('Mechanical Keyboard',  129.99,  50, 'peripherals'),
  ('Wireless Mouse',        49.99, 120, 'peripherals'),
  ('USB-C Hub',             39.99,  80, 'accessories'),
  ('Monitor Stand',         79.99,  30, 'furniture'),
  ('Webcam HD',             89.99,  60, 'peripherals'),
  ('Laptop Sleeve',         29.99, 200, 'accessories'),
  ('Desk Lamp',             45.00,  40, 'furniture'),
  ('Noise-cancel Headset', 199.99,  25, 'audio');

INSERT INTO orders (user_id, status, total, created_at) VALUES
  (1, 'completed',  179.98, NOW() - INTERVAL '10 days'),
  (2, 'completed',   49.99, NOW() - INTERVAL '8 days'),
  (1, 'shipped',    129.98, NOW() - INTERVAL '5 days'),
  (3, 'pending',     89.99, NOW() - INTERVAL '3 days'),
  (4, 'completed',  279.97, NOW() - INTERVAL '2 days'),
  (5, 'pending',     39.99, NOW() - INTERVAL '1 day'),
  (2, 'shipped',    249.98, NOW() - INTERVAL '6 hours');

INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
  (1, 1, 1, 129.99),
  (1, 2, 1,  49.99),
  (2, 2, 1,  49.99),
  (3, 3, 2,  39.99),
  (3, 6, 1,  29.99),
  (4, 5, 1,  89.99),
  (5, 1, 1, 129.99),
  (5, 8, 1, 199.99),
  (5, 7, 1,  45.00),
  (6, 3, 1,  39.99),
  (7, 8, 1, 199.99),
  (7, 2, 1,  49.99);
