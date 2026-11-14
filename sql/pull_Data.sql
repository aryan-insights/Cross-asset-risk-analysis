SELECT asset, COUNT(*) AS row_count, MIN(date) AS first_day, MAX(date) AS last_day
FROM prices
GROUP BY asset;