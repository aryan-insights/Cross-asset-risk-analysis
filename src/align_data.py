import pandas as pd
from config import CLEAN, ASSETS

series = []
for asset in ASSETS:
    df = pd.read_csv(CLEAN / f"{asset}_clean.csv", parse_dates=["date"])
    series.append(df.set_index("date")["close"].rename(asset.lower()))

# Keep only dates where all three assets traded
prices = pd.concat(series, axis=1, join="inner").sort_index()
returns = prices.pct_change().dropna()

print("shared trading days:", len(prices))
print(prices.head(), "\n")
print(prices.tail(), "\n")
print(returns.describe())

prices.to_csv(CLEAN / "combined_prices.csv")
returns.to_csv(CLEAN / "combined_returns.csv")