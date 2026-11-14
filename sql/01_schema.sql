-- Cross-Asset Risk Analysis: Bitcoin vs Gold vs NIFTY 50
-- psql -U postgres -d cross_asset_risk -f schema.sql
-- Safe to re-run: every statement is idempotent.

-- 1) Dimension table: one row per asset
CREATE TABLE IF NOT EXISTS dim_asset (
    asset_id    SERIAL       PRIMARY KEY,
    asset_code  VARCHAR(10)  NOT NULL UNIQUE, 
    asset_name  VARCHAR(50)  NOT NULL,
    asset_class VARCHAR(20)  NOT NULL,          
    currency    CHAR(3)      NOT NULL           
);

-- 2) Fact table: one row per asset per trading day
CREATE TABLE IF NOT EXISTS fact_prices (
    price_date  DATE           NOT NULL,
    asset_id    INT            NOT NULL REFERENCES dim_asset (asset_id),
    open_price  NUMERIC(18, 6),
    high_price  NUMERIC(18, 6),
    low_price   NUMERIC(18, 6),
    close_price NUMERIC(18, 6) NOT NULL,
    volume      BIGINT,
    PRIMARY KEY (price_date, asset_id),         
    CHECK (close_price > 0),
    CHECK (high_price >= low_price)
);

-- Window functions (LAG, rolling averages) partition by asset and order by date,
-- so an index in that order helps later.
CREATE INDEX IF NOT EXISTS idx_fact_prices_asset_date
    ON fact_prices (asset_id, price_date);

-- 3) Seed the dimension table
INSERT INTO dim_asset (asset_code, asset_name, asset_class, currency) VALUES
    ('BTC',   'Bitcoin',  'crypto',    'USD'),
    ('GOLD',  'Gold',     'commodity', 'USD'),
    ('NIFTY', 'NIFTY 50', 'index',     'INR')
ON CONFLICT (asset_code) DO NOTHING;

