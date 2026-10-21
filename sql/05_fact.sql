-- =============================================================================
-- 05_fact.sql
-- One row per ride request. booking_id is NOT unique in the source data
-- (different rides share an id), so the grain is keyed by a surrogate.
-- =============================================================================

CREATE TABLE IF NOT EXISTS dw.fact_bookings (
    booking_sk              bigint   GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    booking_id              text     NOT NULL,
    date_key                integer  NOT NULL REFERENCES dw.dim_date (date_key),
    pickup_time             time     NOT NULL,
    time_slot_key           smallint NOT NULL REFERENCES dw.dim_time_slot (time_slot_key),
    customer_key            integer  NOT NULL REFERENCES dw.dim_customer (customer_key),
    vehicle_key             smallint NOT NULL REFERENCES dw.dim_vehicle (vehicle_key),
    pickup_location_key     integer  NOT NULL REFERENCES dw.dim_location (location_key),
    drop_location_key       integer  NOT NULL REFERENCES dw.dim_location (location_key),
    status_key              smallint NOT NULL REFERENCES dw.dim_booking_status (status_key),
    payment_method_key      smallint REFERENCES dw.dim_payment_method (payment_method_key),
    cancellation_reason_key integer  REFERENCES dw.dim_cancellation_reason (cancellation_reason_key),
    booking_value           numeric(10,2) CHECK (booking_value >= 0),
    ride_distance_km        numeric(6,2)  CHECK (ride_distance_km >= 0),
    driver_rating           numeric(2,1)  CHECK (driver_rating BETWEEN 1 AND 5),
    customer_rating         numeric(2,1)  CHECK (customer_rating BETWEEN 1 AND 5),
    run_id                  bigint   NOT NULL REFERENCES audit.etl_runs (run_id),
    source_row_num          bigint   NOT NULL
);

-- Foreign-key / filter columns used by every dashboard page.
CREATE INDEX IF NOT EXISTS ix_fact_bookings_date       ON dw.fact_bookings (date_key);
CREATE INDEX IF NOT EXISTS ix_fact_bookings_customer   ON dw.fact_bookings (customer_key);
CREATE INDEX IF NOT EXISTS ix_fact_bookings_vehicle    ON dw.fact_bookings (vehicle_key);
CREATE INDEX IF NOT EXISTS ix_fact_bookings_pickup     ON dw.fact_bookings (pickup_location_key);
CREATE INDEX IF NOT EXISTS ix_fact_bookings_status     ON dw.fact_bookings (status_key);
CREATE INDEX IF NOT EXISTS ix_fact_bookings_booking_id ON dw.fact_bookings (booking_id);
