"""End-to-end pipeline: raw CSV -> PostgreSQL staging -> star schema -> data quality -> marts.

Usage:
    python etl/run_pipeline.py                 # build/refresh everything
    python etl/run_pipeline.py --rebuild       # drop all schemas first (clean slate)
    python etl/run_pipeline.py --csv other.csv # load a different extract

Connection settings come from the standard libpq variables (PGHOST, PGPORT,
PGUSER, PGPASSWORD) plus PGDATABASE (default: uber_analytics). A .env file in
the project root is read if present.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import logging
import os
import sys
from pathlib import Path

import psycopg
from psycopg import sql

ROOT = Path(__file__).resolve().parents[1]
SQL_DIR = ROOT / "sql"
DEFAULT_CSV = ROOT / "data" / "raw" / "uber_rides.csv"
PIPELINE_NAME = "uber_bookings"

# CSV header -> staging.raw_rides column, in file order.
COLUMN_MAP = {
    "Date": "ride_date",
    "Time": "pickup_time",
    "Booking ID": "booking_id",
    "Booking Status": "booking_status",
    "Customer ID": "customer_id",
    "Vehicle Type": "vehicle_type",
    "Pickup Location": "pickup_location",
    "Drop Location": "drop_location",
    "Cancelled Rides by Customer": "cancelled_by_customer",
    "Reason for cancelling by Customer": "customer_cancel_reason",
    "Cancelled Rides by Driver": "cancelled_by_driver",
    "Driver Cancellation Reason": "driver_cancel_reason",
    "Incomplete Rides": "incomplete_ride",
    "Incomplete Rides Reason": "incomplete_reason",
    "Booking Value": "booking_value",
    "Ride Distance": "ride_distance",
    "Driver Ratings": "driver_rating",
    "Customer Rating": "customer_rating",
    "Payment Method": "payment_method",
}

log = logging.getLogger("pipeline")


class DataQualityError(RuntimeError):
    pass


def load_dotenv(path: Path) -> None:
    """Minimal .env reader so the project has no extra dependency for config."""
    if not path.exists():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            os.environ.setdefault(key.strip(), value.strip().strip("'\""))


def database_name() -> str:
    return os.environ.get("PGDATABASE", "uber_analytics")


def ensure_database() -> None:
    """Create the target database if it does not exist yet."""
    dbname = database_name()
    with psycopg.connect(dbname="postgres", autocommit=True) as conn:
        exists = conn.execute("SELECT 1 FROM pg_database WHERE datname = %s", (dbname,)).fetchone()
        if not exists:
            conn.execute(sql.SQL("CREATE DATABASE {}").format(sql.Identifier(dbname)))
            log.info("created database %s", dbname)


def apply_ddl(conn: psycopg.Connection, rebuild: bool) -> None:
    # Idempotent DDL emits "already exists, skipping" notices on every run; hide them.
    conn.execute("SET client_min_messages = warning")
    if rebuild:
        log.warning("--rebuild: dropping schemas staging, dw, mart, audit")
        conn.execute("DROP SCHEMA IF EXISTS mart, dw, staging, audit CASCADE")
    for path in sorted(SQL_DIR.glob("[0-9][0-9]_*.sql")):
        log.info("applying %s", path.name)
        conn.execute(path.read_text(encoding="utf-8"))
    conn.execute("RESET client_min_messages")
    conn.commit()


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def check_header(csv_path: Path) -> None:
    with csv_path.open(newline="", encoding="utf-8") as fh:
        header = next(csv.reader(fh))
    if header != list(COLUMN_MAP):
        missing = set(COLUMN_MAP) - set(header)
        extra = set(header) - set(COLUMN_MAP)
        raise ValueError(f"unexpected CSV header; missing={sorted(missing)} extra={sorted(extra)}")


def start_run(conn: psycopg.Connection, csv_path: Path) -> int:
    run_id = conn.execute(
        """INSERT INTO audit.etl_runs (pipeline_name, source_file, source_sha256)
           VALUES (%s, %s, %s) RETURNING run_id""",
        (PIPELINE_NAME, csv_path.name, file_sha256(csv_path)),
    ).fetchone()[0]
    conn.commit()
    return run_id


def stage_csv(conn: psycopg.Connection, csv_path: Path) -> None:
    conn.execute("TRUNCATE staging.raw_rides RESTART IDENTITY")
    copy_sql = sql.SQL("COPY staging.raw_rides ({}) FROM STDIN WITH (FORMAT csv, HEADER true)").format(
        sql.SQL(", ").join(map(sql.Identifier, COLUMN_MAP.values()))
    )
    with conn.cursor() as cur, cur.copy(copy_sql) as copy, csv_path.open("rb") as fh:
        while chunk := fh.read(1 << 20):
            copy.write(chunk)


def fetch_dq_results(conn: psycopg.Connection, run_id: int) -> list[tuple]:
    return conn.execute(
        """SELECT check_name, severity, failed_rows, passed, description
           FROM audit.dq_results WHERE run_id = %s ORDER BY severity, check_name""",
        (run_id,),
    ).fetchall()


def record_failure(conn: psycopg.Connection, run_id: int, error: str, dq_rows: list[tuple]) -> None:
    conn.rollback()
    with conn.transaction():
        conn.cursor().executemany(
            """INSERT INTO audit.dq_results (run_id, check_name, severity, failed_rows, description)
               VALUES (%s, %s, %s, %s, %s)""",
            [(run_id, name, sev, failed, desc) for name, sev, failed, _, desc in dq_rows],
        )
        conn.execute(
            """UPDATE audit.etl_runs SET status = 'FAILED', finished_at = now(), error_message = %s
               WHERE run_id = %s""",
            (error[:2000], run_id),
        )


def ensure_powerbi_login(conn: psycopg.Connection) -> None:
    password = os.environ.get("POWERBI_DB_PASSWORD")
    if not password:
        return
    user = os.environ.get("POWERBI_DB_USER", "powerbi")
    exists = conn.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (user,)).fetchone()
    verb = "ALTER" if exists else "CREATE"
    conn.execute(sql.SQL(verb + " ROLE {} LOGIN PASSWORD {}").format(sql.Identifier(user), sql.Literal(password)))
    conn.execute(sql.SQL("GRANT bi_reader TO {}").format(sql.Identifier(user)))
    conn.commit()
    log.info("read-only login %s is ready for Power BI", user)


def print_summary(conn: psycopg.Connection, run_id: int) -> None:
    run = conn.execute(
        "SELECT rows_staged, rows_loaded, rows_rejected FROM audit.etl_runs WHERE run_id = %s", (run_id,)
    ).fetchone()
    log.info("run %s: staged=%s loaded=%s rejected=%s", run_id, *run)
    for name, severity, failed, passed, _ in fetch_dq_results(conn, run_id):
        log.info("  DQ %-5s %-28s %s", severity, name, "PASS" if passed else f"{failed} rows")
    cur = conn.execute("SELECT * FROM mart.vw_kpi_overview")
    for col, value in zip((d.name for d in cur.description), cur.fetchone()):
        log.info("  KPI %-26s %s", col, value)


def run(csv_path: Path, rebuild: bool) -> int:
    check_header(csv_path)
    ensure_database()
    with psycopg.connect(dbname=database_name()) as conn:
        conn.add_notice_handler(lambda diag: log.info("postgres: %s", diag.message_primary))
        apply_ddl(conn, rebuild)
        run_id = start_run(conn, csv_path)
        log.info("started run %s for %s", run_id, csv_path.name)
        dq_rows: list[tuple] = []
        try:
            # Staging, load and DQ share one transaction: an ERROR check rolls all of it back.
            stage_csv(conn, csv_path)
            conn.execute("CALL dw.sp_load_bookings(%s)", (run_id,))
            conn.execute("CALL audit.sp_run_dq_checks(%s)", (run_id,))
            dq_rows = fetch_dq_results(conn, run_id)
            failed = [r for r in dq_rows if r[1] == "ERROR" and not r[3]]
            if failed:
                raise DataQualityError("blocking DQ checks failed: " + ", ".join(r[0] for r in failed))
            conn.execute("REFRESH MATERIALIZED VIEW mart.mv_daily_kpis")
            conn.execute(
                "UPDATE audit.etl_runs SET status = 'SUCCESS', finished_at = now() WHERE run_id = %s",
                (run_id,),
            )
            conn.commit()
        except Exception as exc:
            log.error("run %s failed: %s", run_id, exc)
            record_failure(conn, run_id, str(exc), dq_rows)
            return 1
        ensure_powerbi_login(conn)
        print_summary(conn, run_id)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--csv", type=Path, default=DEFAULT_CSV, help="source extract (default: %(default)s)")
    parser.add_argument("--rebuild", action="store_true", help="drop and recreate all schemas first")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)-7s %(message)s", datefmt="%H:%M:%S")
    load_dotenv(ROOT / ".env")
    return run(args.csv.resolve(), args.rebuild)


if __name__ == "__main__":
    sys.exit(main())
