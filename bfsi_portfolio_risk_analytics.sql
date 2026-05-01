----- Q1. Which loan segment is contributing most to NPAs?

SELECT 
	loan_type,
	COUNT(*) AS total_loans,
    SUM(loan_amount_lakh) AS total_loan_amount_lakh,
    SUM(CASE WHEN is_npa = 1 THEN loan_amount_lakh ELSE 0 END) AS npa_amount_lakh,
    COUNT(CASE WHEN is_npa = 1 THEN 1 END) AS npa_count,
    ROUND(100 * SUM(CASE WHEN is_npa = 1 THEN loan_amount_lakh END)/ SUM(loan_amount_lakh),2) AS npa_pct
FROM loans
GROUP BY loan_type
ORDER BY npa_pct DESC;

----- Q2. How does CIBIL score impact default risk?
SELECT
    CASE
        WHEN c.cibil_score BETWEEN 300 AND 549 THEN '300-549 (POOR)'
        WHEN c.cibil_score BETWEEN 550 AND 649 THEN '550-649 (FAIR)'
        WHEN c.cibil_score BETWEEN 650 AND 749 THEN '650-749 (GOOD)'
        WHEN c.cibil_score BETWEEN 750 AND 849 THEN '750-849 (VERY GOOD)'
        ELSE '850-900 (EXCELLENT)' 
    END AS cibil_bucket,
    COUNT(DISTINCT c.customer_id) AS customer_count,
    ROUND(AVG(c.annual_income_lakh), 2) AS avg_income_lakh, 
    COUNT(l.loan_id) AS total_loans,
    SUM(l.is_npa) AS npa_loans,
    ROUND(100.0 * SUM(l.is_npa) / NULLIF(COUNT(l.loan_id), 0), 2) AS npa_rate_pct,
    ROUND(AVG(l.interest_rate_pct), 2) AS avg_interest_rate
FROM customers c
JOIN loans l ON c.customer_id = l.customer_id
GROUP BY 
    CASE
        WHEN c.cibil_score BETWEEN 300 AND 549 THEN '300-549 (POOR)'
        WHEN c.cibil_score BETWEEN 550 AND 649 THEN '550-649 (FAIR)'
        WHEN c.cibil_score BETWEEN 650 AND 749 THEN '650-749 (GOOD)'
        WHEN c.cibil_score BETWEEN 750 AND 849 THEN '750-849 (VERY GOOD)'
        ELSE '850-900 (EXCELLENT)' 
    END
ORDER BY MIN(c.cibil_score);

----- Q3. Which branches are underperforming in collections?
WITH branch_perf AS (
  SELECT
    mc.branch_id,
    b.branch_name,
    b.zone,
    b.state,
    ROUND(AVG(mc.collection_efficiency_pct), 2)  AS avg_efficiency,
    ROUND(AVG(mc.npa_pct), 2) AS avg_npa_pct,
    SUM(mc.new_loans_disbursed) AS total_disbursements
  FROM monthly_collections mc
  JOIN branches b ON mc.branch_id = b.branch_id
  WHERE mc.month LIKE '2024%'
  GROUP BY mc.branch_id, b.branch_name, b.zone, b.state
)
SELECT
  branch_id, branch_name, zone, state,
  avg_efficiency,
  avg_npa_pct,
  total_disbursements,
  RANK() OVER (ORDER BY avg_efficiency DESC) AS efficiency_rank,
  CASE
    WHEN avg_efficiency >= 95 THEN 'Green'
    WHEN avg_efficiency >= 85 THEN 'Amber'
    ELSE 'Red'
  END rag_status
FROM branch_perf
ORDER BY efficiency_rank;

----- Q4. Is NPA increasing or decreasing over time?

WITH monthly_npa AS (
  SELECT
    DATE_FORMAT(disbursement_date, '%Y-%m') AS month,
    COUNT(CASE WHEN is_npa=1 THEN 1 END) AS npa_count,
    ROUND(SUM(CASE WHEN is_npa=1
      THEN loan_amount_lakh END), 2) AS npa_amount_lakh,
    ROUND(SUM(loan_amount_lakh), 2) AS total_portfolio_lakh
  FROM loans
  GROUP BY DATE_FORMAT(disbursement_date, '%Y-%m')
)
SELECT
  month,
  npa_count,
  npa_amount_lakh,
  total_portfolio_lakh,
  ROUND(100.0 * npa_amount_lakh / total_portfolio_lakh, 2) AS npa_pct,
  LAG(npa_amount_lakh) OVER (ORDER BY month) AS prev_month_npa,
  ROUND(
    npa_amount_lakh - LAG(npa_amount_lakh) OVER (ORDER BY month)
  , 2) AS mom_change_lakh
FROM monthly_npa
ORDER BY month;

----- Q5. Who are the highest-risk customers?
SELECT
  c.customer_id,
  c.name,
  c.cibil_score,
  c.cibil_category,
  c.annual_income_lakh,
  c.state,
  COUNT(l.loan_id) AS total_loans,
  SUM(CASE WHEN l.is_npa=1 THEN l.loan_amount_lakh END) AS npa_exposure_lakh,
  MAX(l.days_past_due) AS max_dpd,
  MAX(l.emi_missed_count) AS max_emi_missed,
  ROUND(
    100.0 * SUM(CASE WHEN l.is_npa=1 THEN l.loan_amount_lakh END)
           / SUM(l.loan_amount_lakh), 2
  ) AS npa_pct_of_exposure
FROM customers c
JOIN loans l ON c.customer_id = l.customer_id
GROUP BY c.customer_id, c.name, c.cibil_score, c.cibil_category,
         c.annual_income_lakh, c.state
HAVING SUM(l.is_npa) > 0
ORDER BY npa_exposure_lakh DESC
LIMIT 10;

----- Q6. Can we detect fraud patterns in transactions?

WITH fraud_base AS (
    -- First filter froud transaction and count channel
    SELECT 
        customer_id,
        amount,
        transaction_date,
        channel,
        COUNT(*) OVER (PARTITION BY customer_id, channel) as channel_usage_count
    FROM transactions
    WHERE is_flagged_fraud = 1 
      AND status = 'Success'
),
top_channels AS (
    -- Rank top channel every customer
    SELECT 
        customer_id,
        channel,
        ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY channel_usage_count DESC) as rn
    FROM fraud_base
),
fraud_summary AS (
    -- Final aggregation
    SELECT
        t.customer_id,
        COUNT(*) AS fraud_txn_count,
        ROUND(SUM(t.amount), 2) AS total_fraud_amount,
        MAX(t.transaction_date) AS last_fraud_date,
        tc.channel AS top_fraud_channel
    FROM transactions t
    JOIN top_channels tc ON t.customer_id = tc.customer_id AND tc.rn = 1
    WHERE t.is_flagged_fraud = 1
      AND t.status = 'Success'
    GROUP BY t.customer_id, tc.channel
    HAVING COUNT(*) >= 3
)
SELECT
    fs.*,
    c.cibil_score,
    c.state,
    c.occupation
FROM fraud_summary fs
JOIN customers c ON fs.customer_id = c.customer_id
ORDER BY fs.fraud_txn_count DESC;

----- Q7. Are customers over-leveraged?

WITH customer_lti AS (
  SELECT
    c.customer_id,
    c.annual_income_lakh,
    SUM(l.loan_amount_lakh) AS total_loan_lakh,
    ROUND(SUM(l.loan_amount_lakh)/c.annual_income_lakh, 2) AS lti_ratio,
    COUNT(l.loan_id) AS loan_count
  FROM customers c
  JOIN loans l ON c.customer_id = l.customer_id
  WHERE l.loan_status = 'Active'
  GROUP BY c.customer_id, c.annual_income_lakh
)
SELECT
  CASE
    WHEN lti_ratio <= 2   THEN 'Low Risk   (≤2×)'
    WHEN lti_ratio <= 4   THEN 'Medium Risk (2–4×)'
    WHEN lti_ratio <= 6   THEN 'High Risk   (4–6×)'
    ELSE 'Very High   (>6×)'
  END AS lti_band,
  COUNT(*) AS customer_count,
  ROUND(AVG(lti_ratio), 2) AS avg_lti,
  ROUND(AVG(total_loan_lakh), 2) AS avg_exposure_lakh,
  ROUND(AVG(annual_income_lakh), 2) AS avg_income_lakh
FROM customer_lti
GROUP BY lti_band
ORDER BY MIN(lti_ratio);

----- Q8. How is business growing over time?


SELECT
  YEAR(disbursement_date) AS yr,
  QUARTER(disbursement_date) AS qtr,
  COUNT(loan_id) AS loans_disbursed,
  ROUND(SUM(loan_amount_lakh), 2) AS qtr_disbursement_lakh,
  ROUND(
    SUM(SUM(loan_amount_lakh))
      OVER (PARTITION BY YEAR(disbursement_date)
            ORDER BY QUARTER(disbursement_date)
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
  , 2) AS cumulative_ytd_lakh
FROM loans
GROUP BY YEAR(disbursement_date), QUARTER(disbursement_date)
ORDER BY yr, qtr;

----- Q9. How does RBI classify loan risk (DPD buckets)?

SELECT
  CASE
    WHEN days_past_due = 0 THEN 'Standard (0 DPD)'
    WHEN days_past_due BETWEEN 1 AND 30  THEN 'SMA-0 (1–30 DPD)'
    WHEN days_past_due BETWEEN 31 AND 60 THEN 'SMA-1 (31–60 DPD)'
    WHEN days_past_due BETWEEN 61 AND 89 THEN 'SMA-2 (61–89 DPD)'
    ELSE 'NPA (90+ DPD)'
  END AS rbi_classification,
  COUNT(*) AS loan_count,
  ROUND(SUM(loan_amount_lakh), 2) AS exposure_lakh,
  ROUND(100.0*COUNT(*)/SUM(COUNT(*)) OVER(), 2) AS pct_of_total
FROM loans
GROUP BY rbi_classification
ORDER BY MIN(days_past_due);

----- Q10. Which payment channels are risky? 

SELECT
  channel,
  COUNT(*) AS txn_count,
  ROUND(SUM(amount)/100000, 2) AS total_crore,
  ROUND(100.0*COUNT(*)/SUM(COUNT(*)) OVER(), 2) AS txn_share_pct,
  COUNT(CASE WHEN status='Failed' THEN 1 END) AS failed_txns,
  ROUND(
    100.0 * COUNT(CASE WHEN status='Failed' THEN 1 END)
           / COUNT(*), 2
  ) AS failure_rate_pct,
  COUNT(CASE WHEN is_flagged_fraud=1 THEN 1 END) AS fraud_flags
FROM transactions
WHERE transaction_type = 'EMI Payment'
GROUP BY channel
ORDER BY txn_count DESC;

----- Q11. Which loan vintages perform poorly?

SELECT
  YEAR(disbursement_date) AS disbursement_year,
  loan_type,
  COUNT(*) AS total_loans,
  SUM(is_npa) AS npa_count,
  ROUND(100.0 * SUM(is_npa) / COUNT(*), 2) AS npa_rate_pct,
  ROUND(AVG(loan_amount_lakh), 2) AS avg_loan_lakh,
  ROUND(AVG(interest_rate_pct), 2) AS avg_rate,
  ROUND(AVG(days_past_due), 0) AS avg_dpd
FROM loans
GROUP BY YEAR(disbursement_date), loan_type
ORDER BY disbursement_year, npa_rate_pct DESC;

----- Q12. What is the overall health of the portfolio?

WITH portfolio AS (
  SELECT
    ROUND(SUM(loan_amount_lakh),2) AS total_portfolio_lakh,
    ROUND(SUM(CASE WHEN is_npa=1
      THEN loan_amount_lakh END),2) AS total_npa_lakh,
    ROUND(100.0*SUM(is_npa)/COUNT(*),2) AS overall_npa_pct,
    COUNT(*) AS total_loans,
    SUM(is_npa) AS npa_loans
  FROM loans
),
collection AS (
  SELECT ROUND(AVG(collection_efficiency_pct),2) AS avg_collection_eff
  FROM monthly_collections
  WHERE month LIKE '2024%'
),
fraud AS (
  SELECT
    COUNT(*) AS total_fraud_flags,
    ROUND(SUM(amount)/100000,2) AS fraud_amount_crore
  FROM transactions
  WHERE is_flagged_fraud=1 AND status='Success'
),
top_zone AS (
  SELECT b.zone,
    ROUND(AVG(mc.collection_efficiency_pct),2) AS zone_efficiency
  FROM monthly_collections mc
  JOIN branches b ON mc.branch_id=b.branch_id
  WHERE mc.month LIKE '2024%'
  GROUP BY b.zone
  ORDER BY zone_efficiency DESC LIMIT 1
)
SELECT
  p.total_portfolio_lakh,
  p.total_npa_lakh,
  p.overall_npa_pct,
  p.total_loans,
  p.npa_loans,
  c.avg_collection_eff AS collection_efficiency_2024_pct,
  f.total_fraud_flags,
  f.fraud_amount_crore,
  tz.zone AS best_performing_zone,
  tz.zone_efficiency AS best_zone_efficiency_pct
FROM portfolio p
CROSS JOIN collection c
CROSS JOIN fraud f
CROSS JOIN top_zone tz;









