-- ============================================================
-- Wide table: sensor_readings (52 columns, 2000 rows)
-- Added to analytics database for testing wide-table support
-- ============================================================

\c analytics

CREATE TABLE sensor_readings (
    id              BIGSERIAL PRIMARY KEY,
    device_id       VARCHAR(50) NOT NULL,
    recorded_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    status          VARCHAR(20) NOT NULL DEFAULT 'normal',

    -- Temperature sensors (°C)
    temp_01         NUMERIC(6,2),  temp_02         NUMERIC(6,2),
    temp_03         NUMERIC(6,2),  temp_04         NUMERIC(6,2),
    temp_05         NUMERIC(6,2),  temp_06         NUMERIC(6,2),
    temp_07         NUMERIC(6,2),  temp_08         NUMERIC(6,2),

    -- Humidity sensors (%)
    humidity_01     NUMERIC(5,2),  humidity_02     NUMERIC(5,2),
    humidity_03     NUMERIC(5,2),  humidity_04     NUMERIC(5,2),
    humidity_05     NUMERIC(5,2),  humidity_06     NUMERIC(5,2),

    -- Pressure sensors (hPa)
    pressure_01     NUMERIC(7,2),  pressure_02     NUMERIC(7,2),
    pressure_03     NUMERIC(7,2),  pressure_04     NUMERIC(7,2),
    pressure_05     NUMERIC(7,2),  pressure_06     NUMERIC(7,2),

    -- Vibration sensors (mm/s)
    vibration_01    NUMERIC(6,2),  vibration_02    NUMERIC(6,2),
    vibration_03    NUMERIC(6,2),  vibration_04    NUMERIC(6,2),
    vibration_05    NUMERIC(6,2),  vibration_06    NUMERIC(6,2),

    -- Voltage sensors (V)
    voltage_01      NUMERIC(6,2),  voltage_02      NUMERIC(6,2),
    voltage_03      NUMERIC(6,2),  voltage_04      NUMERIC(6,2),
    voltage_05      NUMERIC(6,2),  voltage_06      NUMERIC(6,2),

    -- Current sensors (A)
    current_01      NUMERIC(6,2),  current_02      NUMERIC(6,2),
    current_03      NUMERIC(6,2),  current_04      NUMERIC(6,2),
    current_05      NUMERIC(6,2),  current_06      NUMERIC(6,2),

    -- Flow rate sensors (L/min)
    flow_rate_01    NUMERIC(8,2),  flow_rate_02    NUMERIC(8,2),
    flow_rate_03    NUMERIC(8,2),

    -- pH level sensors
    ph_level_01     NUMERIC(4,2),  ph_level_02     NUMERIC(4,2),
    ph_level_03     NUMERIC(4,2),

    -- Conductivity sensors (µS/cm)
    conductivity_01 NUMERIC(8,2),  conductivity_02 NUMERIC(8,2),
    conductivity_03 NUMERIC(8,2)
);

COMMENT ON TABLE sensor_readings IS 'Wide IoT sensor data table with 52 columns for testing';
COMMENT ON COLUMN sensor_readings.status IS 'normal, warning, or critical';

CREATE INDEX idx_sensor_device ON sensor_readings(device_id);
CREATE INDEX idx_sensor_time   ON sensor_readings(recorded_at);

-- 2000 sensor readings across 50 devices
INSERT INTO sensor_readings (
    device_id, recorded_at, status,
    temp_01, temp_02, temp_03, temp_04, temp_05, temp_06, temp_07, temp_08,
    humidity_01, humidity_02, humidity_03, humidity_04, humidity_05, humidity_06,
    pressure_01, pressure_02, pressure_03, pressure_04, pressure_05, pressure_06,
    vibration_01, vibration_02, vibration_03, vibration_04, vibration_05, vibration_06,
    voltage_01, voltage_02, voltage_03, voltage_04, voltage_05, voltage_06,
    current_01, current_02, current_03, current_04, current_05, current_06,
    flow_rate_01, flow_rate_02, flow_rate_03,
    ph_level_01, ph_level_02, ph_level_03,
    conductivity_01, conductivity_02, conductivity_03
)
SELECT
    'sensor-' || LPAD((i % 50 + 1)::text, 3, '0'),
    NOW() - (i * interval '1 minute'),
    CASE WHEN random() < 0.9 THEN 'normal' WHEN random() < 0.5 THEN 'warning' ELSE 'critical' END,

    round((random() * 40 + 10)::numeric, 2),  round((random() * 40 + 10)::numeric, 2),
    round((random() * 40 + 10)::numeric, 2),  round((random() * 40 + 10)::numeric, 2),
    round((random() * 40 + 10)::numeric, 2),  round((random() * 40 + 10)::numeric, 2),
    round((random() * 40 + 10)::numeric, 2),  round((random() * 40 + 10)::numeric, 2),

    round((random() * 75 + 20)::numeric, 2),  round((random() * 75 + 20)::numeric, 2),
    round((random() * 75 + 20)::numeric, 2),  round((random() * 75 + 20)::numeric, 2),
    round((random() * 75 + 20)::numeric, 2),  round((random() * 75 + 20)::numeric, 2),

    round((random() * 70 + 980)::numeric, 2), round((random() * 70 + 980)::numeric, 2),
    round((random() * 70 + 980)::numeric, 2), round((random() * 70 + 980)::numeric, 2),
    round((random() * 70 + 980)::numeric, 2), round((random() * 70 + 980)::numeric, 2),

    round((random() * 30)::numeric, 2),        round((random() * 30)::numeric, 2),
    round((random() * 30)::numeric, 2),        round((random() * 30)::numeric, 2),
    round((random() * 30)::numeric, 2),        round((random() * 30)::numeric, 2),

    round((random() * 140 + 100)::numeric, 2), round((random() * 140 + 100)::numeric, 2),
    round((random() * 140 + 100)::numeric, 2), round((random() * 140 + 100)::numeric, 2),
    round((random() * 140 + 100)::numeric, 2), round((random() * 140 + 100)::numeric, 2),

    round((random() * 50)::numeric, 2),        round((random() * 50)::numeric, 2),
    round((random() * 50)::numeric, 2),        round((random() * 50)::numeric, 2),
    round((random() * 50)::numeric, 2),        round((random() * 50)::numeric, 2),

    round((random() * 200)::numeric, 2),       round((random() * 200)::numeric, 2),
    round((random() * 200)::numeric, 2),

    round((random() * 6 + 4)::numeric, 2),     round((random() * 6 + 4)::numeric, 2),
    round((random() * 6 + 4)::numeric, 2),

    round((random() * 500)::numeric, 2),       round((random() * 500)::numeric, 2),
    round((random() * 500)::numeric, 2)
FROM generate_series(1, 2000) AS i;
