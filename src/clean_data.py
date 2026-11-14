import pandas as pd
from config import RAW, CLEAN, ASSETS

CLEAN.mkdir(exist_ok=True)

def clean(asset, raw_file):
    df = pd.read_csv(RAW / raw_file)

    # Keep only the calendar date (drop time and timezone)
    df["Date"] = pd.to_datetime(df["Date"].str[:10])

    # Drop columns with no information for these assets
    df = df.drop(columns=["Adj Close", "Dividends", "Stock Splits"])

    # SQL-friendly names
    df.columns = ["date", "open", "high", "low", "close", "volume"]
    df.insert(0, "asset", asset)
    df = df.sort_values("date").reset_index(drop=True)

    # Quality checks
    checks = {
        "duplicate dates": int(df["date"].duplicated().sum()),
        "null values": int(df.isna().sum().sum()),
        "close <= 0": int((df["close"] <= 0).sum()),
        "high < low": int((df["high"] < df["low"]).sum()),
    }
    print(f"--- {asset} ---")
    print("rows:", len(df), "| range:", df["date"].min().date(), "to", df["date"].max().date())
    for name, count in checks.items():
        print(f"{name}: {count}")
    print()

    if any(checks.values()):
        raise ValueError(f"{asset}: data quality checks failed, investigate before continuing")

    df.to_csv(CLEAN / f"{asset}_clean.csv", index=False)

if __name__ == "__main__":
    for asset, info in ASSETS.items():
        clean(asset, info["raw_file"])