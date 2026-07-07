\c analytics

-- ============================================================
-- Schema
-- ============================================================

CREATE TABLE events (
    id          BIGSERIAL PRIMARY KEY,
    event_type  VARCHAR(50)  NOT NULL,
    user_id     INT,
    payload     JSONB,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE events IS 'User activity events for analytics';
COMMENT ON COLUMN events.event_type IS 'page_view, add_cart, purchase, login, signup';
COMMENT ON COLUMN events.payload IS 'Event-specific JSON payload';
COMMENT ON COLUMN events.user_id IS 'References ecommerce.users.id';

CREATE TABLE sessions (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     INT,
    ip          INET,
    user_agent  TEXT,
    started_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ended_at    TIMESTAMPTZ
);

CREATE TABLE page_views (
    id          BIGSERIAL PRIMARY KEY,
    session_id  UUID REFERENCES sessions(id),
    url         TEXT NOT NULL,
    referrer    TEXT,
    duration_ms INT,
    viewed_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_events_type      ON events(event_type);
CREATE INDEX idx_events_user_id   ON events(user_id);
CREATE INDEX idx_events_created   ON events(created_at);
CREATE INDEX idx_sessions_user_id ON sessions(user_id);
CREATE INDEX idx_page_views_session ON page_views(session_id);

-- ============================================================
-- Seed data
-- ============================================================

INSERT INTO sessions (id, user_id, ip, user_agent, started_at, ended_at) VALUES
  ('a0000000-0000-0000-0000-000000000001', 1, '192.168.1.10',  'Mozilla/5.0 Chrome/120', NOW() - INTERVAL '7 days',  NOW() - INTERVAL '7 days'  + INTERVAL '25 minutes'),
  ('a0000000-0000-0000-0000-000000000002', 2, '10.0.0.5',      'Mozilla/5.0 Firefox/121', NOW() - INTERVAL '5 days',  NOW() - INTERVAL '5 days'  + INTERVAL '12 minutes'),
  ('a0000000-0000-0000-0000-000000000003', 1, '192.168.1.10',  'Mozilla/5.0 Chrome/120',  NOW() - INTERVAL '2 days',  NOW() - INTERVAL '2 days'  + INTERVAL '40 minutes'),
  ('a0000000-0000-0000-0000-000000000004', 4, '172.16.0.22',   'Mozilla/5.0 Safari/17',   NOW() - INTERVAL '1 day',   NOW() - INTERVAL '1 day'   + INTERVAL '8 minutes'),
  ('a0000000-0000-0000-0000-000000000005', 5, '10.0.0.100',    'Mozilla/5.0 Chrome/120',  NOW() - INTERVAL '3 hours', NULL);

INSERT INTO events (event_type, user_id, payload, created_at) VALUES
  ('page_view',  1, '{"url": "/products", "duration_ms": 3200}',  NOW() - INTERVAL '7 days'),
  ('add_cart',   1, '{"product_id": 1, "price": 129.99}',         NOW() - INTERVAL '7 days'  + INTERVAL '3 minutes'),
  ('purchase',   1, '{"order_id": 1, "total": 179.98}',           NOW() - INTERVAL '7 days'  + INTERVAL '5 minutes'),
  ('page_view',  2, '{"url": "/products", "duration_ms": 1800}',  NOW() - INTERVAL '5 days'),
  ('add_cart',   2, '{"product_id": 2, "price": 49.99}',          NOW() - INTERVAL '5 days'  + INTERVAL '2 minutes'),
  ('purchase',   2, '{"order_id": 2, "total": 49.99}',            NOW() - INTERVAL '5 days'  + INTERVAL '4 minutes'),
  ('page_view',  1, '{"url": "/orders", "duration_ms": 5100}',    NOW() - INTERVAL '2 days'),
  ('page_view',  4, '{"url": "/", "duration_ms": 900}',           NOW() - INTERVAL '1 day'),
  ('add_cart',   4, '{"product_id": 1, "price": 129.99}',         NOW() - INTERVAL '1 day'   + INTERVAL '2 minutes'),
  ('add_cart',   4, '{"product_id": 8, "price": 199.99}',         NOW() - INTERVAL '1 day'   + INTERVAL '3 minutes'),
  ('purchase',   4, '{"order_id": 5, "total": 279.97}',           NOW() - INTERVAL '1 day'   + INTERVAL '5 minutes'),
  ('page_view',  5, '{"url": "/products", "duration_ms": 4500}',  NOW() - INTERVAL '3 hours'),
  ('login',      5, '{"method": "email"}',                        NOW() - INTERVAL '3 hours' - INTERVAL '5 minutes'),
  ('signup',     3, '{"method": "email"}',                        NOW() - INTERVAL '30 days'),
  ('login',      3, '{"method": "email"}',                        NOW() - INTERVAL '20 days');

INSERT INTO page_views (session_id, url, referrer, duration_ms, viewed_at) VALUES
  ('a0000000-0000-0000-0000-000000000001', '/',              NULL,                  1200, NOW() - INTERVAL '7 days'),
  ('a0000000-0000-0000-0000-000000000001', '/products',      '/',                  3200, NOW() - INTERVAL '7 days'  + INTERVAL '1 minute'),
  ('a0000000-0000-0000-0000-000000000001', '/products/1',    '/products',          8500, NOW() - INTERVAL '7 days'  + INTERVAL '5 minutes'),
  ('a0000000-0000-0000-0000-000000000002', '/',              'https://google.com',  800, NOW() - INTERVAL '5 days'),
  ('a0000000-0000-0000-0000-000000000002', '/products',      '/',                  1800, NOW() - INTERVAL '5 days'  + INTERVAL '1 minute'),
  ('a0000000-0000-0000-0000-000000000003', '/orders',        NULL,                  5100, NOW() - INTERVAL '2 days'),
  ('a0000000-0000-0000-0000-000000000003', '/orders/1',      '/orders',            2300, NOW() - INTERVAL '2 days'  + INTERVAL '6 minutes'),
  ('a0000000-0000-0000-0000-000000000004', '/',              NULL,                   900, NOW() - INTERVAL '1 day'),
  ('a0000000-0000-0000-0000-000000000005', '/products',      NULL,                  4500, NOW() - INTERVAL '3 hours');
