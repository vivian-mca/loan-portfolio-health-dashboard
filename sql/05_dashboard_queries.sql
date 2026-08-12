/* =====================================================================
   05_dashboard_queries.sql
   Pre-aggregated queries meant to be pulled into Power BI (Get Data ->
   SQL Server -> Advanced options -> SQL statement), one per drill-down.
   For the underlying loan-level grain, import lending.vw_LoanPortfolioBase
   directly and let Power BI/DAX do the slicing -- these queries are for
   when you want the aggregation to happen in SQL instead (e.g. a fast
   summary table, or a source you can hand to someone without Power BI).
   ===================================================================== */

USE LoanPortfolioDB;
GO

-- ---------------------------------------------------------------------
-- 1. KPI summary by Branch
-- Suggested visual: a table or matrix with a KPI per column, one row
-- per branch, conditional formatting on DelinquencyRateByBalance.
-- ---------------------------------------------------------------------
SELECT
    b.BranchName,
    b.Region,
    COUNT(*)                                                       AS TotalLoanCount,
    SUM(CASE WHEN v.IsActive = 1 THEN 1 ELSE 0 END)                AS ActiveLoanCount,
    SUM(CASE WHEN v.IsActive = 1 THEN v.OutstandingBalance ELSE 0 END) AS ActiveBalance,
    SUM(CASE WHEN v.IsActive = 1 AND v.IsDelinquent = 1 THEN v.OutstandingBalance ELSE 0 END)
        / NULLIF(SUM(CASE WHEN v.IsActive = 1 THEN v.OutstandingBalance ELSE 0 END), 0)
                                                                    AS DelinquencyRateByBalance,
    SUM(v.ChargeOffAmount) / NULLIF(SUM(v.LoanAmount), 0)          AS ChargeOffRateByAmount,
    SUM(CASE WHEN v.IsSecured = 1 THEN v.LoanAmount ELSE 0 END)
        / NULLIF(SUM(CASE WHEN v.IsSecured = 1 THEN v.CollateralValue ELSE 0 END), 0)
                                                                    AS WeightedAvgLTV
FROM lending.vw_LoanPortfolioBase v
JOIN lending.Branches b ON b.BranchID = v.BranchID
GROUP BY b.BranchName, b.Region
ORDER BY ActiveBalance DESC;
GO

-- ---------------------------------------------------------------------
-- 2. KPI summary by Loan Officer
-- Suggested visual: a ranked table (top/bottom performers by
-- delinquency or charge-off rate), filterable by branch via slicer.
-- ---------------------------------------------------------------------
SELECT
    v.LoanOfficerID,
    v.LoanOfficerName,
    b.BranchName,
    COUNT(*)                                                       AS TotalLoanCount,
    SUM(CASE WHEN v.IsActive = 1 THEN 1 ELSE 0 END)                AS ActiveLoanCount,
    SUM(CASE WHEN v.IsActive = 1 THEN v.OutstandingBalance ELSE 0 END) AS ActiveBalance,
    SUM(CASE WHEN v.IsActive = 1 AND v.IsDelinquent = 1 THEN v.OutstandingBalance ELSE 0 END)
        / NULLIF(SUM(CASE WHEN v.IsActive = 1 THEN v.OutstandingBalance ELSE 0 END), 0)
                                                                    AS DelinquencyRateByBalance,
    SUM(v.ChargeOffAmount) / NULLIF(SUM(v.LoanAmount), 0)          AS ChargeOffRateByAmount
FROM lending.vw_LoanPortfolioBase v
JOIN lending.Branches b ON b.BranchID = v.BranchID
GROUP BY v.LoanOfficerID, v.LoanOfficerName, b.BranchName
ORDER BY ActiveBalance DESC;
GO

-- ---------------------------------------------------------------------
-- 3. KPI summary by Member Segment
-- Suggested visual: a stacked bar of active balance by segment, plus a
-- clustered column comparing delinquency rate across segments -- the
-- clearest way to show "risk concentrates in Subprime" to a reviewer.
-- ---------------------------------------------------------------------
SELECT
    v.MemberSegment,
    COUNT(*)                                                       AS TotalLoanCount,
    SUM(CASE WHEN v.IsActive = 1 THEN 1 ELSE 0 END)                AS ActiveLoanCount,
    SUM(CASE WHEN v.IsActive = 1 THEN v.OutstandingBalance ELSE 0 END) AS ActiveBalance,
    SUM(CASE WHEN v.IsActive = 1 AND v.IsDelinquent = 1 THEN v.OutstandingBalance ELSE 0 END)
        / NULLIF(SUM(CASE WHEN v.IsActive = 1 THEN v.OutstandingBalance ELSE 0 END), 0)
                                                                    AS DelinquencyRateByBalance,
    SUM(v.ChargeOffAmount) / NULLIF(SUM(v.LoanAmount), 0)          AS ChargeOffRateByAmount,
    AVG(m.CreditScore)                                             AS AvgCreditScore,
    AVG(m.DebtToIncomeRatio)                                       AS AvgDTI
FROM lending.vw_LoanPortfolioBase v
JOIN lending.Members m ON m.MemberID = v.MemberID
GROUP BY v.MemberSegment
ORDER BY ActiveBalance DESC;
GO

-- ---------------------------------------------------------------------
-- 4. Loan concentration by Loan Type (portfolio mix)
-- Suggested visual: a donut/pie of ActiveBalance share by LoanTypeName --
-- the direct answer to "what's the loan-type concentration KPI."
-- ---------------------------------------------------------------------
SELECT * FROM lending.vw_KPI_LoanConcentrationByType
ORDER BY PctOfActiveBalance DESC;
GO

-- ---------------------------------------------------------------------
-- 5. Monthly origination trend
-- Suggested visual: a line chart of originated volume over time, with
-- a secondary line for the delinquency rate of loans originated that
-- month (a vintage-style view -- do newer cohorts perform worse?).
-- ---------------------------------------------------------------------
SELECT
    DATEFROMPARTS(YEAR(OriginationDate), MONTH(OriginationDate), 1)   AS OriginationMonth,
    COUNT(*)                                                       AS LoansOriginated,
    SUM(LoanAmount)                                                AS AmountOriginated,
    SUM(CASE WHEN IsActive = 1 AND IsDelinquent = 1 THEN 1 ELSE 0 END)
        / NULLIF(SUM(CASE WHEN IsActive = 1 THEN 1 ELSE 0 END), 0) AS CohortDelinquencyRateByCount,
    SUM(ChargeOffFlag)                                             AS ChargedOffCount
FROM lending.vw_LoanPortfolioBase
GROUP BY DATEFROMPARTS(YEAR(OriginationDate), MONTH(OriginationDate), 1)
ORDER BY OriginationMonth;
GO

-- ---------------------------------------------------------------------
-- 6. Branch x Loan Type matrix (concentration drill-down)
-- Suggested visual: a Power BI matrix visual, Branch on rows, LoanType
-- on columns, ActiveBalance as the value -- spot a branch overweight in
-- one product at a glance.
-- ---------------------------------------------------------------------
SELECT
    b.BranchName,
    v.LoanTypeName,
    SUM(CASE WHEN v.IsActive = 1 THEN v.OutstandingBalance ELSE 0 END) AS ActiveBalance,
    SUM(CASE WHEN v.IsActive = 1 THEN 1 ELSE 0 END)                AS ActiveLoanCount
FROM lending.vw_LoanPortfolioBase v
JOIN lending.Branches b ON b.BranchID = v.BranchID
GROUP BY b.BranchName, v.LoanTypeName
ORDER BY b.BranchName, ActiveBalance DESC;
GO
