-- =============================================================================
-- 01_schemas.sql
-- Layered warehouse layout:
--   staging : raw CSV landed as text, truncated on every run
--   dw      : cleaned, typed star schema (dimensions + fact)
--   mart    : business-facing views consumed by Power BI
--   audit   : pipeline runs, rejected rows and data-quality results
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS staging;
CREATE SCHEMA IF NOT EXISTS dw;
CREATE SCHEMA IF NOT EXISTS mart;
CREATE SCHEMA IF NOT EXISTS audit;

COMMENT ON SCHEMA staging IS 'Raw landing zone. All columns are text; nothing is trusted yet.';
COMMENT ON SCHEMA dw      IS 'Typed star schema: dim_* tables and fact_bookings.';
COMMENT ON SCHEMA mart    IS 'Reporting views that mirror the Power BI dashboard pages.';
COMMENT ON SCHEMA audit   IS 'Pipeline run log, quarantined rows and data-quality results.';
