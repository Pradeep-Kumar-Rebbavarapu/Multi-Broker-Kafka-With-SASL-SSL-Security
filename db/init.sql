CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;

CREATE TABLE IF NOT EXISTS iot_sensor_data (
    id SERIAL PRIMARY KEY,
    device_id VARCHAR(50) NOT NULL,
    timestamp TIMESTAMPTZ NOT NULL,
    temperature NUMERIC NOT NULL,
    humidity NUMERIC NOT NULL,
    status VARCHAR(100) NOT NULL,
    battery_level NUMERIC NOT NULL
);

SELECT create_hypertable('iot_sensor_data', 'timestamp');

CREATE INDEX IF NOT EXISTS idx_device_id ON iot_sensor_data (device_id);
CREATE INDEX IF NOT EXISTS idx_timestamp ON iot_sensor_data (timestamp DESC);

GRANT ALL PRIVILEGES ON TABLE iot_sensor_data TO myuser;
GRANT ALL PRIVILEGES ON SEQUENCE iot_sensor_data_id_seq TO myuser;
