-- =============================================================================
-- 02_audit.sql
-- Operational metadata: every pipeline run, every rejected row, every DQ check.
-- =============================================================================

CREATE TABLE IF NOT EXISTS audit.etl_runs (
    run_id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pipeline_name   text        NOT NULL,
    source_file     text        NOT NULL,
    source_sha256   char(64)    NOT NULL,
    started_at      timestamptz NOT NULL DEFAULT now(),
    finished_at     timestamptz,
    status          text        NOT NULL DEFAULT 'RUNNING'
                    CHECK (status IN ('RUNNING', 'SUCCESS', 'FAILED')),
    rows_staged     integer,
    rows_loaded     integer,
    rows_rejected   integer,
    error_message   text
);

CREATE TABLE IF NOT EXISTS audit.rejected_rows (
    run_id          bigint      NOT NULL REFERENCES audit.etl_runs (run_id),
    source_row_num  bigint      NOT NULL,
    booking_id      text,
    reject_reason   text        NOT NULL,
    raw_record      jsonb       NOT NULL,
    rejected_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (run_id, source_row_num)
);

CREATE TABLE IF NOT EXISTS audit.dq_results (
    run_id          bigint      NOT NULL REFERENCES audit.etl_runs (run_id),
    check_name      text        NOT NULL,
    severity        text        NOT NULL CHECK (severity IN ('ERROR', 'WARN')),
    failed_rows     bigint      NOT NULL,
    passed          boolean     GENERATED ALWAYS AS (failed_rows = 0) STORED,
    description     text        NOT NULL,
    checked_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (run_id, check_name)
);
