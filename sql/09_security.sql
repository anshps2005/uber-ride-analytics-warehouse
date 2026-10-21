-- =============================================================================
-- 09_security.sql
-- Least-privilege access for reporting tools: the bi_reader role can read the
-- mart layer only. Views execute with their owner's rights, so readers never
-- need (or get) access to staging, dw or audit.
--
-- Create a login for Power BI with, e.g.:
--   CREATE ROLE powerbi LOGIN PASSWORD '<strong password>' IN ROLE bi_reader;
-- (run_pipeline.py does this automatically when POWERBI_DB_PASSWORD is set.)
-- =============================================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bi_reader') THEN
        CREATE ROLE bi_reader NOLOGIN;
    END IF;
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO bi_reader', current_database());
END
$$;

REVOKE ALL ON SCHEMA staging, dw, audit FROM PUBLIC;

GRANT USAGE  ON SCHEMA mart TO bi_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA mart TO bi_reader;
