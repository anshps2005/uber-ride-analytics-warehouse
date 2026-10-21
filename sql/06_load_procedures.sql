-- =============================================================================
-- 06_load_procedures.sql
-- staging.raw_rides  ->  audit.rejected_rows (bad rows)
--                    ->  dw.dim_*           (new members appended)
--                    ->  dw.fact_bookings   (full refresh)
-- The caller runs this inside one transaction, so a failure leaves the
-- warehouse exactly as it was before the run.
-- =============================================================================

CREATE OR REPLACE PROCEDURE dw.sp_load_bookings(p_run_id bigint)
LANGUAGE plpgsql
AS $$
DECLARE
    v_staged   integer;
    v_rejected integer;
    v_loaded   integer;
BEGIN
    SELECT count(*) INTO v_staged FROM staging.raw_rides;

    -- 1. Quarantine rows that fail validation ---------------------------------
    INSERT INTO audit.rejected_rows (run_id, source_row_num, booking_id, reject_reason, raw_record)
    SELECT p_run_id, v.source_row_num, v.booking_id, v.reject_reason,
           to_jsonb(v) - 'reject_reason' - 'source_row_num'
    FROM staging.v_rides_validated AS v
    WHERE v.reject_reason IS NOT NULL;
    GET DIAGNOSTICS v_rejected = ROW_COUNT;

    -- 2. Typed, trimmed copy of the clean rows ---------------------------------
    DROP TABLE IF EXISTS tmp_rides;
    CREATE TEMP TABLE tmp_rides ON COMMIT DROP AS
    SELECT
        v.source_row_num,
        btrim(v.booking_id)                         AS booking_id,
        v.ride_date::date                           AS ride_date,
        v.pickup_time::time                         AS pickup_time,
        btrim(v.booking_status)                     AS booking_status,
        btrim(v.customer_id)                        AS customer_id,
        btrim(v.vehicle_type)                       AS vehicle_type,
        btrim(v.pickup_location)                    AS pickup_location,
        btrim(v.drop_location)                      AS drop_location,
        nullif(btrim(v.payment_method), '')         AS payment_method,
        CASE v.booking_status
            WHEN 'Cancelled by Customer' THEN 'Customer'
            WHEN 'Cancelled by Driver'   THEN 'Driver'
            WHEN 'Incomplete'            THEN 'Incomplete'
        END                                         AS reason_source,
        nullif(btrim(CASE v.booking_status
            WHEN 'Cancelled by Customer' THEN v.customer_cancel_reason
            WHEN 'Cancelled by Driver'   THEN v.driver_cancel_reason
            WHEN 'Incomplete'            THEN v.incomplete_reason
        END), '')                                   AS reason,
        nullif(v.booking_value, '')::numeric(10,2)  AS booking_value,
        nullif(v.ride_distance, '')::numeric(6,2)   AS ride_distance_km,
        nullif(v.driver_rating, '')::numeric(2,1)   AS driver_rating,
        nullif(v.customer_rating, '')::numeric(2,1) AS customer_rating
    FROM staging.v_rides_validated AS v
    WHERE v.reject_reason IS NULL;

    -- 3. Dimensions: append unseen members only --------------------------------
    INSERT INTO dw.dim_date (date_key, full_date, year, quarter, quarter_label, month_no,
                             month_name, month_short, day_of_month, iso_weekday,
                             weekday_short, is_weekend)
    SELECT to_char(d, 'YYYYMMDD')::integer,
           d::date,
           extract(year FROM d),
           extract(quarter FROM d),
           'Q' || extract(quarter FROM d),
           extract(month FROM d),
           to_char(d, 'FMMonth'),
           to_char(d, 'Mon'),
           extract(day FROM d),
           extract(isodow FROM d),
           to_char(d, 'Dy'),
           extract(isodow FROM d) IN (6, 7)
    FROM (SELECT make_date(extract(year FROM min(ride_date))::int, 1, 1)   AS first_day,
                 make_date(extract(year FROM max(ride_date))::int, 12, 31) AS last_day
          FROM tmp_rides) AS bounds,
         generate_series(bounds.first_day, bounds.last_day, interval '1 day') AS d
    ON CONFLICT (date_key) DO NOTHING;

    INSERT INTO dw.dim_vehicle (vehicle_type, vehicle_group)
    SELECT DISTINCT vehicle_type,
           CASE WHEN vehicle_type ILIKE '%bike%' THEN 'Bike' ELSE vehicle_type END
    FROM tmp_rides
    ON CONFLICT (vehicle_type) DO NOTHING;

    INSERT INTO dw.dim_location (location_name)
    SELECT pickup_location FROM tmp_rides
    UNION
    SELECT drop_location FROM tmp_rides
    ON CONFLICT (location_name) DO NOTHING;

    INSERT INTO dw.dim_customer (customer_id)
    SELECT DISTINCT customer_id FROM tmp_rides
    ON CONFLICT (customer_id) DO NOTHING;

    INSERT INTO dw.dim_payment_method (payment_method)
    SELECT DISTINCT payment_method FROM tmp_rides WHERE payment_method IS NOT NULL
    ON CONFLICT (payment_method) DO NOTHING;

    INSERT INTO dw.dim_booking_status (booking_status, status_category, is_completed)
    SELECT DISTINCT booking_status,
           CASE booking_status
               WHEN 'Completed'       THEN 'Completed'
               WHEN 'Incomplete'      THEN 'Incomplete'
               WHEN 'No Driver Found' THEN 'No Driver'
               ELSE 'Cancelled'
           END,
           booking_status = 'Completed'
    FROM tmp_rides
    ON CONFLICT (booking_status) DO NOTHING;

    INSERT INTO dw.dim_cancellation_reason (reason_source, reason)
    SELECT DISTINCT reason_source, reason
    FROM tmp_rides
    WHERE reason IS NOT NULL
    ON CONFLICT (reason_source, reason) DO NOTHING;

    -- 4. Fact: full refresh ----------------------------------------------------
    TRUNCATE dw.fact_bookings RESTART IDENTITY;

    INSERT INTO dw.fact_bookings (
        booking_id, date_key, pickup_time, time_slot_key, customer_key, vehicle_key,
        pickup_location_key, drop_location_key, status_key, payment_method_key,
        cancellation_reason_key, booking_value, ride_distance_km, driver_rating,
        customer_rating, run_id, source_row_num)
    SELECT
        t.booking_id,
        to_char(t.ride_date, 'YYYYMMDD')::integer,
        t.pickup_time,
        extract(hour FROM t.pickup_time)::integer / 3 + 1,
        c.customer_key,
        v.vehicle_key,
        pl.location_key,
        dl.location_key,
        s.status_key,
        pm.payment_method_key,
        cr.cancellation_reason_key,
        t.booking_value,
        t.ride_distance_km,
        t.driver_rating,
        t.customer_rating,
        p_run_id,
        t.source_row_num
    FROM tmp_rides AS t
    JOIN dw.dim_customer            AS c  ON c.customer_id     = t.customer_id
    JOIN dw.dim_vehicle             AS v  ON v.vehicle_type    = t.vehicle_type
    JOIN dw.dim_location            AS pl ON pl.location_name  = t.pickup_location
    JOIN dw.dim_location            AS dl ON dl.location_name  = t.drop_location
    JOIN dw.dim_booking_status      AS s  ON s.booking_status  = t.booking_status
    LEFT JOIN dw.dim_payment_method AS pm ON pm.payment_method = t.payment_method
    LEFT JOIN dw.dim_cancellation_reason AS cr
           ON cr.reason_source = t.reason_source AND cr.reason = t.reason;
    GET DIAGNOSTICS v_loaded = ROW_COUNT;

    -- 5. Customer lifetime attributes -------------------------------------------
    UPDATE dw.dim_customer AS c
    SET first_booking_date = agg.first_date,
        last_booking_date  = agg.last_date
    FROM (SELECT f.customer_key,
                 min(d.full_date) AS first_date,
                 max(d.full_date) AS last_date
          FROM dw.fact_bookings AS f
          JOIN dw.dim_date      AS d USING (date_key)
          GROUP BY f.customer_key) AS agg
    WHERE c.customer_key = agg.customer_key;

    UPDATE audit.etl_runs
    SET rows_staged = v_staged, rows_loaded = v_loaded, rows_rejected = v_rejected
    WHERE run_id = p_run_id;

    RAISE NOTICE 'run %: staged %, loaded %, rejected %', p_run_id, v_staged, v_loaded, v_rejected;
END;
$$;
