-- =============================================================================
-- 03_staging.sql
-- Landing table for data/raw/uber_rides.csv (loaded with COPY) and a
-- validation view that flags every row that cannot be safely typed.
-- =============================================================================

CREATE TABLE IF NOT EXISTS staging.raw_rides (
    source_row_num          bigint GENERATED ALWAYS AS IDENTITY,
    ride_date               text,
    pickup_time             text,
    booking_id              text,
    booking_status          text,
    customer_id             text,
    vehicle_type            text,
    pickup_location         text,
    drop_location           text,
    cancelled_by_customer   text,
    customer_cancel_reason  text,
    cancelled_by_driver     text,
    driver_cancel_reason    text,
    incomplete_ride         text,
    incomplete_reason       text,
    booking_value           text,
    ride_distance           text,
    driver_rating           text,
    customer_rating         text,
    payment_method          text
);

-- One reject reason per row (the first rule it breaks). NULL = row is clean.
-- pg_input_is_valid() (PostgreSQL 16+) tests a cast without raising an error.
CREATE OR REPLACE VIEW staging.v_rides_validated AS
SELECT
    r.*,
    CASE
        WHEN nullif(btrim(r.booking_id), '')  IS NULL         THEN 'missing booking_id'
        WHEN nullif(btrim(r.customer_id), '') IS NULL         THEN 'missing customer_id'
        WHEN NOT pg_input_is_valid(r.ride_date, 'date')       THEN 'invalid ride_date'
        WHEN NOT pg_input_is_valid(r.pickup_time, 'time')     THEN 'invalid pickup_time'
        WHEN r.booking_status NOT IN ('Completed', 'Cancelled by Customer', 'Cancelled by Driver',
                                      'No Driver Found', 'Incomplete')
                                                              THEN 'unknown booking_status'
        WHEN nullif(btrim(r.vehicle_type), '') IS NULL        THEN 'missing vehicle_type'
        WHEN nullif(btrim(r.pickup_location), '') IS NULL
          OR nullif(btrim(r.drop_location), '')   IS NULL     THEN 'missing location'
        WHEN NOT pg_input_is_valid(coalesce(nullif(r.booking_value, ''), '0'), 'numeric(10,2)')
                                                              THEN 'invalid booking_value'
        WHEN NOT pg_input_is_valid(coalesce(nullif(r.ride_distance, ''), '0'), 'numeric(6,2)')
                                                              THEN 'invalid ride_distance'
        WHEN NOT pg_input_is_valid(coalesce(nullif(r.driver_rating, ''), '0'), 'numeric(2,1)')
          OR NOT pg_input_is_valid(coalesce(nullif(r.customer_rating, ''), '0'), 'numeric(2,1)')
                                                              THEN 'invalid rating'
        WHEN nullif(r.booking_value, '')::numeric < 0         THEN 'negative booking_value'
        WHEN nullif(r.ride_distance, '')::numeric < 0         THEN 'negative ride_distance'
        WHEN nullif(r.driver_rating, '')::numeric   NOT BETWEEN 1 AND 5
          OR nullif(r.customer_rating, '')::numeric NOT BETWEEN 1 AND 5
                                                              THEN 'rating out of range'
    END AS reject_reason
FROM staging.raw_rides AS r;
