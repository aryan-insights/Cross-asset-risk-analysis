"""
load_prices.py
Loads BTC_clean.csv, GOLD_clean.csv and NIFTY_clean.csv into the fact_prices table.

Setup (once):
    pip install pandas psycopg2-binary

Run (PowerShell):
    $env:PG_PASSWORD = "your_postgres_password"
    python load_prices.py

Safe to re-run: rows are upserted on (price_date, asset_id), so no duplicates.
"""

import os
import sys
from pathlib import Path

import pandas as pd
import psycopg2
from psycopg2.extras import execute_values

# ---------------------------------------------------------------- config
from config import CLEAN

CLEAN_DIR = CLEAN

FILES = {                      # asset_code -> file name
    "BTC": "BTC_clean.csv",
    "GOLD": "GOLD_clean.csv",
    "NIFTY": "NIFTY_clean.csv",
}

DB = {
    "host": os.getenv("PG_HOST", "localhost"),
    "port": os.getenv("PG_PORT", "5432"),
    "dbname": os.getenv("PG_DB", "cross_asset_risk"),
    "user": os.getenv("PG_USER", "postgres"),
    "password": os.getenv("PG_PASSWORD"),   # never hard-code passwords in code you push to GitHub
}

REQUIRED_COLS = ["asset", "date", "open", "high", "low", "close", "volume"]


# ---------------------------------------------------------------- helpers
def parse_dates(series: pd.Series) -> pd.Series:
    """Your CSVs use DD-MM-YYYY. Try that first, then ISO. Fail loudly if neither works."""
    for fmt in ("%d-%m-%Y", "%Y-%m-%d"):
        try:
            return pd.to_datetime(series, format=fmt)
        except (ValueError, TypeError):
            continue
    raise ValueError("Dates are not in DD-MM-YYYY or YYYY-MM-DD format")


def num(x, cast=float):
    """Convert to a Python number, or None if missing (psycopg2 can't handle numpy/NaN)."""
    return None if pd.isna(x) else cast(x)


def read_and_validate(asset_code: str, filename: str) -> pd.DataFrame:
    path = CLEAN_DIR / filename
    df = pd.read_csv(path)
    df.columns = [c.strip().lower() for c in df.columns]

    missing = [c for c in REQUIRED_COLS if c not in df.columns]
    if missing:
        raise ValueError(f"{filename}: missing columns {missing}")

    df["date"] = parse_dates(df["date"])

    # --- data quality checks (these are the start of a real pipeline's validation layer)
    dupes = df.duplicated(subset=["date"]).sum()
    if dupes:
        print(f"  [warn] {filename}: dropping {dupes} duplicate dates")
        df = df.drop_duplicates(subset=["date"], keep="last")

    if df["close"].isna().any():
        raise ValueError(f"{filename}: null values in close")
    if (df["close"] <= 0).any():
        raise ValueError(f"{filename}: non-positive close prices found")
    if (df["high"] < df["low"]).any():
        raise ValueError(f"{filename}: rows where high < low")

    file_codes = set(df["asset"].astype(str).str.strip().str.upper())
    if file_codes != {asset_code}:
        print(f"  [warn] {filename}: 'asset' column has {file_codes}, expected {{'{asset_code}'}}")

    return df.sort_values("date").reset_index(drop=True)


# ---------------------------------------------------------------- main
def main() -> None:
    if not DB["password"]:
        sys.exit("Set the PG_PASSWORD environment variable first.")

    conn = psycopg2.connect(**DB)
    try:
        with conn, conn.cursor() as cur:       # 'with conn' = one transaction, rolled back on error
            cur.execute("SELECT asset_code, asset_id FROM dim_asset")
            asset_ids = dict(cur.fetchall())

            for asset_code, filename in FILES.items():
                print(f"Loading {filename} ...")
                if asset_code not in asset_ids:
                    raise ValueError(f"{asset_code} not found in dim_asset. Did you run schema.sql?")

                df = read_and_validate(asset_code, filename)
                asset_id = asset_ids[asset_code]

                rows = [
                    (
                        r.date.date(),
                        asset_id,
                        num(r.open),
                        num(r.high),
                        num(r.low),
                        num(r.close),
                        num(r.volume, lambda v: int(round(v))),
                    )
                    for r in df.itertuples(index=False)
                ]

                execute_values(
                    cur,
                    """
                    INSERT INTO fact_prices
                        (price_date, asset_id, open_price, high_price, low_price, close_price, volume)
                    VALUES %s
                    ON CONFLICT (price_date, asset_id) DO UPDATE SET
                        open_price  = EXCLUDED.open_price,
                        high_price  = EXCLUDED.high_price,
                        low_price   = EXCLUDED.low_price,
                        close_price = EXCLUDED.close_price,
                        volume      = EXCLUDED.volume
                    """,
                    rows,
                    page_size=1000,
                )
                print(f"  {len(rows)} rows upserted "
                      f"({df['date'].min().date()} to {df['date'].max().date()})")
    finally:
        conn.close()

    print("Done.")


if __name__ == "__main__":
    main()
    
    