"""Reconciliation and integrity tests for the PostgreSQL warehouse.

The expected values are computed independently with pandas straight from the
raw CSV, so a bug in the SQL transformations shows up as a mismatch.
Run the pipeline first:  python etl/run_pipeline.py  then  pytest
"""

from __future__ import annotations

import os
import sys
from decimal import Decimal
from pathlib import Path

import pandas as pd
import psycopg
import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "etl"))
from run_pipeline import DEFAULT_CSV, load_dotenv  # noqa: E402

load_dotenv(ROOT / ".env")


@pytest.fixture(scope="session")
def conn():
    try:
        connection = psycopg.connect(dbname=os.environ.get("PGDATABASE", "uber_analytics"))
    except psycopg.OperationalError as exc:
        pytest.skip(f"PostgreSQL not reachable: {exc}")
    yield connection
    connection.close()


@pytest.fixture(scope="session")
def raw() -> pd.DataFrame:
    return pd.read_csv(DEFAULT_CSV, dtype={"Booking ID": str, "Customer ID": str}, low_memory=False)


def one(conn, query: str):
    cur = conn.execute(query)
    row = cur.fetchone()
    return dict(zip((d.name for d in cur.description), row))


def test_latest_run_succeeded(conn):
    run = one(conn, "SELECT * FROM audit.etl_runs ORDER BY run_id DESC LIMIT 1")
    assert run["status"] == "SUCCESS"
    assert run["rows_staged"] == run["rows_loaded"] + run["rows_rejected"]


def test_no_blocking_dq_failures(conn):
    failed = conn.execute(
        """SELECT check_name FROM audit.dq_results
           WHERE run_id = (SELECT max(run_id) FROM audit.etl_runs WHERE status = 'SUCCESS')
             AND severity = 'ERROR' AND NOT passed"""
    ).fetchall()
    assert failed == []


def test_overview_kpis_match_raw_csv(conn, raw):
    kpi = one(conn, "SELECT * FROM mart.vw_kpi_overview")
    completed = raw["Booking Status"] == "Completed"
    assert kpi["total_rides"] == len(raw)
    assert kpi["total_bookings"] == raw["Booking ID"].nunique()
    assert kpi["completed_bookings"] == raw.loc[completed, "Booking ID"].nunique()
    assert kpi["lost_bookings"] == raw.loc[~completed, "Booking ID"].nunique()
    assert kpi["total_customers"] == raw["Customer ID"].nunique()
    assert kpi["total_revenue"] == Decimal(str(raw["Booking Value"].sum()))
    assert float(kpi["total_distance_km"]) == pytest.approx(raw["Ride Distance"].sum(), abs=0.01)
    assert float(kpi["avg_distance_km"]) == pytest.approx(raw["Ride Distance"].mean(), abs=0.005)


def test_kpis_match_published_dashboard(conn):
    """Totals visible on the Power BI report (Customer page detail table and cards)."""
    kpi = one(conn, "SELECT * FROM mart.vw_kpi_overview")
    assert kpi["total_revenue"] == Decimal("51846183")
    assert kpi["completed_bookings"] == 92551
    assert kpi["lost_bookings"] == 56817
    cancel = one(conn, "SELECT * FROM mart.vw_customer_cancellation_kpis")
    assert cancel["customer_cancellation_rate_pct"] == Decimal("7.00")
    assert cancel["top_customer_cancellation_reason"] == "Wrong Address"
    assert round(cancel["customer_cancelled_revenue_impact"] / Decimal("1e6"), 2) == Decimal("5.34")


def test_customer_segments_match_raw_csv(conn, raw):
    completed_per_customer = (
        raw.assign(done=raw["Booking Status"].eq("Completed")).groupby("Customer ID")["done"].sum()
    )
    expected = {
        "No Completed Ride": int((completed_per_customer == 0).sum()),
        "First Time": int((completed_per_customer == 1).sum()),
        "Returning": int((completed_per_customer == 2).sum()),
        "Regular": int((completed_per_customer >= 3).sum()),
    }
    actual = dict(conn.execute("SELECT customer_segment, customers FROM mart.vw_customer_segments").fetchall())
    assert actual == expected


def test_vehicle_contribution_sums_to_100(conn):
    total = conn.execute("SELECT sum(revenue_contribution_pct) FROM mart.vw_vehicle_performance").fetchone()[0]
    assert float(total) == pytest.approx(100, abs=0.05)
    groups = {r[0] for r in conn.execute("SELECT vehicle_group FROM mart.vw_vehicle_performance")}
    assert "eBike" not in groups and "Bike" in groups


def test_monthly_revenue_matches_raw_csv(conn, raw):
    expected = raw.groupby(pd.to_datetime(raw["Date"]).dt.month)["Booking Value"].sum()
    actual = dict(conn.execute("SELECT month_no, revenue FROM mart.vw_monthly_trend").fetchall())
    for month, revenue in expected.items():
        assert float(actual[month]) == pytest.approx(revenue, abs=0.01)


def test_every_ride_lands_in_one_heatmap_cell(conn, raw):
    assert conn.execute("SELECT sum(rides) FROM mart.vw_demand_heatmap").fetchone()[0] == len(raw)
    slots = conn.execute("SELECT count(DISTINCT time_slot_label) FROM mart.vw_demand_heatmap").fetchone()[0]
    assert slots == 8


def test_materialized_view_is_populated(conn, raw):
    assert conn.execute("SELECT sum(rides) FROM mart.mv_daily_kpis").fetchone()[0] == len(raw)


def test_bi_reader_cannot_see_internal_schemas(conn):
    rows = conn.execute(
        """SELECT has_schema_privilege('bi_reader', 'mart', 'USAGE'),
                  has_table_privilege('bi_reader', 'mart.vw_bookings', 'SELECT'),
                  has_schema_privilege('bi_reader', 'dw', 'USAGE'),
                  has_schema_privilege('bi_reader', 'staging', 'USAGE'),
                  has_schema_privilege('bi_reader', 'audit', 'USAGE')"""
    ).fetchone()
    assert rows == (True, True, False, False, False)
