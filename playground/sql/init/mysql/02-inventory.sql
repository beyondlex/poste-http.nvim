-- ============================================================
-- Database: inventory
-- ============================================================

CREATE DATABASE IF NOT EXISTS inventory CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE inventory;

-- Schema

CREATE TABLE warehouses (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    name        VARCHAR(200) NOT NULL,
    city        VARCHAR(100) NOT NULL,
    capacity    INT NOT NULL,
    created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE suppliers (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    name        VARCHAR(200) NOT NULL,
    contact     VARCHAR(100),
    phone       VARCHAR(30),
    rating      DECIMAL(3,2) DEFAULT 0.00,
    created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE items (
    id            INT AUTO_INCREMENT PRIMARY KEY COMMENT 'Primary key',
    sku           VARCHAR(50)  NOT NULL UNIQUE COMMENT 'Stock keeping unit code',
    name          VARCHAR(200) NOT NULL COMMENT 'Display name',
    unit_price    DECIMAL(10,2) NOT NULL COMMENT 'Price per unit in CNY',
    weight_kg     DECIMAL(8,3) COMMENT 'Weight in kilograms',
    supplier_id   INT COMMENT 'References suppliers.id',
    created_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT 'Record creation timestamp',
    FOREIGN KEY (supplier_id) REFERENCES suppliers(id)
) ENGINE=InnoDB COMMENT='Product inventory items';

CREATE TABLE stock (
    id            INT AUTO_INCREMENT PRIMARY KEY,
    item_id       INT NOT NULL,
    warehouse_id  INT NOT NULL,
    quantity      INT NOT NULL DEFAULT 0,
    last_updated  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uq_stock (item_id, warehouse_id),
    FOREIGN KEY (item_id)      REFERENCES items(id),
    FOREIGN KEY (warehouse_id) REFERENCES warehouses(id)
) ENGINE=InnoDB;

CREATE TABLE shipments (
    id            INT AUTO_INCREMENT PRIMARY KEY,
    from_warehouse INT NOT NULL,
    to_warehouse   INT NOT NULL,
    status        ENUM('pending','in_transit','delivered','cancelled') NOT NULL DEFAULT 'pending',
    shipped_at    TIMESTAMP NULL,
    delivered_at  TIMESTAMP NULL,
    created_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (from_warehouse) REFERENCES warehouses(id),
    FOREIGN KEY (to_warehouse)   REFERENCES warehouses(id),
    INDEX idx_shipments_status (status)
) ENGINE=InnoDB;

CREATE TABLE shipment_items (
    id            INT AUTO_INCREMENT PRIMARY KEY,
    shipment_id   INT NOT NULL,
    item_id       INT NOT NULL,
    quantity      INT NOT NULL,
    FOREIGN KEY (shipment_id) REFERENCES shipments(id),
    FOREIGN KEY (item_id)     REFERENCES items(id)
) ENGINE=InnoDB;

-- Seed data

INSERT INTO warehouses (name, city, capacity) VALUES
  ('East Hub',     'Shanghai',  10000),
  ('West Hub',     'Chengdu',    8000),
  ('South Hub',    'Shenzhen',  12000),
  ('Central Hub',  'Wuhan',      6000);

INSERT INTO suppliers (name, contact, phone, rating) VALUES
  ('Shenzhen Electronics Co.',  'Li Wei',     '+86-755-1234-5678', 4.50),
  ('Shanghai Parts Ltd.',       'Zhang Min',  '+86-21-8765-4321',  3.80),
  ('Beijing Materials Inc.',    'Wang Fang',  '+86-10-1111-2222',  4.20),
  ('Guangzhou Supply Chain',    'Chen Jie',   '+86-20-3333-4444',  4.70);

INSERT INTO items (sku, name, unit_price, weight_kg, supplier_id) VALUES
  ('ELEC-001', 'Circuit Board A',      12.50,  0.150, 1),
  ('ELEC-002', 'LED Module',            3.75,  0.050, 1),
  ('ELEC-003', 'Power Supply Unit',    28.00,  0.800, 1),
  ('PART-001', 'Aluminum Housing',     15.00,  1.200, 2),
  ('PART-002', 'Steel Bracket',         4.50,  0.300, 2),
  ('PART-003', 'Rubber Gasket',         0.80,  0.020, 2),
  ('MAT-001',  'Copper Wire (100m)',   45.00,  2.500, 3),
  ('MAT-002',  'Solder Paste (500g)',  18.00,  0.500, 3),
  ('SUPP-001', 'Thermal Paste',         6.00,  0.100, 4),
  ('SUPP-002', 'Cable Tie (1000pc)',    8.50,  1.000, 4);

INSERT INTO stock (item_id, warehouse_id, quantity) VALUES
  (1,  1, 500),  (1,  2, 200),  (1,  3, 350),
  (2,  1, 2000), (2,  3, 1500),
  (3,  1, 150),  (3,  2, 80),   (3,  4, 60),
  (4,  2, 300),  (4,  3, 450),
  (5,  1, 1000), (5,  2, 800),  (5,  3, 600),  (5,  4, 400),
  (6,  1, 5000), (6,  2, 3000), (6,  3, 4000), (6,  4, 2000),
  (7,  3, 100),  (7,  4, 75),
  (8,  1, 200),  (8,  2, 150),
  (9,  1, 800),  (9,  3, 500),
  (10, 2, 300),  (10, 4, 250);

INSERT INTO shipments (from_warehouse, to_warehouse, status, shipped_at, delivered_at) VALUES
  (1, 2, 'delivered',  NOW() - INTERVAL 10 DAY, NOW() - INTERVAL 8 DAY),
  (1, 4, 'delivered',  NOW() - INTERVAL 7 DAY,  NOW() - INTERVAL 5 DAY),
  (3, 1, 'in_transit', NOW() - INTERVAL 1 DAY,  NULL),
  (2, 3, 'pending',    NULL,                    NULL),
  (1, 3, 'delivered',  NOW() - INTERVAL 20 DAY, NOW() - INTERVAL 18 DAY);

INSERT INTO shipment_items (shipment_id, item_id, quantity) VALUES
  (1, 1,  100),
  (1, 3,   50),
  (2, 7,   30),
  (2, 8,   50),
  (3, 2,  500),
  (3, 9,  200),
  (4, 4,  150),
  (4, 5,  300),
  (5, 6, 2000);
