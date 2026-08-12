/* =====================================================================
   04_stored_procedures.sql
   Parameterized KPI procedures.

   Views (03_kpi_views.sql) answer "what is the KPI for the whole
   portfolio, right now." These procedures answer the two questions a
   view alone can't: "what is it for a specific branch/date range" and
   "break it down by branch/officer/segment in one call."
   ===================================================================== */

USE LoanPortfolioDB;
GO

-- ---------------------------------------------------------------------
-- usp_GetPortfolioKPISummary
-- All five KPIs in one row, optionally filtered to a branch, a loan
-- type, and/or an origination date range. Example:
--   EXEC lending.usp_GetPortfolioKPISummary @BranchID = 2;
--   EXEC lending.usp_GetPortfolioKPISummary
--        @OriginationStartDate = '2025-01-01', @OriginationEndDate = '2025-12-31';
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE lending.usp_GetPortfolioKPISummary
    @BranchID               INT  = NULL,
    @LoanTypeID              INT  = NULL,
    @OriginationStartDate     DATE = NULL,
    @OriginationEndDate       DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    WITH Filtered AS (
        SELECT *
        FROM lending.vw_LoanPortfolioBase
        WHERE (@BranchID IS NULL OR BranchID = @BranchID)
          AND (@LoanTypeID IS NULL OR LoanTypeID = @LoanTypeID)
          AND (@OriginationStartDate IS NULL OR OriginationDate >= @OriginationStartDate)
          AND (@OriginationEndDate IS NULL OR OriginationDate <= @OriginationEndDate)
    ),
    CostOfFunds AS (
        SELECT CAST(ParamValue AS DECIMAL(10,6)) AS Rate
        FROM lending.InstitutionParameters WHERE ParamName = 'CostOfFundsRate'
    )
    SELECT
        COUNT(*)                                                   AS TotalLoanCount,
        SUM(LoanAmount)                                            AS TotalOriginatedAmount,

        SUM(CASE WHEN IsActive = 1 THEN 1 ELSE 0 END)              AS ActiveLoanCount,
        SUM(CASE WHEN IsActive = 1 THEN OutstandingBalance ELSE 0 END) AS ActiveBalance,
        SUM(CASE WHEN IsActive = 1 AND IsDelinquent = 1 THEN OutstandingBalance ELSE 0 END)
            / NULLIF(SUM(CASE WHEN IsActive = 1 THEN OutstandingBalance ELSE 0 END), 0)
                                                                    AS DelinquencyRateByBalance,

        SUM(ChargeOffAmount)                                       AS TotalChargeOffAmount,
        SUM(ChargeOffAmount) / NULLIF(SUM(LoanAmount), 0)          AS ChargeOffRateByAmount,

        SUM(CASE WHEN IsSecured = 1 THEN LoanAmount ELSE 0 END)
            / NULLIF(SUM(CASE WHEN IsSecured = 1 THEN CollateralValue ELSE 0 END), 0)
                                                                    AS WeightedAvgLTV,

        (SUM(CASE WHEN IsActive = 1 THEN OutstandingBalance * InterestRate ELSE 0 END)
            - SUM(CASE WHEN IsActive = 1 THEN OutstandingBalance ELSE 0 END) * (SELECT Rate FROM CostOfFunds))
            / NULLIF(SUM(CASE WHEN IsActive = 1 THEN OutstandingBalance ELSE 0 END), 0)
                                                                    AS NetInterestMargin
    FROM Filtered;
END
GO

-- ---------------------------------------------------------------------
-- usp_GetKPIByDimension
-- All five KPIs broken down by Branch, LoanOfficer, or MemberSegment --
-- the three drill-downs the Power BI report needs. @GroupBy is matched
-- against a fixed whitelist (never concatenated directly into the SQL
-- string) before being used to build the dynamic GROUP BY, so this is
-- safe against SQL injection despite building the query dynamically.
-- Example:
--   EXEC lending.usp_GetKPIByDimension @GroupBy = 'Branch';
--   EXEC lending.usp_GetKPIByDimension @GroupBy = 'MemberSegment';
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE lending.usp_GetKPIByDimension
    @GroupBy VARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @GroupByColumn NVARCHAR(50) = CASE @GroupBy
        WHEN 'Branch'        THEN N'BranchName'
        WHEN 'LoanOfficer'   THEN N'LoanOfficerName'
        WHEN 'MemberSegment' THEN N'MemberSegment'
        ELSE NULL
    END;

    IF @GroupByColumn IS NULL
    BEGIN
        RAISERROR('Invalid @GroupBy value. Use ''Branch'', ''LoanOfficer'', or ''MemberSegment''.', 16, 1);
        RETURN;
    END;

    DECLARE @sql NVARCHAR(MAX) = N'
    SELECT
        ' + @GroupByColumn + N' AS GroupValue,
        COUNT(*) AS TotalLoanCount,
        SUM(CASE WHEN IsActive = 1 THEN 1 ELSE 0 END) AS ActiveLoanCount,
        SUM(CASE WHEN IsActive = 1 THEN OutstandingBalance ELSE 0 END) AS ActiveBalance,
        SUM(CASE WHEN IsActive = 1 AND IsDelinquent = 1 THEN OutstandingBalance ELSE 0 END)
            / NULLIF(SUM(CASE WHEN IsActive = 1 THEN OutstandingBalance ELSE 0 END), 0) AS DelinquencyRateByBalance,
        SUM(ChargeOffAmount) / NULLIF(SUM(LoanAmount), 0) AS ChargeOffRateByAmount,
        SUM(CASE WHEN IsSecured = 1 THEN LoanAmount ELSE 0 END)
            / NULLIF(SUM(CASE WHEN IsSecured = 1 THEN CollateralValue ELSE 0 END), 0) AS WeightedAvgLTV
    FROM lending.vw_LoanPortfolioBase
    GROUP BY ' + @GroupByColumn + N'
    ORDER BY ActiveBalance DESC;';

    EXEC sp_executesql @sql;
END
GO

PRINT 'Stored procedures created: usp_GetPortfolioKPISummary, usp_GetKPIByDimension';
