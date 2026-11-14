-- =====================================================================
-- Cross-Asset Risk Analysis: Bitcoin vs Gold vs NIFTY 50
-- analysis.sql  (Phase 3, complete analysis)
--
-- Requires: schema.sql, load_prices.py and returns_and_risk.sql already run.
-- Each numbered query is standalone. In pgAdmin, select ONE query (from its
-- header comment to its semicolon) and press F5. Do not run the whole
-- file at once, because pgAdmin only shows the last result.
--
-- Conventions:
--   * Returns are simple daily returns on COMMON trading days (all 3 markets open).
--   * Annualized with 252 trading days.
--   * Sharpe/Sortino use a 0% risk-free rate.
--   * Results are in % unless the column name says otherwise.
-- =====================================================================


-- ---------------------------------------------------------------------
-- SETUP run on: rolling 90-day correlation views
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_rolling_correlation AS
SELECT
    price_date,
    CASE WHEN COUNT(*) OVER w = 90 THEN CORR(btc, gold)   OVER w END AS btc_gold_90d,
    CASE WHEN COUNT(*) OVER w = 90 THEN CORR(btc, nifty)  OVER w END AS btc_nifty_90d,
    CASE WHEN COUNT(*) OVER w = 90 THEN CORR(gold, nifty) OVER w END AS gold_nifty_90d
FROM v_common_returns
WINDOW w AS (ORDER BY price_date ROWS BETWEEN 89 PRECEDING AND CURRENT ROW);

CREATE OR REPLACE VIEW v_rolling_correlation_long AS
SELECT price_date, 'BTC vs Gold'   AS pair, btc_gold_90d   AS corr_90d FROM v_rolling_correlation WHERE btc_gold_90d   IS NOT NULL
UNION ALL
SELECT price_date, 'BTC vs NIFTY'  AS pair, btc_nifty_90d  AS corr_90d FROM v_rolling_correlation WHERE btc_nifty_90d  IS NOT NULL
UNION ALL
SELECT price_date, 'Gold vs NIFTY' AS pair, gold_nifty_90d AS corr_90d FROM v_rolling_correlation WHERE gold_nifty_90d IS NOT NULL;


-- =====================================================================
-- Q1a. DATA QUALITY: rows and date range per asset (raw table)
-- Expectation : BTC has the most rows (trades 7 days a week).
-- =====================================================================
SELECT
    a.asset_code,
    COUNT(*)          AS total_rows,
    MIN(f.price_date) AS first_date,
    MAX(f.price_date) AS last_date,
    COUNT(*) FILTER (WHERE f.volume IS NULL OR f.volume = 0) AS rows_with_zero_or_null_volume
FROM fact_prices f
JOIN dim_asset a USING (asset_id)
GROUP BY a.asset_code
ORDER BY a.asset_code;

-- ---------------------------------------------------------------------
-- FINDING (Q1a): data coverage and quality
-- Run on: data as of 2026-10-22
--
--   asset   rows    first_date   last_date    zero/null volume rows
--   BTC     4,313   2015-01-01   2026-10-22   0
--   GOLD    2,969   2015-01-02   2026-10-22   36
--   NIFTY   2,905   2015-01-02   2026-10-22   29
--
-- 1. Row counts match what load_prices.py inserted, so nothing was lost in loading.
-- 2. BTC has the most rows because it trades 7 days a week; gold and NIFTY
--    only trade on market days.
-- 3. BTC starts 1 day earlier because 1 Jan is a market holiday for gold/NIFTY.
-- 4. 36 gold rows and 29 NIFTY rows have zero volume. Volume is not used in
--    any return, risk or drawdown calculation (all use close_price), so the
--    results are not affected.
-- 5. All three series end on the same date (2026-10-22).
-- ---------------------------------------------------------------------

-- =====================================================================
-- Q1b. DATA QUALITY: the common-days dataset all risk numbers are built on
-- longest_gap_days is usually 4 to 5 (long weekend + holidays).
-- =====================================================================
SELECT
    COUNT(*)        AS common_days,
    MIN(price_date) AS first_date,
    MAX(price_date) AS last_date,
    MAX(gap)        AS longest_gap_days
FROM (
    SELECT price_date,
           price_date - LAG(price_date) OVER (ORDER BY price_date) AS gap
    FROM v_common_prices
) t;

-- ---------------------------------------------------------------------
-- FINDING (Q1b): common-days dataset used for all risk calculations
-- Run on: data as of 2026-10-22
--
--   common_days   first_date   last_date    longest_gap_days
--   2,819         2015-01-02   2026-10-22   6
--
-- 1. 2,819 days have a price for ALL three assets. Daily returns need a
--    previous day, so this gives 2,818 return observations (matches
--    v_risk_summary.trading_days and combined_returns.csv).
-- 2. The window starts on 2015-01-02 because gold and NIFTY begin that day.
-- 3. Longest gap between common days is 6 calendar days (weekend plus
--    stacked holidays across the Indian and US calendars). Gap dates
--    to be confirmed with the gap query.
-- ---------------------------------------------------------------------


-- =====================================================================
-- Q1c. DATA QUALITY: suspicious daily moves (possible bad data points)
-- A single-day move over 25% is rare for gold/NIFTY. Check any hits manually.
-- =====================================================================
SELECT asset_code, price_date, ROUND(ret * 100, 2) AS ret_pct
FROM v_returns_long
WHERE ABS(ret) > 0.25
ORDER BY ABS(ret) DESC;

-- ---------------------------------------------------------------------
-- FINDING (Q1c): suspicious daily moves (|return| > 25%)
-- Run on: data as of 2026-10-22
--
--   asset   price_date   ret_pct
--   BTC     2020-03-12   -37.17
--   BTC     2017-12-07   +25.25
--
-- 1. Only 2 observations out of 2,818 exceed the 25% threshold, both BTC.
-- 2. Both fall on known market events (COVID crash in March 2020; the
--    late-2017 crypto bubble run-up) and are single-day moves, so they are
--    treated as genuine and kept in the data.
-- 3. Gold and NIFTY have no daily move above 25%.
-- 4. The 25% cut-off is a screening threshold, not a statistical rule.
--    Removing these rows would understate BTC's risk.
-- ---------------------------------------------------------------------


-- =====================================================================
-- Q2. PERFORMANCE SCORECARD (the headline table for your README)
--  growth_of_1        : what 1 unit invested on day one is worth at the end
--  cagr_pct           : true compounded yearly return
--  avg_ann_return_pct : average daily return x 252 (overstates volatile assets)
--  ann_vol_pct        : yearly volatility (standard deviation of returns)
--  sharpe_rf0         : return per unit of total risk
--  sortino_rf0        : return per unit of DOWNSIDE risk only
--  var95 / cvar95     : 5th-percentile daily return / average of the days beyond it
--  max_drawdown_pct   : worst peak-to-trough fall
--  calmar             : CAGR divided by max drawdown (return per unit of crash pain)
-- =====================================================================
WITH base AS (
    SELECT asset_code, ret FROM v_returns_long
),
var AS (
    SELECT asset_code,
           PERCENTILE_CONT(0.05) WITHIN GROUP (ORDER BY ret)::numeric AS var95
    FROM base
    GROUP BY asset_code
),
stats AS (
    SELECT
        asset_code,
        COUNT(*)                                          AS n,
        AVG(ret)                                          AS mu,
        STDDEV_SAMP(ret)                                  AS sd,
        SQRT(AVG(POWER(LEAST(ret, 0), 2)))                AS downside_dev,
        EXP(SUM(LN(1 + ret)))                             AS growth,
        100.0 * COUNT(*) FILTER (WHERE ret > 0) / COUNT(*) AS pct_up_days
    FROM base
    GROUP BY asset_code
),
cvar AS (
    SELECT b.asset_code, AVG(b.ret) AS cvar95
    FROM base b
    JOIN var v ON v.asset_code = b.asset_code AND b.ret <= v.var95
    GROUP BY b.asset_code
),
mdd AS (
    SELECT asset_code, MIN(drawdown) AS max_dd
    FROM v_drawdown
    GROUP BY asset_code
)
SELECT
    s.asset_code,
    s.n                                                           AS trading_days,
    ROUND(s.growth, 2)                                            AS growth_of_1,
    ROUND(100 * (POWER(s.growth, 252.0 / s.n) - 1), 2)            AS cagr_pct,
    ROUND(100 * s.mu * 252, 2)                                    AS avg_ann_return_pct,
    ROUND(100 * s.sd * SQRT(252.0), 2)                            AS ann_vol_pct,
    ROUND(s.mu * SQRT(252.0) / s.sd, 2)                           AS sharpe_rf0,
    ROUND(s.mu * SQRT(252.0) / s.downside_dev, 2)                 AS sortino_rf0,
    ROUND(100 * v.var95, 2)                                       AS var95_1day_pct,
    ROUND(100 * c.cvar95, 2)                                      AS cvar95_1day_pct,
    ROUND(100 * m.max_dd, 1)                                      AS max_drawdown_pct,
    ROUND((POWER(s.growth, 252.0 / s.n) - 1) / ABS(m.max_dd), 2)  AS calmar,
    ROUND(s.pct_up_days, 1)                                       AS pct_up_days
FROM stats s
JOIN var  v USING (asset_code)
JOIN cvar c USING (asset_code)
JOIN mdd  m USING (asset_code)
ORDER BY s.asset_code;

-- ---------------------------------------------------------------------
-- FINDING (Q2): performance scorecard
-- Run on: data as of 2026-10-22 (2,818 common-day returns, 2015-01-05 to 2026-10-22)
--
--   asset  growth  CAGR%  avgAnn%  vol%   Sharpe Sortino VaR95%  CVaR95%  maxDD%  Calmar
--   BTC    258.72  64.35  72.39    67.07  1.08   1.62    -6.03    -9.72    -83.0   0.77
--   GOLD   3.43    11.64  12.50    17.23  0.73   1.04    -1.70    -2.53    -24.9   0.47
--   NIFTY  2.70    9.30   10.24    16.37  0.63   0.86    -1.50    -2.41    -38.4   0.24
--
-- 1. BTC delivered the highest return and best risk-adjusted scores, but with
--    about 4x the volatility of gold or NIFTY and an 83% maximum drawdown.
-- 2. CAGR (64.35%) is below the average-return figure (72.39%) because of
--    volatility drag; CAGR is the correct figure to quote.
-- 3. BTC's CVaR95 (-9.72%) is roughly 4x that of gold and NIFTY: on its worst
--    5% of days it lost almost 10% on average.
-- 4. Gold had a shallower drawdown than NIFTY (-24.9% vs -38.4%) but slightly
--    wider daily tail losses (VaR/CVaR), so "safer" depends on the measure.
-- 5. About 53% of days are up days for all three assets; BTC's advantage is
--    the size of its gains, not the frequency.
-- 6. Limitations: starting date (BTC began near $315), 0% risk-free rate,
--    mixed currencies (USD vs INR), possible exclusion of NIFTY dividends.
-- ---------------------------------------------------------------------


-- =====================================================================
-- Q3a. WORST DRAWDOWN EVENT per asset: peak, trough, recovery
-- recovery_date is NULL (status 'not yet recovered') if the asset has not
-- climbed back to its old peak by the last date in the data.
-- =====================================================================
WITH trough AS (
    SELECT DISTINCT ON (asset_code)
           asset_code, price_date AS trough_date, peak_index, drawdown
    FROM v_drawdown
    ORDER BY asset_code, drawdown
),
peak AS (
    SELECT t.asset_code, MAX(d.price_date) AS peak_date
    FROM trough t
    JOIN v_drawdown d
      ON d.asset_code = t.asset_code
     AND d.price_date <= t.trough_date
     AND d.wealth_index = t.peak_index
    GROUP BY t.asset_code
),
rec AS (
    SELECT t.asset_code, MIN(d.price_date) AS recovery_date
    FROM trough t
    JOIN v_drawdown d
      ON d.asset_code = t.asset_code
     AND d.price_date > t.trough_date
     AND d.wealth_index >= t.peak_index
    GROUP BY t.asset_code
)
SELECT
    t.asset_code,
    ROUND(100 * t.drawdown, 1)                  AS max_drawdown_pct,
    p.peak_date,
    t.trough_date,
    r.recovery_date,
    t.trough_date - p.peak_date                 AS days_peak_to_trough,
    r.recovery_date - t.trough_date             AS days_trough_to_recovery,
    CASE WHEN r.recovery_date IS NULL THEN 'not yet recovered' ELSE 'recovered' END AS status
FROM trough t
JOIN peak p USING (asset_code)
LEFT JOIN rec r USING (asset_code)
ORDER BY t.asset_code;

-- ---------------------------------------------------------------------
-- FINDING (Q3a): worst drawdown event per asset
-- Run on: data as of 2026-10-22 (common trading days only)
--
--   asset  max_dd%  peak_date   trough_date  recovery_date  days_down  days_to_recover  status
--   BTC    -83.0    2017-12-18  2018-12-14   2020-12-02     361        719              recovered
--   GOLD   -24.9    2026-01-29  2026-07-16   (none)         168        n/a              not yet recovered
--   NIFTY  -38.4    2020-01-14  2020-03-23   2020-11-09     69         231              recovered
--
-- 1. NIFTY: deep but short. The COVID crash took 69 days and the index was
--    back at its old peak about 10 months after the peak (300 days underwater).
-- 2. BTC: the 2017 bubble peak took 1,080 days (about 3 years) to be regained.
-- 3. GOLD: still below its 2026-01-29 peak at the end of the data, so its
--    -24.9% is the worst fall so far in an unfinished episode.
-- 4. Gold's worst drawdown falls at the very end of the sample, so its risk
--    metrics are more sensitive to recent data than BTC's or NIFTY's.
-- 5. Dates are on common trading days (weekdays when all three markets are
--    open), so BTC's true weekend peak and trough can differ slightly.
-- ---------------------------------------------------------------------


-- =====================================================================
-- Q3b. HOW OFTEN was each asset in pain? (share of days below each drawdown level)
-- =====================================================================
SELECT
    asset_code,
    ROUND(100.0 * COUNT(*) FILTER (WHERE drawdown < -0.10) / COUNT(*), 1) AS pct_days_below_minus10,
    ROUND(100.0 * COUNT(*) FILTER (WHERE drawdown < -0.20) / COUNT(*), 1) AS pct_days_below_minus20,
    ROUND(100.0 * COUNT(*) FILTER (WHERE drawdown < -0.50) / COUNT(*), 1) AS pct_days_below_minus50,
    ROUND(100 * AVG(drawdown), 1)                                         AS avg_drawdown_pct
FROM v_drawdown
GROUP BY asset_code
ORDER BY asset_code;

-- ---------------------------------------------------------------------
-- FINDING (Q3b): how often each asset was below its previous peak
-- Run on: data as of 2026-10-22 (2,818 common-day observations)
--
--   asset  >10% below  >20% below  >50% below  avg drawdown
--   BTC    76.6%       63.2%       30.3%       -33.6%
--   GOLD   31.3%       2.2%        0.0%        -7.3%
--   NIFTY  17.8%       2.2%        0.0%        -5.7%
--
-- 1. BTC spent about three quarters of the period at least 10% below its
--    prior high, and nearly a third of it more than 50% below.
-- 2. Gold and NIFTY were never more than 50% below a peak and each spent about
--    2.2% of days (roughly 62 days) more than 20% below.
-- 3. Gold spent more time in moderate drawdowns than NIFTY (avg -7.3% vs
--    -5.7%), although NIFTY's maximum drawdown is deeper (Q3a): NIFTY has the
--    worse worst case, gold the worse typical case.
-- 4. Drawdown days are clustered and not independent. These figures measure
--    time spent below a peak, not the probability of a loss on a single day.
-- ---------------------------------------------------------------------


-- =====================================================================
-- Q4. CALENDAR-YEAR RETURNS AND VOLATILITY (basis for a heatmap or bar chart)
-- 2015 starts on 5 Jan and the last year is partial, so treat both as partial years.
-- =====================================================================
SELECT
    *,
    CASE
        WHEN btc_return_pct >= GREATEST(gold_return_pct, nifty_return_pct) THEN 'BTC'
        WHEN gold_return_pct >= nifty_return_pct THEN 'GOLD'
        ELSE 'NIFTY'
    END AS best_asset
FROM (
    SELECT
        EXTRACT(YEAR FROM price_date)::int                AS yr,
        COUNT(*)                                          AS days,
        ROUND(100 * (EXP(SUM(LN(1 + btc)))   - 1), 1)     AS btc_return_pct,
        ROUND(100 * (EXP(SUM(LN(1 + gold)))  - 1), 1)     AS gold_return_pct,
        ROUND(100 * (EXP(SUM(LN(1 + nifty))) - 1), 1)     AS nifty_return_pct,
        ROUND(100 * STDDEV_SAMP(btc)   * SQRT(252.0), 1)  AS btc_vol_pct,
        ROUND(100 * STDDEV_SAMP(gold)  * SQRT(252.0), 1)  AS gold_vol_pct,
        ROUND(100 * STDDEV_SAMP(nifty) * SQRT(252.0), 1)  AS nifty_vol_pct
    FROM v_common_returns
    GROUP BY 1
) y
ORDER BY yr;

-- ---------------------------------------------------------------------
-- FINDING (Q4): calendar-year returns and volatility
-- Run on: data as of 2026-10-22 (2015 starts 5 Jan; 2026 is year-to-date)
--
--   yr     ret%: BTC     GOLD    NIFTY   | vol%: BTC   GOLD   NIFTY | best
--   2015        36.7   -10.6    -5.3     |       67.4  15.1   16.5  | BTC
--   2016       123.2     8.5     3.0     |       51.0  16.5   15.2  | BTC
--   2017      1424.7    13.6    28.6     |       93.6  10.6    9.2  | BTC
--   2018       -74.5    -2.1     3.2     |       79.7  10.9   13.1  | NIFTY
--   2019        92.2    18.9    12.0     |       71.9  12.0   14.1  | BTC
--   2020       303.2    24.7    14.9     |       72.7  22.2   31.8  | BTC
--   2021        59.7    -3.5    24.1     |       81.1  15.5   15.7  | BTC
--   2022       -64.1    -0.1     4.3     |       66.1  16.1   17.7  | NIFTY
--   2023       153.6    13.4    20.0     |       48.0  13.8   10.0  | BTC
--   2024       121.9    27.5     8.8     |       58.3  15.7   14.2  | BTC
--   2025        -6.3    64.4    10.5     |       39.9  21.5   11.9  | GOLD
--   2026 YTD    -6.9    -6.4   -13.2     |       45.7  30.3   15.2  | GOLD
--
-- 1. Yearly returns compound back to the Q2 growth figures (BTC 258.7x,
--    gold 3.43x, NIFTY 2.70x), so the two results are consistent.
-- 2. BTC had the best return in 8 of 12 years but also the two worst
--    (2018: -74.5%, 2022: -64.1%). NIFTY won those two years; gold won
--    2025 and 2026 YTD.
-- 3. BTC's 2017 (+1,424.7%) is outsized: the other 11 years compounded
--    give about 17x, not 259x.
-- 4. Gold's 2025 (+64.4%) is its best year by far and drives much of its CAGR.
-- 5. Calendar-year returns hide intra-year crashes (NIFTY 2020: +14.9% for
--    the year, but a -38.4% drawdown inside it).
-- 6. 2026 YTD is the only year in which all three assets are down; gold is
--    "best" there only because it lost the least.
-- 7. BTC volatility fell from 93.6% (2017) to 39.9% (2025); gold volatility
--    rose from 10.6% (2017) to 30.3% (2026 YTD). The BTC/gold volatility
--    ratio narrowed from about 9x to about 1.5x.
-- 8. best_asset ranks by return only and ignores risk.
-- ---------------------------------------------------------------------


-- =====================================================================
-- Q5a. CORRELATION of daily returns, full period
-- =====================================================================
SELECT
    ROUND(btc_gold::numeric, 3)   AS btc_gold,
    ROUND(btc_nifty::numeric, 3)  AS btc_nifty,
    ROUND(gold_nifty::numeric, 3) AS gold_nifty
FROM v_correlation;

-- ---------------------------------------------------------------------
-- FINDING (Q5a): correlation of daily returns, full period
-- Run on: data as of 2026-10-22 (2,818 common-day returns)
--
--   btc_gold  btc_nifty  gold_nifty
--   0.090     0.078      0.034
--
-- 1. All three correlations are close to zero: on a typical day, the assets
--    moved almost independently of each other.
-- 2. Squared, they explain under 1% of each other's daily variation
--    (BTC-gold about 0.8%, BTC-NIFTY about 0.6%, gold-NIFTY about 0.1%).
-- 3. Matches the v_correlation view (same data, rounded).
-- 4. Limitations: one number for 11 years can hide changes over time and
--    crash-period behaviour (see Q5b, Q5d, Q6). Daily returns may also be
--    pushed toward zero because the markets close at different times
--    (see the weekly check in Q5c).
-- ---------------------------------------------------------------------

-- =====================================================================
-- Q5b. CORRELATION by calendar year (did diversification hold every year?)
-- =====================================================================
SELECT
    EXTRACT(YEAR FROM price_date)::int       AS yr,
    ROUND(CORR(btc, gold)::numeric, 3)       AS btc_gold,
    ROUND(CORR(btc, nifty)::numeric, 3)      AS btc_nifty,
    ROUND(CORR(gold, nifty)::numeric, 3)     AS gold_nifty
FROM v_common_returns
GROUP BY 1
ORDER BY 1;

-- ---------------------------------------------------------------------
-- FINDING (Q5b): correlation of daily returns by calendar year
-- Run on: data as of 2026-10-22 (2015 starts 5 Jan; 2026 is year-to-date)
--
--   yr    btc_gold  btc_nifty  gold_nifty
--   2015   -0.010    0.141      0.006
--   2016    0.102   -0.059     -0.227
--   2017   -0.017   -0.014     -0.036
--   2018    0.011    0.013     -0.021
--   2019    0.199   -0.117     -0.063
--   2020    0.289    0.244      0.011
--   2021   -0.053    0.076      0.102
--   2022    0.060    0.184     -0.012
--   2023    0.135   -0.068      0.004
--   2024    0.070    0.073      0.126
--   2025    0.113    0.016      0.061
--   2026    0.231    0.109      0.295
--
-- 1. All values lie between -0.227 and +0.295; no pair reached 0.30 in any
--    year, so the near-zero picture from Q5a holds year by year.
-- 2. With about 240 daily observations per year, correlations within roughly
--    +/-0.13 cannot be told apart from zero (about +/-0.145 for 2026 YTD).
--    Among 36 values, a few will look unusual by chance.
-- 3. 2020 stands out: BTC's correlation with both gold (0.289) and NIFTY
--    (0.244) is at or near its highest. Consistent with assets moving
--    together in a crisis; see Q6 for the direct test.
-- 4. 2024-2026: all nine values are positive. 2026 YTD is the only year with
--    all three pairs above 0.1, and all three assets fell that year (Q4).
--    This hints at weakening diversification; check against Q5d.
-- 5. The sign of BTC-NIFTY and gold-NIFTY flips between years, so there is
--    no stable relationship in either direction.
-- ---------------------------------------------------------------------


-- =====================================================================
-- Q5c. ROBUSTNESS: correlation of WEEKLY returns
-- Daily correlations are pushed toward zero because the markets close at
-- different times of day. Weekly returns reduce that timing effect.
-- =====================================================================
WITH weekly AS (
    SELECT DISTINCT ON (DATE_TRUNC('week', price_date)::date)
           DATE_TRUNC('week', price_date)::date AS wk, btc, gold, nifty
    FROM v_common_prices
    ORDER BY DATE_TRUNC('week', price_date)::date, price_date DESC
),
wr AS (
    SELECT
        wk,
        btc   / LAG(btc)   OVER (ORDER BY wk) - 1 AS btc,
        gold  / LAG(gold)  OVER (ORDER BY wk) - 1 AS gold,
        nifty / LAG(nifty) OVER (ORDER BY wk) - 1 AS nifty
    FROM weekly
)
SELECT
    COUNT(btc)                            AS weeks,
    ROUND(CORR(btc, gold)::numeric, 3)    AS btc_gold_weekly,
    ROUND(CORR(btc, nifty)::numeric, 3)   AS btc_nifty_weekly,
    ROUND(CORR(gold, nifty)::numeric, 3)  AS gold_nifty_weekly
FROM wr;

-- ---------------------------------------------------------------------
-- FINDING (Q5c): robustness check, correlation of WEEKLY returns
-- Run on: data as of 2026-10-22 (616 weekly returns; weeks use the last
--         common trading day's close)
--
--                  daily (Q5a)   weekly (Q5c)
--   btc_gold        0.090         0.083
--   btc_nifty       0.078         0.127
--   gold_nifty      0.034         0.109
--
-- 1. Weekly correlations remain low (all below 0.13), so the diversification
--    conclusion holds at a weekly horizon.
-- 2. The NIFTY pairs rise from daily to weekly; BTC-gold does not. This is
--    consistent with non-synchronous closing times (NIFTY closes before US
--    trading hours), which push daily correlations toward zero. This is an
--    interpretation, not something tested here.
-- 3. With 616 observations, correlations beyond roughly +/-0.08 are
--    distinguishable from zero (rough rule; returns have fat tails). BTC-NIFTY
--    (0.127) and gold-NIFTY (0.109) pass; BTC-gold (0.083) is borderline.
-- 4. Even so, the correlations explain under 2% of weekly variation
--    (BTC-gold 0.7%, BTC-NIFTY 1.6%, gold-NIFTY 1.2%). Describe them as
--    "low but slightly positive", not "uncorrelated".
-- ---------------------------------------------------------------------

-- =====================================================================
-- Q5d. ROLLING 90-DAY CORRELATION: average, share of time above 0.3,
--      and when it was highest / lowest
-- =====================================================================
WITH ranked AS (
    SELECT
        pair, price_date, corr_90d,
        ROW_NUMBER() OVER (PARTITION BY pair ORDER BY corr_90d DESC) AS hi_rank,
        ROW_NUMBER() OVER (PARTITION BY pair ORDER BY corr_90d)      AS lo_rank
    FROM v_rolling_correlation_long
)
SELECT
    s.pair,
    s.avg_corr,
    s.pct_days_above_0_3,
    MAX(r.price_date) FILTER (WHERE r.hi_rank = 1)                 AS highest_on,
    ROUND(MAX(r.corr_90d) FILTER (WHERE r.hi_rank = 1)::numeric, 3) AS highest_value,
    MAX(r.price_date) FILTER (WHERE r.lo_rank = 1)                 AS lowest_on,
    ROUND(MAX(r.corr_90d) FILTER (WHERE r.lo_rank = 1)::numeric, 3) AS lowest_value
FROM (
    SELECT
        pair,
        ROUND(AVG(corr_90d)::numeric, 3)                                         AS avg_corr,
        ROUND(100.0 * COUNT(*) FILTER (WHERE corr_90d > 0.3) / COUNT(*), 1)      AS pct_days_above_0_3
    FROM v_rolling_correlation_long
    GROUP BY pair
) s
JOIN ranked r USING (pair)
GROUP BY s.pair, s.avg_corr, s.pct_days_above_0_3
ORDER BY s.pair;

-- ---------------------------------------------------------------------
-- FINDING (Q5d): rolling 90-day correlation of daily returns
-- Run on: data as of 2026-10-22 (2,729 rolling windows)
--
--   pair           avg     % windows > 0.3   highest (date)       lowest (date)
--   BTC vs Gold    0.092   7.7               0.549 (2026-10-14)   -0.249 (2018-11-15)
--   BTC vs NIFTY   0.036   4.0               0.632 (2020-03-16)   -0.210 (2019-10-14)
--   Gold vs NIFTY  0.019   4.0               0.409 (2026-06-18)   -0.439 (2016-02-29)
--
-- 1. The 90-day correlation stayed below 0.3 in 92% (BTC-gold) to 96% (other
--    pairs) of windows: diversification held most of the time, but it was
--    not constant.
-- 2. BTC-NIFTY peaked at 0.632 on 2020-03-16, during the COVID crash, the
--    highest reading of any pair. Consistent with assets moving together in
--    a crisis (direct test in Q6).
-- 3. Both gold pairs peak in 2026 (BTC-gold 0.549, gold-NIFTY 0.409), in line
--    with the higher 2026 values in Q5b. The data ends near a high point, so
--    whether this persists cannot be judged from this sample.
-- 4. A 90-day window is short: even a true correlation of zero often gives
--    readings within about +/-0.2 by chance. Only the extremes are clearly
--    beyond noise. Overlapping windows are not independent observations.
-- 5. The BTC-NIFTY average of rolling values (0.036) differs from the
--    full-period correlation (0.078) because the full-period figure gives
--    more weight to high-volatility stretches such as March 2020.
-- ---------------------------------------------------------------------

-- =====================================================================
-- Q6. HEDGE TEST: what did BTC and gold do on NIFTY's worst 5% of days?
-- Compares crash-day behaviour with normal days. This answers whether
-- diversification worked when it mattered.
-- =====================================================================
WITH thr AS (
    SELECT PERCENTILE_CONT(0.05) WITHIN GROUP (ORDER BY nifty) AS p5
    FROM v_common_returns
),
tagged AS (
    SELECT 'All days' AS scenario, r.btc, r.gold, r.nifty
    FROM v_common_returns r
    UNION ALL
    SELECT 'NIFTY worst 5% days', r.btc, r.gold, r.nifty
    FROM v_common_returns r, thr
    WHERE r.nifty <= thr.p5
)
SELECT
    scenario,
    COUNT(*)                                                         AS days,
    ROUND(100 * AVG(nifty), 2)                                       AS avg_nifty_pct,
    ROUND(100 * AVG(btc), 2)                                         AS avg_btc_pct,
    ROUND(100 * AVG(gold), 2)                                        AS avg_gold_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE btc  > 0) / COUNT(*), 1)    AS pct_days_btc_up,
    ROUND(100.0 * COUNT(*) FILTER (WHERE gold > 0) / COUNT(*), 1)    AS pct_days_gold_up,
    ROUND(CORR(btc, nifty)::numeric, 3)                              AS btc_nifty_corr,
    ROUND(CORR(gold, nifty)::numeric, 3)                             AS gold_nifty_corr
FROM tagged
GROUP BY scenario
ORDER BY scenario;

-- FINDING (Q6): hedge test, what BTC and gold did on NIFTY's worst 5% of days
-- Run on: data as of 2026-10-22
--
--   scenario             days  NIFTY%  BTC%   GOLD%  BTC up%  GOLD up%  corr BTC-NIFTY  corr GOLD-NIFTY
--   All days             2818   0.04    0.29   0.05   52.8     53.1      0.078           0.034
--   NIFTY worst 5% days   141  -2.41   -0.64  -0.01   46.8     51.1      0.214           0.019
--
-- 1. NIFTY's average on its worst days (-2.41%) equals the Q2 CVaR95, a useful
--    consistency check (141 days is 5% of 2,818).
-- 2. Gold was neutral on NIFTY's worst days: average -0.01% (vs +0.05% on all
--    days), up 51.1% of the time (vs 53.1%), correlation unchanged (0.019).
--    It did not fall with equities, but it did not offset the losses either.
-- 3. BTC tended to fall with NIFTY: average -0.64% vs +0.29% on all days, up
--    only 46.8% of the time (vs 52.8%), and the correlation rises to 0.214
--    (vs 0.078). Diversification was weaker when equities sold off.
-- 4. BTC's shortfall is roughly 2.6 standard errors below its normal average
--    (rough calculation), so unlikely to be pure chance. The correlation rise
--    is only suggestive: over 141 days a correlation has a margin of about
--    +/-0.17. Worst days also cluster (e.g. March 2020), so the effective
--    sample is smaller than 141.
-- 5. Consistent with Q5b and Q5d: BTC-NIFTY correlation peaked in March 2020.
-- 6. Timing: NIFTY closes before US hours, so same-day comparisons may
--    understate how BTC and gold react to the same news. A next-day version
--    has not been run.



-- =====================================================================
-- Q7. BETA TO NIFTY: how much BTC and gold move per 1% move in NIFTY,
--     and how much of their movement NIFTY explains (r_squared)
-- =====================================================================
SELECT 'BTC' AS asset,
       ROUND(REGR_SLOPE(btc, nifty)::numeric, 3) AS beta_to_nifty,
       ROUND(REGR_R2(btc, nifty)::numeric, 4)    AS r_squared
FROM v_common_returns
UNION ALL
SELECT 'GOLD',
       ROUND(REGR_SLOPE(gold, nifty)::numeric, 3),
       ROUND(REGR_R2(gold, nifty)::numeric, 4)
FROM v_common_returns;

-- ---------------------------------------------------------------------
-- FINDING (Q7): beta to NIFTY (daily returns)
-- Run on: data as of 2026-10-22 (2,818 common-day returns)
--
--   asset   beta_to_nifty   r_squared
--   BTC     0.320           0.0061
--   GOLD    0.036           0.0012
--
-- 1. A 1% move in NIFTY went with an average 0.32% move in BTC, and about
--    0.04% in gold. Rough t-statistics: BTC about 4 (distinguishable from
--    zero), gold about 1.8 (not clearly).
-- 2. NIFTY explains 0.6% of BTC's daily variance and 0.1% of gold's. More
--    than 99% of BTC's movement is independent of NIFTY, so BTC adds mostly
--    independent risk to a NIFTY portfolio (tested in Q8).
-- 3. These are the same numbers as Q5a restated: beta = correlation x
--    (asset volatility / NIFTY volatility); r_squared = correlation squared.
-- 4. Consistent with Q6: the BTC beta implies about -0.5% for BTC on a day
--    when NIFTY falls 2.4%; the observed Q6 average was -0.64%.
-- 5. Daily betas probably understate the true link because NIFTY closes
--    before US trading hours (see Q5c). Weekly betas have not been run.
-- ---------------------------------------------------------------------


-- =====================================================================
-- Q8. DIVERSIFICATION TEST: does adding BTC and/or gold improve a NIFTY portfolio?
-- Assumes the weights are rebalanced daily (a simplification).
-- Edit the weights in the VALUES list to try other mixes; each row must sum to 1.
-- =====================================================================
WITH weights (sort_order, portfolio, w_nifty, w_gold, w_btc) AS (
    VALUES
        (1, '100% NIFTY',                    1.00, 0.00, 0.00),
        (2, '95% NIFTY / 5% BTC',            0.95, 0.00, 0.05),
        (3, '90% NIFTY / 10% BTC',           0.90, 0.00, 0.10),
        (4, '90% NIFTY / 10% Gold',          0.90, 0.10, 0.00),
        (5, '80% NIFTY / 10% Gold / 10% BTC',0.80, 0.10, 0.10),
        (6, '70% NIFTY / 20% Gold / 10% BTC',0.70, 0.20, 0.10),
        (7, 'Equal weight (1/3 each)',       0.3333333333, 0.3333333333, 0.3333333334)
),
pr AS (
    SELECT w.sort_order, w.portfolio, r.price_date,
           w.w_nifty * r.nifty + w.w_gold * r.gold + w.w_btc * r.btc AS ret
    FROM weights w
    CROSS JOIN v_common_returns r
),
wi AS (
    SELECT sort_order, portfolio, price_date, ret,
           EXP(SUM(LN(1 + ret)) OVER (PARTITION BY portfolio ORDER BY price_date)) AS wealth
    FROM pr
),
dd AS (
    SELECT sort_order, portfolio, price_date, ret,
           wealth / GREATEST(1, MAX(wealth) OVER (PARTITION BY portfolio ORDER BY price_date)) - 1 AS drawdown
    FROM wi
)
SELECT
    portfolio,
    ROUND(100 * (POWER(EXP(SUM(LN(1 + ret))), 252.0 / COUNT(*)) - 1), 2) AS cagr_pct,
    ROUND(100 * STDDEV_SAMP(ret) * SQRT(252.0), 2)                       AS ann_vol_pct,
    ROUND(AVG(ret) * SQRT(252.0) / STDDEV_SAMP(ret), 2)                  AS sharpe_rf0,
    ROUND(100 * MIN(drawdown), 1)                                        AS max_drawdown_pct,
    ROUND(100 * PERCENTILE_CONT(0.05) WITHIN GROUP (ORDER BY ret)::numeric, 2) AS var95_1day_pct
FROM dd
GROUP BY sort_order, portfolio
ORDER BY sort_order;

-- ---------------------------------------------------------------------
-- FINDING (Q8): diversification test, NIFTY with BTC and/or gold added
-- Run on: data as of 2026-10-22 (2,818 common-day returns; daily rebalancing)
--
--   portfolio                         CAGR%   vol%    Sharpe  maxDD%  VaR95%
--   100% NIFTY                         9.30   16.37   0.63    -38.4   -1.50
--   95% NIFTY / 5% BTC                12.78   16.16   0.83    -37.6   -1.44
--   90% NIFTY / 10% BTC               16.25   16.66   0.99    -37.0   -1.51
--   90% NIFTY / 10% Gold               9.80   14.89   0.70    -35.1   -1.34
--   80% NIFTY / 10% Gold / 10% BTC    16.75   15.39   1.08    -33.7   -1.39
--   70% NIFTY / 20% Gold / 10% BTC    17.19   14.39   1.18    -30.4   -1.29
--   Equal weight (1/3 each)           33.18   24.64   1.29    -39.9   -2.19
--
-- 1. Sanity check: the 100% NIFTY row equals NIFTY's row in Q2.
-- 2. BTC mainly adds return: 5% BTC lifts CAGR by about 3.5 points and
--    Sharpe from 0.63 to 0.83 with slightly lower volatility. At 10% BTC,
--    volatility and VaR are back at NIFTY's level (BTC fell with NIFTY on
--    bad days, Q6). The volatility-minimising BTC weight is about 4% (rough
--    two-asset calculation that reproduces the 16.16% and 16.66% above).
-- 3. Gold mainly reduces risk: 10% gold cuts volatility by 1.5 points, max
--    drawdown from -38.4% to -35.1%, and barely changes return.
-- 4. 70/20/10 beats 100% NIFTY and the other mixes tested (excluding equal
--    weight) on every measure in this table.
-- 5. Equal weight has the best Sharpe (1.29) and CAGR (33.18%) but also higher
--    volatility, a deeper drawdown than NIFTY alone and the worst VaR.
-- 6. The return gains mostly reflect BTC's own history (start near $315, 2017
--    spike). The risk reductions come from low correlation. They should be
--    described separately.
-- 7. Limitations: daily rebalancing (unrealistic; buy-and-hold not tested),
--    INR and USD returns mixed without conversion, no costs or taxes,
--    hand-picked weights, drawdown dates not shown. Historical analysis,
--    not investment advice.
-- ---------------------------------------------------------------------


-- =====================================================================
-- Q9. BEST AND WORST 5 DAYS per asset (for the narrative: link dates to events)
-- =====================================================================
WITH ranked AS (
    SELECT
        asset_code, price_date, ret,
        ROW_NUMBER() OVER (PARTITION BY asset_code ORDER BY ret)      AS worst_rk,
        ROW_NUMBER() OVER (PARTITION BY asset_code ORDER BY ret DESC) AS best_rk
    FROM v_returns_long
)
SELECT asset_code, 'worst' AS kind, worst_rk AS rank, price_date, ROUND(100 * ret, 2) AS ret_pct
FROM ranked
WHERE worst_rk <= 5
UNION ALL
SELECT asset_code, 'best', best_rk, price_date, ROUND(100 * ret, 2)
FROM ranked
WHERE best_rk <= 5
ORDER BY asset_code, kind DESC, rank;

-- FINDING (Q9): five best and worst days per asset
-- Run on: data as of 2026-10-22 (returns between consecutive COMMON trading days)
--
--   BTC worst    2020-03-12 -37.17 | 2022-11-09 -22.92 | 2022-06-13 -22.68 | 2018-02-05 -21.24 | 2015-01-14 -21.14
--   BTC best     2017-12-07 +25.25 | 2017-07-20 +23.94 | 2019-05-13 +22.51 | 2016-06-13 +21.98 | 2021-02-08 +21.11
--   GOLD worst   2026-01-30 -10.78 | 2026-03-19  -5.93 | 2025-10-21  -5.74 | 2020-11-09  -4.99 | 2021-06-17  -4.65
--   GOLD best    2026-04-01  +6.34 | 2026-02-03  +6.07 | 2020-03-24  +5.95 | 2020-03-23  +5.59 | 2025-04-11  +5.36
--   NIFTY worst  2020-03-23 -12.98 | 2020-03-12  -8.30 | 2020-03-16  -7.61 | 2024-06-04  -5.93 | 2015-08-24  -5.92
--   NIFTY best   2020-04-07  +8.76 | 2020-03-25  +6.62 | 2020-03-20  +5.83 | 2019-09-20  +5.32 | 2021-02-01  +4.74
--
-- 1. Consistency: BTC's worst (-37.17%) and best (+25.25%) are the only moves
--    above 25% listed in Q1c; NIFTY's worst day (2020-03-23) is the Q3a
--    trough date; gold's worst day (2026-01-30) is the day after its Q3a peak
--    (2026-01-29).
-- 2. BTC's extremes range from -37% to +25% and fall between 2015 and 2022;
--    none since Nov 2022, consistent with BTC's falling volatility (Q4).
-- 3. These are returns between consecutive COMMON trading days. 5 of BTC's 10
--    extreme days are Mondays (2016-06-13, 2018-02-05, 2019-05-13, 2021-02-08,
--    2022-06-13), when the return spans Friday close to Monday close, so they
--    are better described as worst/best intervals than single days.
-- 4. Gold's worst day (-10.78% on 2026-01-30) came the day after its peak and
--    accounts for about 11 of the 24.9 points of its maximum drawdown (Q3a).
--    It is worse than all but one of NIFTY's five worst days. 3 of gold's 5
--    worst and 3 of its 5 best days fall in 2025-2026, consistent with its
--    30.3% volatility in 2026 YTD (Q4).
-- 5. Volatility clusters: 3 of NIFTY's 5 worst and 3 of its 5 best days are in
--    March-April 2020. BTC's worst day (2020-03-12) is also NIFTY's second
--    worst (-8.30%), so both fell hard on the same day.
-- 6. On NIFTY's worst day (2020-03-23) gold gained 5.59%. This is a single
--    example, not evidence; the Q6 averages are the evidence (gold neutral).
-- 7. The causes of gold's 2025-2026 moves have not been investigated; 
-- ---------------------------------------------------------------------