-- =============================================================================
-- 07_data_quality.sql
-- Post-load assertions. ERROR checks block the run (the pipeline rolls back);
-- WARN checks are recorded for review but the load is kept.
-- =============================================================================

CREATE OR REPLACE PROCEDURE audit.sp_run_dq_checks(p_run_id bigint)
LANGUAGE plpgsql
AS $$
BEGIN
    DELETE FROM audit.dq_results WHERE run_id = p_run_id;

    INSERT INTO audit.dq_results (run_id, check_name, severity, failed_rows, description)

    -- Every staged row must end up either loaded or rejected.
    SELECT p_run_id, 'row_count_reconciliation', 'ERROR',
           abs(r.rows_staged - r.rows_loaded - r.rows_rejected),
           'staged rows = loaded rows + rejected rows'
    FROM audit.etl_runs AS r
    WHERE r.run_id = p_run_id

    UNION ALL
    SELECT p_run_id, 'completed_ride_missing_fare', 'ERROR', count(*),
           'Completed rides must have booking_value, distance and payment_method'
    FROM dw.fact_bookings AS f
    JOIN dw.dim_booking_status AS s USING (status_key)
    WHERE s.is_completed
      AND (f.booking_value IS NULL OR f.ride_distance_km IS NULL OR f.payment_method_key IS NULL)

    UNION ALL
    SELECT p_run_id, 'cancelled_ride_has_fare', 'ERROR', count(*),
           'Cancelled / no-driver rides must not carry revenue'
    FROM dw.fact_bookings AS f
    JOIN dw.dim_booking_status AS s USING (status_key)
    WHERE s.status_category IN ('Cancelled', 'No Driver')
      AND f.booking_value IS NOT NULL

    UNION ALL
    SELECT p_run_id, 'future_dated_ride', 'ERROR', count(*),
           'Ride date is later than today'
    FROM dw.fact_bookings AS f
    JOIN dw.dim_date AS d USING (date_key)
    WHERE d.full_date > current_date

    UNION ALL
    SELECT p_run_id, 'rejected_rows', 'WARN', count(*),
           'Rows quarantined in audit.rejected_rows during this run'
    FROM audit.rejected_rows
    WHERE run_id = p_run_id

    UNION ALL
    SELECT p_run_id, 'duplicate_booking_id', 'WARN', count(*),
           'booking_id values shared by more than one ride (kept, keyed by booking_sk)'
    FROM (SELECT booking_id FROM dw.fact_bookings GROUP BY booking_id HAVING count(*) > 1) AS d

    UNION ALL
    SELECT p_run_id, 'cancellation_without_reason', 'WARN', count(*),
           'Cancelled or incomplete rides with no recorded reason'
    FROM dw.fact_bookings AS f
    JOIN dw.dim_booking_status AS s USING (status_key)
    WHERE s.status_category IN ('Cancelled', 'Incomplete')
      AND f.cancellation_reason_key IS NULL

    UNION ALL
    SELECT p_run_id, 'pickup_equals_drop', 'WARN', count(*),
           'Pickup and drop location are identical'
    FROM dw.fact_bookings
    WHERE pickup_location_key = drop_location_key

    UNION ALL
    -- Tukey far-out fences on fare (Q3 + 3 * IQR), computed per vehicle type.
    SELECT p_run_id, 'fare_outlier', 'WARN', count(*),
           'booking_value above Q3 + 3*IQR for its vehicle type'
    FROM dw.fact_bookings AS f
    JOIN (SELECT vehicle_key,
                 percentile_cont(0.25) WITHIN GROUP (ORDER BY booking_value) AS q1,
                 percentile_cont(0.75) WITHIN GROUP (ORDER BY booking_value) AS q3
          FROM dw.fact_bookings
          WHERE booking_value IS NOT NULL
          GROUP BY vehicle_key) AS q USING (vehicle_key)
    WHERE f.booking_value > q.q3 + 3 * (q.q3 - q.q1);
END;
$$;
