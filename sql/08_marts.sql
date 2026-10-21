-- =============================================================================
-- 08_marts.sql
-- Reporting layer. Each view maps to a Power BI page / DAX measure group, so
-- the dashboard numbers can be reproduced (and audited) in plain SQL.
-- The mart schema holds only derived objects, so it is rebuilt on every run.
-- =============================================================================

DROP SCHEMA IF EXISTS mart CASCADE;
CREATE SCHEMA mart;
COMMENT ON SCHEMA mart IS 'Reporting views that mirror the Power BI dashboard pages.';

-- -----------------------------------------------------------------------------
-- Flat, analysis-ready bookings table. This is the single source Power BI imports.
-- -----------------------------------------------------------------------------
CREATE VIEW mart.vw_bookings AS
SELECT
    f.booking_sk,
    f.booking_id,
    d.full_date             AS booking_date,
    f.pickup_time,
    d.full_date + f.pickup_time AS booking_ts,
    d.year,
    d.quarter_label,
    d.month_no,
    d.month_short,
    d.iso_weekday,
    d.weekday_short,
    d.is_weekend,
    ts.time_slot_key        AS time_slot_sort,
    ts.time_slot_label,
    c.customer_id,
    v.vehicle_type,
    v.vehicle_group,
    pl.location_name        AS pickup_location,
    dl.location_name        AS drop_location,
    s.booking_status,
    s.status_category,
    s.is_completed,
    cr.reason_source        AS cancellation_source,
    cr.reason               AS cancellation_reason,
    pm.payment_method,
    f.booking_value,
    f.ride_distance_km,
    f.driver_rating,
    f.customer_rating
FROM dw.fact_bookings        AS f
JOIN dw.dim_date             AS d  USING (date_key)
JOIN dw.dim_time_slot        AS ts USING (time_slot_key)
JOIN dw.dim_customer         AS c  USING (customer_key)
JOIN dw.dim_vehicle          AS v  USING (vehicle_key)
JOIN dw.dim_location         AS pl ON pl.location_key = f.pickup_location_key
JOIN dw.dim_location         AS dl ON dl.location_key = f.drop_location_key
JOIN dw.dim_booking_status   AS s  USING (status_key)
LEFT JOIN dw.dim_payment_method      AS pm USING (payment_method_key)
LEFT JOIN dw.dim_cancellation_reason AS cr USING (cancellation_reason_key);

-- -----------------------------------------------------------------------------
-- Overview page: headline KPI cards.
-- Bookings use DISTINCT booking_id to match the DAX measure Booking_Count.
-- -----------------------------------------------------------------------------
CREATE VIEW mart.vw_kpi_overview AS
WITH base AS (
    SELECT
        count(*)                                                AS total_rides,
        count(DISTINCT booking_id)                              AS total_bookings,
        count(DISTINCT booking_id) FILTER (WHERE is_completed)     AS completed_bookings,
        count(DISTINCT booking_id) FILTER (WHERE NOT is_completed) AS lost_bookings,
        count(DISTINCT customer_id)                             AS total_customers,
        sum(booking_value)                                      AS total_revenue,
        sum(ride_distance_km)                                   AS total_distance_km,
        avg(ride_distance_km)                                   AS avg_distance_km,
        avg(driver_rating)                                      AS avg_driver_rating,
        avg(customer_rating)                                    AS avg_customer_rating
    FROM mart.vw_bookings
)
SELECT
    total_rides,
    total_bookings,
    completed_bookings,
    lost_bookings,
    total_customers,
    total_revenue,
    total_distance_km,
    round(avg_distance_km, 2)                                           AS avg_distance_km,
    round(avg_driver_rating, 2)                                         AS avg_driver_rating,
    round(avg_customer_rating, 2)                                       AS avg_customer_rating,
    round(100.0 * completed_bookings / nullif(total_bookings, 0), 2)    AS completion_rate_pct,
    round(total_revenue / nullif(total_bookings, 0), 2)                 AS avg_revenue_per_booking,
    round(total_revenue / nullif(total_distance_km, 0), 2)              AS revenue_per_km,
    -- DAX [Lost Revenue]: share of lost bookings applied to booked revenue.
    round(total_revenue * lost_bookings / nullif(total_bookings, 0), 2) AS lost_revenue_estimate
FROM base;

-- -----------------------------------------------------------------------------
-- Monthly / quarterly trend with month-over-month revenue change (DAX MoM Revenue %).
-- -----------------------------------------------------------------------------
CREATE VIEW mart.vw_monthly_trend AS
WITH monthly AS (
    SELECT
        year,
        month_no,
        month_short,
        quarter_label,
        count(DISTINCT booking_id)                          AS bookings,
        count(DISTINCT booking_id) FILTER (WHERE is_completed) AS completed_bookings,
        count(DISTINCT customer_id)                         AS customers,
        coalesce(sum(booking_value), 0)                     AS revenue,
        coalesce(sum(ride_distance_km), 0)                  AS distance_km
    FROM mart.vw_bookings
    GROUP BY year, month_no, month_short, quarter_label
)
SELECT
    m.*,
    lag(revenue) OVER w                                             AS prev_month_revenue,
    round(100.0 * (revenue - lag(revenue) OVER w)
          / nullif(lag(revenue) OVER w, 0), 2)                      AS mom_revenue_change_pct,
    sum(revenue) OVER (PARTITION BY year ORDER BY month_no)         AS revenue_ytd
FROM monthly AS m
WINDOW w AS (PARTITION BY year ORDER BY month_no);

CREATE VIEW mart.vw_quarterly_trend AS
WITH quarterly AS (
    SELECT
        year,
        quarter_label,
        count(DISTINCT booking_id)          AS bookings,
        coalesce(sum(booking_value), 0)     AS revenue
    FROM mart.vw_bookings
    GROUP BY year, quarter_label
)
SELECT
    q.*,
    round(100.0 * (revenue - lag(revenue) OVER w) / nullif(lag(revenue) OVER w, 0), 2)
        AS qoq_revenue_change_pct
FROM quarterly AS q
WINDOW w AS (PARTITION BY year ORDER BY quarter_label);

-- -----------------------------------------------------------------------------
-- Vehicle page: contribution %, completion and incomplete rates per vehicle group.
-- -----------------------------------------------------------------------------
CREATE VIEW mart.vw_vehicle_performance AS
WITH by_vehicle AS (
    SELECT
        vehicle_group,
        count(DISTINCT booking_id)                                  AS bookings,
        count(DISTINCT booking_id) FILTER (WHERE is_completed)      AS completed_bookings,
        count(*) FILTER (WHERE status_category = 'Incomplete')      AS incomplete_rides,
        count(*)                                                    AS total_rides,
        coalesce(sum(booking_value), 0)                             AS revenue,
        coalesce(sum(ride_distance_km), 0)                          AS distance_km,
        avg(ride_distance_km)                                       AS avg_distance_km,
        avg(driver_rating)                                          AS avg_driver_rating
    FROM mart.vw_bookings
    GROUP BY vehicle_group
)
SELECT
    vehicle_group,
    bookings,
    completed_bookings,
    revenue,
    round(100.0 * revenue / sum(revenue) OVER (), 2)                AS revenue_contribution_pct,
    round(100.0 * completed_bookings / nullif(bookings, 0), 2)      AS completion_rate_pct,
    round(100.0 * incomplete_rides / nullif(total_rides, 0), 2)     AS incomplete_rate_pct,
    distance_km,
    round(avg_distance_km, 2)                                       AS avg_distance_km,
    round(revenue / nullif(distance_km, 0), 2)                      AS revenue_per_km,
    round(avg_driver_rating, 2)                                     AS avg_driver_rating,
    rank() OVER (ORDER BY revenue DESC)                             AS revenue_rank
FROM by_vehicle;

-- -----------------------------------------------------------------------------
-- Revenue page: payment method mix.
-- -----------------------------------------------------------------------------
CREATE VIEW mart.vw_revenue_by_payment AS
SELECT
    payment_method,
    count(*)                                                AS paid_rides,
    sum(booking_value)                                      AS revenue,
    round(100.0 * sum(booking_value) / sum(sum(booking_value)) OVER (), 2) AS revenue_share_pct,
    round(avg(booking_value), 2)                            AS avg_ticket
FROM mart.vw_bookings
WHERE payment_method IS NOT NULL
GROUP BY payment_method;

-- -----------------------------------------------------------------------------
-- Customer page: per-customer summary + segmentation.
-- Segments follow the DAX measures First_Time / Return_Time / Regular_Customer
-- as filtered on the dashboard: completed rides per customer = 1 / 2 / >= 3.
-- -----------------------------------------------------------------------------
CREATE VIEW mart.vw_customer_summary AS
SELECT
    customer_id,
    count(*)                                            AS rides,
    count(*) FILTER (WHERE is_completed)                AS completed_rides,
    count(*) FILTER (WHERE NOT is_completed)            AS lost_rides,
    coalesce(sum(booking_value), 0)                     AS revenue,
    round(avg(ride_distance_km), 2)                     AS avg_distance_km,
    min(booking_date)                                   AS first_booking_date,
    max(booking_date)                                   AS last_booking_date,
    CASE count(*) FILTER (WHERE is_completed)
        WHEN 0 THEN 'No Completed Ride'
        WHEN 1 THEN 'First Time'
        WHEN 2 THEN 'Returning'
        ELSE 'Regular'
    END                                                 AS customer_segment
FROM mart.vw_bookings
GROUP BY customer_id;

CREATE VIEW mart.vw_customer_segments AS
SELECT
    customer_segment,
    count(*)                                                AS customers,
    round(100.0 * count(*) / sum(count(*)) OVER (), 2)      AS customer_share_pct,
    sum(revenue)                                            AS revenue
FROM mart.vw_customer_summary
GROUP BY customer_segment;

-- Customer cancellation KPIs (DAX: Customer Cancelled Count, Customer Cancellation
-- Rate, Customer Cancelled Revenue Impact, Customer Revenue Risk %, Reliability Index).
CREATE VIEW mart.vw_customer_cancellation_kpis AS
WITH base AS (
    SELECT
        count(*)                                                    AS total_rides,
        count(*) FILTER (WHERE cancellation_source = 'Customer')    AS customer_cancelled,
        sum(booking_value)                                          AS total_revenue,
        avg(booking_value) FILTER (WHERE is_completed)              AS avg_completed_value,
        mode() WITHIN GROUP (ORDER BY cancellation_reason)
            FILTER (WHERE cancellation_source = 'Customer')         AS top_reason
    FROM mart.vw_bookings
)
SELECT
    customer_cancelled                                                  AS customer_cancelled_count,
    round(100.0 * customer_cancelled / total_rides, 2)                  AS customer_cancellation_rate_pct,
    round(avg_completed_value, 2)                                       AS avg_revenue_per_completed_booking,
    round(customer_cancelled * avg_completed_value, 2)                  AS customer_cancelled_revenue_impact,
    round(100.0 * customer_cancelled * avg_completed_value / total_revenue, 2)
                                                                        AS customer_revenue_risk_pct,
    round(100.0 - 100.0 * customer_cancelled / total_rides, 2)          AS customer_reliability_index_pct,
    top_reason                                                          AS top_customer_cancellation_reason
FROM base;

-- All cancellation / incomplete reasons, ranked within their source.
CREATE VIEW mart.vw_cancellation_reasons AS
SELECT
    cancellation_source,
    cancellation_reason,
    count(*)                                                                    AS rides,
    round(100.0 * count(*) / sum(count(*)) OVER (PARTITION BY cancellation_source), 2)
                                                                                AS share_of_source_pct,
    rank() OVER (PARTITION BY cancellation_source ORDER BY count(*) DESC)       AS rank_in_source
FROM mart.vw_bookings
WHERE cancellation_reason IS NOT NULL
GROUP BY cancellation_source, cancellation_reason;

-- -----------------------------------------------------------------------------
-- Location page: pickup hotspots, routes and the day x time-slot heatmap.
-- -----------------------------------------------------------------------------
CREATE VIEW mart.vw_location_performance AS
SELECT
    pickup_location,
    count(*)                                                        AS pickups,
    count(*) FILTER (WHERE is_completed)                            AS completed_rides,
    count(*) FILTER (WHERE status_category = 'No Driver')           AS no_driver_found,
    round(100.0 * count(*) FILTER (WHERE status_category = 'No Driver') / count(*), 2)
                                                                    AS no_driver_rate_pct,
    coalesce(sum(booking_value), 0)                                 AS revenue,
    coalesce(sum(ride_distance_km), 0)                              AS distance_km,
    rank() OVER (ORDER BY count(*) DESC)                            AS pickup_rank
FROM mart.vw_bookings
GROUP BY pickup_location;

CREATE VIEW mart.vw_top_routes AS
SELECT
    pickup_location,
    drop_location,
    count(*)                                        AS rides,
    coalesce(sum(booking_value), 0)                 AS revenue,
    round(avg(ride_distance_km), 2)                 AS avg_distance_km,
    rank() OVER (ORDER BY count(*) DESC)            AS route_rank
FROM mart.vw_bookings
GROUP BY pickup_location, drop_location;

CREATE VIEW mart.vw_demand_heatmap AS
SELECT
    iso_weekday,
    weekday_short,
    time_slot_sort,
    time_slot_label,
    count(*)                                                AS rides,
    round(100.0 * count(*) / sum(count(*)) OVER (), 2)      AS share_of_week_pct
FROM mart.vw_bookings
GROUP BY iso_weekday, weekday_short, time_slot_sort, time_slot_label;

-- -----------------------------------------------------------------------------
-- Pre-aggregated daily grain for fast dashboard refreshes.
-- Created empty and populated by the pipeline after each load. The unique index
-- allows REFRESH ... CONCURRENTLY for out-of-band refreshes while Power BI reads.
-- -----------------------------------------------------------------------------
CREATE MATERIALIZED VIEW mart.mv_daily_kpis AS
SELECT
    booking_date,
    vehicle_group,
    count(*)                                                    AS rides,
    count(*) FILTER (WHERE is_completed)                        AS completed_rides,
    count(*) FILTER (WHERE status_category = 'Cancelled')       AS cancelled_rides,
    count(*) FILTER (WHERE status_category = 'No Driver')       AS no_driver_rides,
    coalesce(sum(booking_value), 0)                             AS revenue,
    coalesce(sum(ride_distance_km), 0)                          AS distance_km
FROM mart.vw_bookings
GROUP BY booking_date, vehicle_group
WITH NO DATA;

CREATE UNIQUE INDEX ux_mv_daily_kpis ON mart.mv_daily_kpis (booking_date, vehicle_group);
