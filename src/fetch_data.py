import time
import yfinance as yf
from config import RAW, ASSETS, START_DATE

RAW.mkdir(exist_ok=True)

def fetch(asset, info, retries=3):
    for attempt in range(1, retries + 1):
        try:
            df = yf.Ticker(info["ticker"]).history(start=START_DATE, auto_adjust=False)
            if df.empty:
                raise ValueError("no data returned")
            df.to_csv(RAW / info["raw_file"])
            print(f"{asset}: {len(df)} rows, "
                  f"{df.index.min().date()} to {df.index.max().date()}")
            return
        except Exception as e:
            print(f"{asset}: attempt {attempt} failed ({e})")
            time.sleep(3)
    raise RuntimeError(f"Could not download {asset} after {retries} attempts")

if __name__ == "__main__":
    for asset, info in ASSETS.items():
        fetch(asset, info)