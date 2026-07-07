-- ============================================================
-- Wide table: web_vitals (54 columns, 2000 rows)
-- Added to blog database for testing wide-table support
-- ============================================================

CREATE DATABASE IF NOT EXISTS blog CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE blog;

CREATE TABLE web_vitals (
    id              BIGINT AUTO_INCREMENT PRIMARY KEY,
    page_id         INT NOT NULL,
    url             VARCHAR(500) NOT NULL,
    measured_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    -- Web performance metrics (all in ms unless noted)
    metric_01       DECIMAL(12,4) COMMENT 'Total page load time',
    metric_02       DECIMAL(12,4) COMMENT 'DNS lookup time',
    metric_03       DECIMAL(12,4) COMMENT 'TCP connection time',
    metric_04       DECIMAL(12,4) COMMENT 'TLS handshake time',
    metric_05       DECIMAL(12,4) COMMENT 'Time to First Byte',
    metric_06       DECIMAL(12,4) COMMENT 'First Paint',
    metric_07       DECIMAL(12,4) COMMENT 'First Contentful Paint',
    metric_08       DECIMAL(12,4) COMMENT 'Largest Contentful Paint',
    metric_09       DECIMAL(12,4) COMMENT 'DOM Interactive',
    metric_10       DECIMAL(12,4) COMMENT 'DOM Content Loaded',
    metric_11       DECIMAL(12,4) COMMENT 'DOM Complete',
    metric_12       DECIMAL(12,4) COMMENT 'Load Event End',
    metric_13       DECIMAL(12,4) COMMENT 'First Input Delay',
    metric_14       DECIMAL(12,4) COMMENT 'Cumulative Layout Shift (score)',
    metric_15       DECIMAL(12,4) COMMENT 'Time to Interactive',
    metric_16       DECIMAL(12,4) COMMENT 'Total Blocking Time',
    metric_17       DECIMAL(12,4) COMMENT 'JS parse time',
    metric_18       DECIMAL(12,4) COMMENT 'JS execution time',
    metric_19       DECIMAL(12,4) COMMENT 'CSS parse time',
    metric_20       DECIMAL(12,4) COMMENT 'Style recalc time',
    metric_21       DECIMAL(12,4) COMMENT 'Layout time',
    metric_22       DECIMAL(12,4) COMMENT 'Paint time',
    metric_23       DECIMAL(12,4) COMMENT 'Composite time',
    metric_24       DECIMAL(12,4) COMMENT 'Image decode time',
    metric_25       DECIMAL(12,4) COMMENT 'Font load time',
    metric_26       DECIMAL(12,4) COMMENT 'Resource fetch count',
    metric_27       DECIMAL(12,4) COMMENT 'Total transfer size (KB)',
    metric_28       DECIMAL(12,4) COMMENT 'DOM node count',
    metric_29       DECIMAL(12,4) COMMENT 'HTML size (KB)',
    metric_30       DECIMAL(12,4) COMMENT 'CSS size (KB)',
    metric_31       DECIMAL(12,4) COMMENT 'JS size (KB)',
    metric_32       DECIMAL(12,4) COMMENT 'Image size (KB)',
    metric_33       DECIMAL(12,4) COMMENT 'Font size (KB)',
    metric_34       DECIMAL(12,4) COMMENT 'API response time',
    metric_35       DECIMAL(12,4) COMMENT 'DB query time',
    metric_36       DECIMAL(12,4) COMMENT 'Cache hit ratio',
    metric_37       DECIMAL(12,4) COMMENT 'CDN origin time',
    metric_38       DECIMAL(12,4) COMMENT 'Edge compute time',
    metric_39       DECIMAL(12,4) COMMENT 'Bandwidth (Mbps)',
    metric_40       DECIMAL(12,4) COMMENT 'Connection type (score)',
    metric_41       DECIMAL(12,4) COMMENT 'Effective RTT',
    metric_42       DECIMAL(12,4) COMMENT 'Downlink speed (Mbps)',
    metric_43       DECIMAL(12,4) COMMENT 'Service worker time',
    metric_44       DECIMAL(12,4) COMMENT 'IndexedDB read time',
    metric_45       DECIMAL(12,4) COMMENT 'IndexedDB write time',
    metric_46       DECIMAL(12,4) COMMENT 'LocalStorage read time',
    metric_47       DECIMAL(12,4) COMMENT 'LocalStorage write time',
    metric_48       DECIMAL(12,4) COMMENT 'WebSocket connect time',
    metric_49       DECIMAL(12,4) COMMENT 'SSR render time',
    metric_50       DECIMAL(12,4) COMMENT 'Client render time',

    INDEX idx_vitals_page (page_id),
    INDEX idx_vitals_time (measured_at)
) ENGINE=InnoDB COMMENT='Web performance metrics with 54 columns for testing';

-- 2000 page performance readings (using cross-join CTE to stay within recursion limit)
INSERT INTO web_vitals (
    page_id, url, measured_at,
    metric_01, metric_02, metric_03, metric_04, metric_05,
    metric_06, metric_07, metric_08, metric_09, metric_10,
    metric_11, metric_12, metric_13, metric_14, metric_15,
    metric_16, metric_17, metric_18, metric_19, metric_20,
    metric_21, metric_22, metric_23, metric_24, metric_25,
    metric_26, metric_27, metric_28, metric_29, metric_30,
    metric_31, metric_32, metric_33, metric_34, metric_35,
    metric_36, metric_37, metric_38, metric_39, metric_40,
    metric_41, metric_42, metric_43, metric_44, metric_45,
    metric_46, metric_47, metric_48, metric_49, metric_50
)
WITH RECURSIVE seq (i) AS (
    SELECT 1
    UNION ALL
    SELECT i + 1 FROM seq WHERE i < 50
)
SELECT
    (a.i + (b.i - 1) * 50) % 20 + 1,
    ELT(1 + ((a.i + (b.i - 1) * 50) % 8),
        '/', '/about', '/products', '/blog',
        '/contact', '/pricing', '/faq', '/docs'),
    NOW() - INTERVAL (a.i + (b.i - 1) * 50) MINUTE,

    ROUND(RAND() * 5000, 4),    ROUND(RAND() * 200, 4),
    ROUND(RAND() * 300, 4),     ROUND(RAND() * 400, 4),
    ROUND(RAND() * 2000, 4),    ROUND(RAND() * 1000, 4),
    ROUND(RAND() * 1500, 4),    ROUND(RAND() * 2500, 4),
    ROUND(RAND() * 3000, 4),    ROUND(RAND() * 3000, 4),
    ROUND(RAND() * 4000, 4),    ROUND(RAND() * 4500, 4),
    ROUND(RAND() * 300, 4),     ROUND(RAND() * 10, 4),
    ROUND(RAND() * 5000, 4),    ROUND(RAND() * 2000, 4),
    ROUND(RAND() * 800, 4),     ROUND(RAND() * 2000, 4),
    ROUND(RAND() * 300, 4),     ROUND(RAND() * 500, 4),
    ROUND(RAND() * 200, 4),     ROUND(RAND() * 300, 4),
    ROUND(RAND() * 150, 4),     ROUND(RAND() * 100, 4),
    ROUND(RAND() * 50, 4),      ROUND(RAND() * 300, 4),
    ROUND(RAND() * 200, 4),     ROUND(RAND() * 100, 4),
    ROUND(RAND() * 50, 4),      ROUND(RAND() * 5000, 4),
    ROUND(RAND() * 3000, 4),    ROUND(RAND() * 2000, 4),
    ROUND(RAND() * 1000, 4),    ROUND(RAND() * 500, 4),
    ROUND(RAND() * 500, 4),     ROUND(RAND() * 1000, 4),
    ROUND(RAND() * 2000, 4),    ROUND(RAND() * 100, 4),
    ROUND(RAND() * 2000, 4),    ROUND(RAND() * 100, 4),
    ROUND(RAND() * 500, 4),     ROUND(RAND() * 400, 4),
    ROUND(RAND() * 200, 4),     ROUND(RAND() * 150, 4),
    ROUND(RAND() * 100, 4),     ROUND(RAND() * 100, 4),
    ROUND(RAND() * 50, 4),      ROUND(RAND() * 50, 4),
    ROUND(RAND() * 200, 4),     ROUND(RAND() * 3000, 4)
FROM seq a CROSS JOIN seq b
WHERE a.i + (b.i - 1) * 50 <= 2000;
