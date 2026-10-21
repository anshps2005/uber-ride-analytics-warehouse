-- =============================================================================
-- business_insights.sql
-- Ad-hoc analysis that goes beyond the dashboard. Each query is standalone;
-- run them in psql, DBeaver or pgAdmin against the uber_analytics database.
-- =============================================================================


-- Q1. Revenue concentration (Pareto): what share of customers drives 80% of revenue?
WITH ranked AS (
    SELECT customer_id,
           revenue,
           sum(revenue) OVER (ORDER BY revenue DESC, customer_id) AS cumulative_revenue,
           sum(revenue) OVER ()                                   AS total_revenue,
           row_number() OVER (ORDER BY revenue DESC, customer_id) AS customer_rank,
           count(*) OVER ()                                       AS total_customers
    FROM mart.vw_customer_summary
    WHERE revenue > 0
)
SELECT min(customer_rank)                                          AS customers_for_80pct_revenue,
       max(total_customers)                                        AS paying_customers,
       round(100.0 * min(customer_rank) / max(total_customers), 2) AS pct_of_paying_customers
FROM ranked
WHERE cumulative_revenue >= 0.8 * total_revenue;


-- Q2. Busiest time slot for each vehicle group (top-N per group).
SELECT vehicle_group, time_slot_label, rides, share_of_group_pct
FROM (
    SELECT vehicle_group,
           time_slot_label,
           count(*)                                                              AS rides,
           round(100.0 * count(*) / sum(count(*)) OVER (PARTITION BY vehicle_group), 2) AS share_of_group_pct,
           row_number() OVER (PARTITION BY vehicle_group ORDER BY count(*) DESC) AS rn
    FROM mart.vw_bookings
    GROUP BY vehicle_group, time_slot_label
) AS s
WHERE rn = 1
ORDER BY rides DESC;


-- Q3. Rolling 7-day revenue and bookings (smooths day-of-week noise).
SELECT booking_date,
       sum(revenue) AS revenue,
       sum(sum(revenue)) OVER (ORDER BY booking_date
                               RANGE BETWEEN INTERVAL '6 days' PRECEDING AND CURRENT ROW) AS revenue_7d,
       round(avg(sum(rides)) OVER (ORDER BY booking_date
                                   RANGE BETWEEN INTERVAL '6 days' PRECEDING AND CURRENT ROW), 1) AS avg_daily_rides_7d
FROM mart.mv_daily_kpis
GROUP BY booking_date
ORDER BY booking_date;


-- Q4. Monthly acquisition: new vs repeat customers (cohort by first booking month).
WITH first_month AS (
    SELECT customer_id, date_trunc('month', min(booking_date))::date AS cohort_month
    FROM mart.vw_bookings
    GROUP BY customer_id
)
SELECT date_trunc('month', b.booking_date)::date                         AS month,
       count(DISTINCT b.customer_id) FILTER (WHERE f.cohort_month =  date_trunc('month', b.booking_date)) AS new_customers,
       count(DISTINCT b.customer_id) FILTER (WHERE f.cohort_month <  date_trunc('month', b.booking_date)) AS repeat_customers
FROM mart.vw_bookings AS b
JOIN first_month      AS f USING (customer_id)
GROUP BY 1
ORDER BY 1;


-- Q5. Driver cancellation hotspots: time slots where drivers cancel more than average.
WITH slot AS (
    SELECT time_slot_sort,
           time_slot_label,
           count(*)                                                   AS rides,
           count(*) FILTER (WHERE cancellation_source = 'Driver')     AS driver_cancellations
    FROM mart.vw_bookings
    GROUP BY time_slot_sort, time_slot_label
)
SELECT time_slot_label,
       rides,
       driver_cancellations,
       round(100.0 * driver_cancellations / rides, 2)                                AS driver_cancel_rate_pct,
       round(100.0 * driver_cancellations / rides
             - 100.0 * sum(driver_cancellations) OVER () / sum(rides) OVER (), 2)    AS vs_overall_pp
FROM slot
ORDER BY time_slot_sort;


-- Q6. Fare distribution by vehicle group (median and spread, not just averages).
SELECT vehicle_group,
       count(*)                                                                  AS paid_rides,
       round(percentile_cont(0.25) WITHIN GROUP (ORDER BY booking_value)::numeric, 2) AS p25_fare,
       round(percentile_cont(0.50) WITHIN GROUP (ORDER BY booking_value)::numeric, 2) AS median_fare,
       round(percentile_cont(0.75) WITHIN GROUP (ORDER BY booking_value)::numeric, 2) AS p75_fare,
       round(percentile_cont(0.95) WITHIN GROUP (ORDER BY booking_value)::numeric, 2) AS p95_fare,
       round(percentile_cont(0.50) WITHIN GROUP (ORDER BY booking_value / nullif(ride_distance_km, 0))::numeric, 2)
                                                                                 AS median_fare_per_km
FROM mart.vw_bookings
WHERE booking_value IS NOT NULL
GROUP BY vehicle_group
ORDER BY median_fare DESC;


-- Q7. Supply gaps: pickup areas with the highest "No Driver Found" rate (min. 500 requests).
SELECT pickup_location, pickups, no_driver_found, no_driver_rate_pct
FROM mart.vw_location_performance
WHERE pickups >= 500
ORDER BY no_driver_rate_pct DESC
LIMIT 10;


-- Q8. Weekend vs weekday performance.
SELECT CASE WHEN is_weekend THEN 'Weekend' ELSE 'Weekday' END             AS day_type,
       count(DISTINCT booking_date)                                       AS days,
       round(count(*)::numeric / count(DISTINCT booking_date), 1)         AS rides_per_day,
       round(sum(booking_value) / count(DISTINCT booking_date), 2)        AS revenue_per_day,
       round(100.0 * count(*) FILTER (WHERE is_completed) / count(*), 2)  AS completion_rate_pct
FROM mart.vw_bookings
GROUP BY is_weekend;


-- Q9. Do ratings move with fare or distance? (Pearson correlation on completed rides.)
SELECT vehicle_group,
       round(corr(customer_rating, booking_value)::numeric, 3)     AS corr_rating_fare,
       round(corr(customer_rating, ride_distance_km)::numeric, 3)  AS corr_rating_distance,
       round(corr(driver_rating, ride_distance_km)::numeric, 3)    AS corr_driver_rating_distance
FROM mart.vw_bookings
WHERE is_completed
GROUP BY vehicle_group
ORDER BY vehicle_group;


-- Q10. Most valuable routes: revenue per km on routes with enough volume.
SELECT pickup_location || ' -> ' || drop_location                AS route,
       count(*)                                                   AS rides,
       count(booking_value)                                       AS paid_rides,
       sum(booking_value)                                         AS revenue,
       round(sum(booking_value) / nullif(sum(ride_distance_km), 0), 2) AS revenue_per_km
FROM mart.vw_bookings
GROUP BY pickup_location, drop_location
HAVING count(*) >= 15
ORDER BY revenue DESC
LIMIT 10;
