-- Phase 3: returns and risk metrics, all in SQL
-- Run in pgAdmin Query Tool on the cross_asset_risk database.
-- Every statement is CREATE OR REPLACE, so it is safe to re-run.

-- ---------------------------------------------------------------
-- 1) Closing prices side by side, only on days ALL three markets traded
--    (same logic as your combined_prices.csv)
-- ---------------------------------------------------------------
CREATE OR REPLACE VIEW v_common_prices AS
SELECT
    p.price_date,
    MAX(CASE WHEN a.asset_code = 'BTC'   THEN p.close_price END) AS btc,
    MAX(CASE WHEN a.asset_code = 'GOLD'  THEN p.close_price END) AS gold,
    MAX(CASE WHEN a.asset_code = 'NIFTY' THEN p.close_price END) AS nifty
FROM fact_prices p
JOIN dim_asset a USING (asset_id)
GROUP BY p.price_date
HAVING COUNT(*) = 3;

-- ---------------------------------------------------------------
-- 2) Daily simple returns on those common days
--    (same logic as your combined_returns.csv; first day is dropped
--     because it has no previous day)
-- ---------------------------------------------------------------
CREATE OR REPLACE VIEW v_common_returns AS
SELECT price_date, btc, gold, nifty
FROM (
    SELECT
        price_date,
        btc   / LAG(btc)   OVER w - 1 AS btc,
        gold  / LAG(gold)  OVER w - 1 AS gold,
        nifty / LAG(nifty) OVER w - 1 AS nifty
    FROM v_common_prices
    WINDOW w AS (ORDER BY price_date)
) t
WHERE btc IS NOT NULL;

-- ---------------------------------------------------------------
-- 3) Same returns in "long" format (one row per asset per day),
--    which makes per-asset window functions easy
-- ---------------------------------------------------------------
CREATE OR REPLACE VIEW v_returns_long AS
SELECT price_date, 'BTC'   AS asset_code, btc   AS ret FROM v_common_returns
UNION ALL
SELECT price_date, 'GOLD'  AS asset_code, gold  AS ret FROM v_common_returns
UNION ALL
SELECT price_date, 'NIFTY' AS asset_code, nifty AS ret FROM v_common_returns;

-- ---------------------------------------------------------------
-- 4) Rolling annualized volatility (30 and 90 trading days)
--    252 = trading days per year (valid because the series only has market days)
-- ---------------------------------------------------------------
CREATE OR REPLACE VIEW v_rolling_volatility AS
SELECT
    price_date,
    asset_code,
    CASE WHEN COUNT(*) OVER w30 = 30
         THEN STDDEV_SAMP(ret) OVER w30 * SQRT(252) END AS vol_30d,
    CASE WHEN COUNT(*) OVER w90 = 90
         THEN STDDEV_SAMP(ret) OVER w90 * SQRT(252) END AS vol_90d
FROM v_returns_long
WINDOW
    w30 AS (PARTITION BY asset_code ORDER BY price_date ROWS BETWEEN 29 PRECEDING AND CURRENT ROW),
    w90 AS (PARTITION BY asset_code ORDER BY price_date ROWS BETWEEN 89 PRECEDING AND CURRENT ROW);

-- ---------------------------------------------------------------
-- 5) Drawdown: how far each asset is below its previous peak
--    wealth = growth of 1 unit invested on day one
-- ---------------------------------------------------------------
CREATE OR REPLACE VIEW v_drawdown AS
WITH wealth AS (
    SELECT
        price_date,
        asset_code,
        EXP(SUM(LN(1 + ret)) OVER (PARTITION BY asset_code ORDER BY price_date)) AS wealth_index
    FROM v_returns_long
),
peaks AS (
    SELECT
        *,
        GREATEST(1, MAX(wealth_index) OVER (PARTITION BY asset_code ORDER BY price_date)) AS peak_index
    FROM wealth
)
SELECT
    price_date,
    asset_code,
    wealth_index,
    peak_index,
    wealth_index / peak_index - 1 AS drawdown
FROM peaks;

-- ---------------------------------------------------------------
-- 6) One-row-per-asset risk summary
--    Sharpe uses a 0% risk-free rate to keep it simple; you can
--    subtract a risk-free rate later.
--    VaR 95% = the 5th-percentile daily return (historical method)
-- ---------------------------------------------------------------
CREATE OR REPLACE VIEW v_risk_summary AS
SELECT
    r.asset_code,
    COUNT(*)                                          AS trading_days,
    AVG(r.ret) * 252                                  AS ann_return,
    STDDEV_SAMP(r.ret) * SQRT(252)                    AS ann_volatility,
    (AVG(r.ret) * 252) / (STDDEV_SAMP(r.ret) * SQRT(252)) AS sharpe_rf0,
    PERCENTILE_CONT(0.05) WITHIN GROUP (ORDER BY r.ret)   AS var_95_1day,
    d.max_drawdown
FROM v_returns_long r
JOIN (
    SELECT asset_code, MIN(drawdown) AS max_drawdown
    FROM v_drawdown
    GROUP BY asset_code
) d ON d.asset_code = r.asset_code
GROUP BY r.asset_code, d.max_drawdown;

-- ---------------------------------------------------------------
-- 7) Correlation between the assets' daily returns
-- ---------------------------------------------------------------
CREATE OR REPLACE VIEW v_correlation AS
SELECT
    CORR(btc, gold)   AS btc_gold,
    CORR(btc, nifty)  AS btc_nifty,
    CORR(gold, nifty) AS gold_nifty
FROM v_common_returns;

-- ---------------------------------------------------------------
-- Checks to run after creating the views
-- ---------------------------------------------------------------
-- a) Should match the first data row of combined_returns.csv:
--    btc -0.12874, gold 0.015093, nifty -0.00203
-- SELECT * FROM v_common_returns ORDER BY price_date LIMIT 3;
--
-- b) Row count should equal the number of data rows in combined_returns.csv
--    (Excel shows rows including the header, so subtract 1)
-- SELECT COUNT(*) FROM v_common_returns;
--
-- c) The results
SELECT * FROM v_risk_summary;
SELECT * FROM v_correlation;

-- WORST DRAWBACKS HAPPENED
SELECT DISTINCT ON (asset_code) asset_code, price_date AS trough_date, drawdown
FROM v_drawdown
ORDER BY asset_code, drawdown;

-- the real compounded return (CAGR):
WITH trough AS (
    SELECT DISTINCT ON (asset_code) asset_code, price_date AS trough_date, peak_index
    FROM v_drawdown
    ORDER BY asset_code, drawdown
)
SELECT t.asset_code, MAX(d.price_date) AS peak_date, t.trough_date
FROM trough t
JOIN v_drawdown d
  ON d.asset_code = t.asset_code
 AND d.price_date <= t.trough_date
 AND d.wealth_index = t.peak_index
GROUP BY t.asset_code, t.trough_date;