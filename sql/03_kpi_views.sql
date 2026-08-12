/* =====================================================================
   03_kpi_views.sql
   KPI views for the Loan Portfolio Health Dashboard.

   Business logic for each KPI is explained in plain language in
   docs/study-guide.md Section 4 -- this file focuses on the SQL. Every
   view is built on top of lending.vw_LoanPortfolioBase so the KPI
   definitions ("what counts as active," "what counts as delinquent")
   are defined exactly once and reused everywhere, instead of redefined
   -- and risking drift -- in five different places.
   ===================================================================== */

USE LoanPortfolioDB;
GO

-- ---------------------------------------------------------------------
-- vw_LoanPortfolioBase
-- One row per loan, denormalized with the dimension attributes every
-- KPI and every Power BI drill-down needs. This is also a reasonable
-- single table to hand Power BI directly for ad-hoc exploration.
-- ---------------------------------------------------------------------
CREATE OR ALTER VIEW lending.vw_LoanPortfolioBase AS
SELECT
    l.LoanID,
    l.SourceLoanID,
    l.MemberID,
    m.MemberSegment,
    m.CreditTier,
    m.IncomeTier,
    l.BranchID,
    b.BranchName,
    b.Region,
    l.LoanOfficerID,
    CONCAT(lo.FirstName, ' ', lo.LastName)     AS LoanOfficerName,
    l.LoanTypeID,
    lt.LoanTypeName,
    lt.IsSecured,
    l.LoanAmount,
    l.InterestRate,
    l.TermMonths,
    l.OriginationDate,
    l.MaturityDate,
    l.OutstandingBalance,
    l.CollateralValue,
    l.CurrentStatus,
    l.DelinquencyDays,
    -- Stored as BIT (efficient for storage/constraints), but SQL Server's SUM() rejects
    -- BIT directly -- cast to INT once here so every downstream view/query can SUM() it.
    CAST(l.ChargeOffFlag AS INT) AS ChargeOffFlag,
    l.ChargeOffAmount,
    l.ChargeOffDate,
    -- A loan is "active" (an earning asset still on the books) once it's originated
    -- and until it resolves to Paid Off or Charged Off.
    CASE WHEN l.CurrentStatus NOT IN ('Paid Off', 'Charged Off') THEN 1 ELSE 0 END AS IsActive,
    -- "Delinquent" = active AND at least 30 days past due. A handful of days late
    -- (grace period) is not treated as delinquent -- DelinquencyDays is 0 for 'Current'.
    CASE WHEN l.DelinquencyDays > 0 THEN 1 ELSE 0 END AS IsDelinquent
FROM lending.Loans l
JOIN lending.Members m       ON m.MemberID = l.MemberID
JOIN lending.Branches b      ON b.BranchID = l.BranchID
JOIN lending.LoanOfficers lo ON lo.LoanOfficerID = l.LoanOfficerID
JOIN lending.LoanTypes lt    ON lt.LoanTypeID = l.LoanTypeID;
GO

-- ---------------------------------------------------------------------
-- KPI 1: Delinquency Rate
-- Of the loans still on the books (active), what share of the dollar
-- balance -- and separately, what share of the loan count -- is 30+
-- days past due? Balance-weighted is the number that matters for risk
-- (a delinquent $400K mortgage is a bigger problem than a delinquent
-- $300 personal loan), count-weighted is what operations/collections
-- staff about workload. Both are reported.
-- ---------------------------------------------------------------------
CREATE OR ALTER VIEW lending.vw_KPI_DelinquencyRate AS
SELECT
    COUNT(*)                                                   AS ActiveLoanCount,
    SUM(IsDelinquent)                                          AS DelinquentLoanCount,
    CAST(SUM(IsDelinquent) AS DECIMAL(12,4))
        / NULLIF(COUNT(*), 0)                                  AS DelinquencyRateByCount,
    SUM(OutstandingBalance)                                    AS ActiveBalance,
    SUM(CASE WHEN IsDelinquent = 1 THEN OutstandingBalance ELSE 0 END) AS DelinquentBalance,
    SUM(CASE WHEN IsDelinquent = 1 THEN OutstandingBalance ELSE 0 END)
        / NULLIF(SUM(OutstandingBalance), 0)                   AS DelinquencyRateByBalance
FROM lending.vw_LoanPortfolioBase
WHERE IsActive = 1;
GO

-- ---------------------------------------------------------------------
-- KPI 2: Charge-off Rate
-- Of everything ever originated, what share has been written off as
-- uncollectible? Reported as cumulative net charge-offs as a percentage
-- of total originated volume (a simplified, non-annualized version of
-- the standard "net charge-offs / average outstanding loans" ratio --
-- see docs/study-guide.md for why, and how to annualize it if you add
-- a date-range parameter).
-- ---------------------------------------------------------------------
CREATE OR ALTER VIEW lending.vw_KPI_ChargeOffRate AS
SELECT
    COUNT(*)                                                   AS TotalLoanCount,
    SUM(ChargeOffFlag)                                         AS ChargedOffLoanCount,
    CAST(SUM(ChargeOffFlag) AS DECIMAL(12,4))
        / NULLIF(COUNT(*), 0)                                  AS ChargeOffRateByCount,
    SUM(LoanAmount)                                            AS TotalOriginatedAmount,
    SUM(ChargeOffAmount)                                       AS TotalChargeOffAmount,
    SUM(ChargeOffAmount) / NULLIF(SUM(LoanAmount), 0)          AS ChargeOffRateByAmount
FROM lending.vw_LoanPortfolioBase;
GO

-- ---------------------------------------------------------------------
-- KPI 3: Loan-to-Value (LTV) Ratio
-- Only meaningful for secured loans (auto, mortgage) -- LTV compares
-- what's owed to what the collateral is worth. Reported both as a
-- dollar-weighted average (total financed / total collateral value,
-- the right way to read aggregate collateral risk) and a simple average
-- across loans, plus a count of loans over the 90% LTV threshold most
-- credit unions treat as elevated risk.
-- ---------------------------------------------------------------------
CREATE OR ALTER VIEW lending.vw_KPI_LoanToValue AS
SELECT
    LoanTypeName,
    COUNT(*)                                                   AS SecuredLoanCount,
    SUM(LoanAmount)                                            AS TotalFinancedAmount,
    SUM(CollateralValue)                                       AS TotalCollateralValue,
    SUM(LoanAmount) / NULLIF(SUM(CollateralValue), 0)          AS WeightedAvgLTV,
    AVG(LoanAmount / NULLIF(CollateralValue, 0))               AS SimpleAvgLTV,
    SUM(CASE WHEN LoanAmount / NULLIF(CollateralValue, 0) > 0.90
             THEN 1 ELSE 0 END)                                AS LoansOverNinetyPctLTV
FROM lending.vw_LoanPortfolioBase
WHERE IsSecured = 1
GROUP BY LoanTypeName;
GO

-- ---------------------------------------------------------------------
-- KPI 4: Net Interest Margin (NIM)
-- (Interest income earned on the loan book - interest expense paid on
-- the deposits/funding that back it) / earning assets. Interest income
-- and expense are annualized run-rates off the current snapshot balance,
-- not trailing-twelve-months actuals -- see docs/study-guide.md for the
-- simplification and how you'd extend this with a real payments table.
-- CostOfFundsRate comes from lending.InstitutionParameters so Finance
-- can update the assumption without touching this view.
-- ---------------------------------------------------------------------
CREATE OR ALTER VIEW lending.vw_KPI_NetInterestMargin AS
SELECT
    SUM(OutstandingBalance)                                    AS EarningAssets,
    SUM(OutstandingBalance * InterestRate)                     AS AnnualInterestIncome,
    SUM(OutstandingBalance) * p.CostOfFundsRate                AS AnnualInterestExpense,
    SUM(OutstandingBalance * InterestRate)
        - SUM(OutstandingBalance) * p.CostOfFundsRate          AS AnnualNetInterestIncome,
    (SUM(OutstandingBalance * InterestRate)
        - SUM(OutstandingBalance) * p.CostOfFundsRate)
        / NULLIF(SUM(OutstandingBalance), 0)                   AS NetInterestMargin
FROM lending.vw_LoanPortfolioBase
CROSS JOIN (
    SELECT CAST(ParamValue AS DECIMAL(10,6)) AS CostOfFundsRate
    FROM lending.InstitutionParameters WHERE ParamName = 'CostOfFundsRate'
) p
WHERE IsActive = 1
GROUP BY p.CostOfFundsRate;
GO

-- ---------------------------------------------------------------------
-- KPI 5: Loan Concentration by Loan Type
-- What share of the active portfolio sits in each product? A book that's
-- 80% one loan type is more exposed to a downturn in that specific
-- product/collateral market -- this is the concentration-risk view.
-- ---------------------------------------------------------------------
CREATE OR ALTER VIEW lending.vw_KPI_LoanConcentrationByType AS
SELECT
    LoanTypeName,
    IsSecured,
    COUNT(*)                                                   AS ActiveLoanCount,
    SUM(OutstandingBalance)                                    AS ActiveBalance,
    SUM(OutstandingBalance) / NULLIF(SUM(SUM(OutstandingBalance)) OVER (), 0) AS PctOfActiveBalance,
    COUNT(*) * 1.0 / NULLIF(SUM(COUNT(*)) OVER (), 0)          AS PctOfActiveLoanCount
FROM lending.vw_LoanPortfolioBase
WHERE IsActive = 1
GROUP BY LoanTypeName, IsSecured;
GO

PRINT 'KPI views created: vw_LoanPortfolioBase, vw_KPI_DelinquencyRate, vw_KPI_ChargeOffRate, vw_KPI_LoanToValue, vw_KPI_NetInterestMargin, vw_KPI_LoanConcentrationByType';
