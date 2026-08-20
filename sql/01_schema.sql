/* =====================================================================
   01_schema.sql
   Loan Portfolio Health Dashboard -- database + table definitions

   Design notes (see docs/walkthrough.md Section 3 for the full write-up):
   - A dedicated LENDING schema (not dbo) so a real deployment could add
     other subject areas (deposits, cards, ...) without collisions.
   - Star-ish shape: Loans is the fact table; Members, Branches,
     LoanOfficers, LoanTypes are dimensions. InstitutionParameters holds
     the one portfolio-level assumption (cost of funds) the NIM KPI needs.
   - Borrower risk attributes (credit score, income, DTI) live on Members,
     not Loans, because they describe the person, not a specific loan --
     a member who takes out three loans still has one credit score.
   - CHECK constraints encode business rules directly in the schema
     (e.g. a loan can't be both charged off and carrying a balance) so bad
     data is rejected at load time instead of silently corrupting KPIs.
   ===================================================================== */

IF DB_ID(N'LoanPortfolioDB') IS NULL
BEGIN
    CREATE DATABASE LoanPortfolioDB;
END
GO

USE LoanPortfolioDB;
GO

IF SCHEMA_ID(N'lending') IS NULL
    EXEC('CREATE SCHEMA lending');
GO

-- Drop in dependency order so this script is safely re-runnable during development.
IF OBJECT_ID('lending.Loans', 'U') IS NOT NULL DROP TABLE lending.Loans;
IF OBJECT_ID('lending.Members', 'U') IS NOT NULL DROP TABLE lending.Members;
IF OBJECT_ID('lending.LoanOfficers', 'U') IS NOT NULL DROP TABLE lending.LoanOfficers;
IF OBJECT_ID('lending.Branches', 'U') IS NOT NULL DROP TABLE lending.Branches;
IF OBJECT_ID('lending.LoanTypes', 'U') IS NOT NULL DROP TABLE lending.LoanTypes;
IF OBJECT_ID('lending.InstitutionParameters', 'U') IS NOT NULL DROP TABLE lending.InstitutionParameters;
GO

-- ---------------------------------------------------------------------
-- Dimension: Branches
-- ---------------------------------------------------------------------
CREATE TABLE lending.Branches (
    BranchID    INT             NOT NULL PRIMARY KEY,
    BranchName  VARCHAR(100)    NOT NULL,
    City        VARCHAR(100)    NOT NULL,
    State       CHAR(2)         NOT NULL,
    Region      VARCHAR(50)     NOT NULL,
    OpenDate    DATE            NOT NULL
);
GO

-- ---------------------------------------------------------------------
-- Dimension: LoanOfficers
-- ---------------------------------------------------------------------
CREATE TABLE lending.LoanOfficers (
    LoanOfficerID   INT             NOT NULL PRIMARY KEY,
    FirstName       VARCHAR(50)     NOT NULL,
    LastName        VARCHAR(50)     NOT NULL,
    BranchID        INT             NOT NULL,
    HireDate        DATE            NOT NULL,
    CONSTRAINT FK_LoanOfficers_Branches
        FOREIGN KEY (BranchID) REFERENCES lending.Branches(BranchID)
);
GO
CREATE INDEX IX_LoanOfficers_BranchID ON lending.LoanOfficers(BranchID);
GO

-- ---------------------------------------------------------------------
-- Dimension: LoanTypes
-- ---------------------------------------------------------------------
CREATE TABLE lending.LoanTypes (
    LoanTypeID          INT             NOT NULL PRIMARY KEY,
    LoanTypeName        VARCHAR(50)     NOT NULL,
    IsSecured           BIT             NOT NULL,
    BaseInterestRate    DECIMAL(6,4)    NOT NULL
);
GO

-- ---------------------------------------------------------------------
-- Reference: InstitutionParameters
-- Small key/value table for portfolio-level assumptions (e.g. cost of
-- funds) that a KPI needs but that don't belong on any one loan or member.
-- Keeping it in a table -- instead of hardcoding the rate inside a view --
-- means Finance can update the assumption without a code change.
-- ---------------------------------------------------------------------
CREATE TABLE lending.InstitutionParameters (
    ParamName           VARCHAR(50)     NOT NULL PRIMARY KEY,
    ParamValue           DECIMAL(10,6)   NOT NULL,
    ParamDescription     VARCHAR(400)    NULL
);
GO

-- ---------------------------------------------------------------------
-- Dimension: Members (borrowers)
-- ---------------------------------------------------------------------
CREATE TABLE lending.Members (
    MemberID                INT             NOT NULL PRIMARY KEY,
    FirstName               VARCHAR(50)     NOT NULL,
    LastName                VARCHAR(50)     NOT NULL,
    HomeBranchID            INT             NOT NULL,
    MemberSinceDate         DATE            NOT NULL,
    CreditScore             SMALLINT        NOT NULL,
    AnnualIncome            DECIMAL(12,2)   NOT NULL,
    MonthlyDebt             DECIMAL(10,2)   NOT NULL,
    DebtToIncomeRatio       DECIMAL(6,4)    NOT NULL,
    YearsOfCreditHistory    DECIMAL(5,1)    NULL,
    YearsInJob              DECIMAL(4,1)    NULL,
    HomeOwnership           VARCHAR(30)     NULL,
    CreditTier              VARCHAR(20)     NOT NULL,
    IncomeTier              VARCHAR(20)     NOT NULL,
    MemberSegment           VARCHAR(40)     NOT NULL,
    CONSTRAINT FK_Members_Branches
        FOREIGN KEY (HomeBranchID) REFERENCES lending.Branches(BranchID),
    CONSTRAINT CK_Members_CreditScore CHECK (CreditScore BETWEEN 300 AND 850),
    CONSTRAINT CK_Members_CreditTier CHECK (CreditTier IN ('Excellent','Good','Fair','Subprime')),
    CONSTRAINT CK_Members_IncomeTier CHECK (IncomeTier IN ('High','Mid','Low'))
);
GO
CREATE INDEX IX_Members_HomeBranchID ON lending.Members(HomeBranchID);
CREATE INDEX IX_Members_MemberSegment ON lending.Members(MemberSegment);
GO

-- ---------------------------------------------------------------------
-- Fact: Loans
-- ---------------------------------------------------------------------
CREATE TABLE lending.Loans (
    LoanID              INT             NOT NULL PRIMARY KEY,
    SourceLoanID        VARCHAR(50)     NULL,     -- traceability back to the Kaggle source row; NULL for synthetic auto/mortgage loans
    MemberID            INT             NOT NULL,
    BranchID            INT             NOT NULL,
    LoanOfficerID       INT             NOT NULL,
    LoanTypeID          INT             NOT NULL,
    LoanAmount          DECIMAL(12,2)   NOT NULL,
    InterestRate        DECIMAL(6,4)    NOT NULL,
    TermMonths          SMALLINT        NOT NULL,
    OriginationDate     DATE            NOT NULL,
    MaturityDate        DATE            NOT NULL,
    OutstandingBalance  DECIMAL(12,2)   NOT NULL,
    CollateralValue     DECIMAL(12,2)   NULL,     -- populated only for secured loan types (Auto, Mortgage)
    CurrentStatus       VARCHAR(20)     NOT NULL, -- Current | 30-59 DPD | 60-89 DPD | 90+ DPD | Paid Off | Charged Off
    DelinquencyDays     SMALLINT        NOT NULL,
    ChargeOffFlag       BIT             NOT NULL,
    ChargeOffAmount     DECIMAL(12,2)   NOT NULL,
    ChargeOffDate        DATE            NULL,
    CONSTRAINT FK_Loans_Members
        FOREIGN KEY (MemberID) REFERENCES lending.Members(MemberID),
    CONSTRAINT FK_Loans_Branches
        FOREIGN KEY (BranchID) REFERENCES lending.Branches(BranchID),
    CONSTRAINT FK_Loans_LoanOfficers
        FOREIGN KEY (LoanOfficerID) REFERENCES lending.LoanOfficers(LoanOfficerID),
    CONSTRAINT FK_Loans_LoanTypes
        FOREIGN KEY (LoanTypeID) REFERENCES lending.LoanTypes(LoanTypeID),
    CONSTRAINT CK_Loans_CurrentStatus CHECK (CurrentStatus IN
        ('Current','30-59 DPD','60-89 DPD','90+ DPD','Paid Off','Charged Off')),
    CONSTRAINT CK_Loans_ChargeOffConsistency CHECK (
        (ChargeOffFlag = 1 AND CurrentStatus = 'Charged Off' AND OutstandingBalance = 0)
        OR (ChargeOffFlag = 0 AND CurrentStatus <> 'Charged Off')
    ),
    CONSTRAINT CK_Loans_LoanAmount CHECK (LoanAmount > 0),
    CONSTRAINT CK_Loans_MaturityAfterOrigination CHECK (MaturityDate > OriginationDate)
);
GO
CREATE INDEX IX_Loans_MemberID ON lending.Loans(MemberID);
CREATE INDEX IX_Loans_BranchID ON lending.Loans(BranchID);
CREATE INDEX IX_Loans_LoanOfficerID ON lending.Loans(LoanOfficerID);
CREATE INDEX IX_Loans_LoanTypeID ON lending.Loans(LoanTypeID);
CREATE INDEX IX_Loans_CurrentStatus ON lending.Loans(CurrentStatus);
CREATE INDEX IX_Loans_OriginationDate ON lending.Loans(OriginationDate);
GO

PRINT 'Schema created: LoanPortfolioDB.lending (Branches, LoanOfficers, LoanTypes, InstitutionParameters, Members, Loans)';
