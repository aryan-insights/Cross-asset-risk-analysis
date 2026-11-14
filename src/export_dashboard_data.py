"""
export_dashboard_data.py
Exports everything the dashboard needs from PostgreSQL into ONE file: dashboard_data.json

It reuses the queries you already validated in analysis_with_findings.sql (Q1a to Q9),
plus the daily series behind the charts (growth, drawdown, rolling volatility,
rolling correlation, daily returns).

Setup:
    Put this file in the SAME folder as analysis_with_findings.sql
    pip install psycopg2-binary

Run (PowerShell), from that folder:
    $env:PG_PASSWORD = 'newpassword1234'
    python export_dashboard_data.py

Output: dashboard_data.json (same folder). Upload that file to the chat.
"""

import datetime as dt
import json
import os
import re
import sys
from decimal import Decimal
from pathlib import Path

import psycopg2

HERE = Path(__file__).resolve().parent
from config import BASE, PROCESSED

SQL_FILE = BASE / "sql" / "03_analysis.sql"
OUT_FILE = PROCESSED / "dashboard_data.json"

DB = {
    "host": os.getenv("PG_HOST", "localhost"),
    "port": os.getenv("PG_PORT", "5432"),
    "dbname": os.getenv("PG_DB", "cross_asset_risk"),
    "user": os.getenv("PG_USER", "postgres"),
    "password": os.getenv("PG_PASSWORD"),
}

ASSETS = ["BTC", "GOLD", "NIFTY"]

# Which analysis query feeds which part of the JSON
QUERY_KEYS = {
    "Q1a": "data_quality",
    "Q1b": "common_days",
    "Q1c": "outlier_days",
    "Q2": "scorecard",
    "Q3a": "drawdown_events",
    "Q3b": "time_in_drawdown",
    "Q4": "yearly",
    "Q5a": "corr_full",
    "Q5b": "corr_yearly",
    "Q5c": "corr_weekly",
    "Q5d": "corr_rolling_summary",
    "Q6": "hedge_test",
    "Q7": "beta",
    "Q8": "portfolios",
    "Q9": "extreme_days",
}


# ---------------------------------------------------------------- helpers
def clean(v):
    if isinstance(v, Decimal):
        return float(v)
    if isinstance(v, (dt.date, dt.datetime)):
        return v.isoformat()[:10]
    return v


def run(cur, sql):
    cur.execute(sql)
    cols = [d[0] for d in cur.description]
    return [dict(zip(cols, (clean(v) for v in row))) for row in cur.fetchall()]


def split_sql_file(path):
    """Return (setup_sql, {query_id: sql}) from analysis_with_findings.sql.
    Comment lines are dropped, so the FINDING blocks never reach the database."""
    header = re.compile(r"^-- (Q\d[a-d]?)\. ")
    setup_lines, queries = [], {}
    cur_id, buf = None, []
    seen_first_header = False

    for line in path.read_text(encoding="utf-8").splitlines():
        m = header.match(line)
        if m:
            seen_first_header = True
            cur_id, buf = m.group(1), []
            continue
        stripped = line.strip()
        if stripped.startswith("--"):
            continue
        if not seen_first_header:
            setup_lines.append(line)
            continue
        if cur_id is None or (not stripped and not buf):
            continue
        buf.append(line)
        if stripped.endswith(";"):
            queries[cur_id] = "\n".join(buf).rstrip().rstrip(";")
            cur_id, buf = None, []

    return "\n".join(setup_lines), queries


def r(x, nd):
    return None if x is None else round(float(x), nd)


def build_series(cur):
    """Daily series on COMMON trading days, one array per asset per metric."""
    prices = run(cur, "SELECT price_date, btc, gold, nifty FROM v_common_prices ORDER BY price_date")
    dates = [p["price_date"] for p in prices]
    idx = {d: i for i, d in enumerate(dates)}
    n = len(dates)

    def empty():
        return {a: [None] * n for a in ASSETS}

    series = {
        "dates": dates,
        "close": {a: [r(p[a.lower()], 4) for p in prices] for a in ASSETS},
        "ret": empty(),
        "wealth": empty(),
        "drawdown": empty(),
        "vol30": empty(),
        "vol90": empty(),
        "corr90": {k: [None] * n for k in ("BTC_GOLD", "BTC_NIFTY", "GOLD_NIFTY")},
    }

    # first common day is the base: wealth 1.0, drawdown 0
    for a in ASSETS:
        series["wealth"][a][0] = 1.0
        series["drawdown"][a][0] = 0.0

    for row in run(cur, "SELECT price_date, btc, gold, nifty FROM v_common_returns ORDER BY price_date"):
        i = idx[row["price_date"]]
        for a in ASSETS:
            series["ret"][a][i] = r(row[a.lower()], 6)

    for row in run(cur, "SELECT price_date, asset_code, wealth_index, drawdown FROM v_drawdown"):
        i = idx[row["price_date"]]
        series["wealth"][row["asset_code"]][i] = r(row["wealth_index"], 5)
        series["drawdown"][row["asset_code"]][i] = r(row["drawdown"], 5)

    for row in run(cur, "SELECT price_date, asset_code, vol_30d, vol_90d FROM v_rolling_volatility"):
        i = idx[row["price_date"]]
        series["vol30"][row["asset_code"]][i] = r(row["vol_30d"], 5)
        series["vol90"][row["asset_code"]][i] = r(row["vol_90d"], 5)

    for row in run(cur, "SELECT price_date, btc_gold_90d, btc_nifty_90d, gold_nifty_90d FROM v_rolling_correlation"):
        i = idx[row["price_date"]]
        series["corr90"]["BTC_GOLD"][i] = r(row["btc_gold_90d"], 4)
        series["corr90"]["BTC_NIFTY"][i] = r(row["btc_nifty_90d"], 4)
        series["corr90"]["GOLD_NIFTY"][i] = r(row["gold_nifty_90d"], 4)

    return series


# ---------------------------------------------------------------- main
def main():
    if not DB["password"]:
        sys.exit("Set the PG_PASSWORD environment variable first.")
    if not SQL_FILE.exists():
        sys.exit(f"Cannot find {SQL_FILE.name} next to this script.")

    setup_sql, queries = split_sql_file(SQL_FILE)
    missing = [q for q in QUERY_KEYS if q not in queries]
    if missing:
        sys.exit(f"Could not find queries {missing} in {SQL_FILE.name}")

    conn = psycopg2.connect(**DB)
    try:
        with conn, conn.cursor() as cur:
            if setup_sql.strip():
                cur.execute(setup_sql)  # (re)creates the rolling-correlation views

            data = {}
            for qid, key in QUERY_KEYS.items():
                print(f"Running {qid} -> {key}")
                data[key] = run(cur, queries[qid])

            print("Building daily series ...")
            series = build_series(cur)
    finally:
        conn.close()

    out = {
        "meta": {
            "title": "Cross-Asset Risk Analysis: Bitcoin vs Gold vs NIFTY 50",
            "generated_at": dt.datetime.now().strftime("%Y-%m-%d %H:%M"),
            "data_as_of": series["dates"][-1],
            "first_date": series["dates"][0],
            "common_days": len(series["dates"]),
            "return_observations": len(series["dates"]) - 1,
            "annualization_days": 252,
            "risk_free_rate": 0,
            "return_type": "simple daily returns on common trading days",
            "source": "PostgreSQL views (v_common_prices, v_common_returns, v_drawdown, v_rolling_volatility, v_rolling_correlation)",
        },
        **data,
        "series": series,
    }

    OUT_FILE.write_text(json.dumps(out, separators=(",", ":")), encoding="utf-8")
    size_kb = OUT_FILE.stat().st_size / 1024
    print(f"\nWrote {OUT_FILE.name}: {size_kb:,.0f} KB, {len(series['dates'])} dates")


if __name__ == "__main__":
    main()
    
    