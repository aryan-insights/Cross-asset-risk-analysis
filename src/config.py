from pathlib import Path

# Project root = the folder above src/
BASE = Path(__file__).resolve().parent.parent
RAW = BASE / "data" / "raw"
CLEAN = BASE / "data" / "clean"
PROCESSED = BASE / "data" / "processed"

START_DATE = "2015-01-01"

ASSETS = {
    "BTC":   {"ticker": "BTC-USD", "raw_file": "BTC-USD.csv"},
    "GOLD":  {"ticker": "GC=F",    "raw_file": "GOLD-GC-F.csv"},
    "NIFTY": {"ticker": "^NSEI",   "raw_file": "NIFTY50-NSEI.csv"},
}