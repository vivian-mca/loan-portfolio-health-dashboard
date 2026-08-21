# Loan Portfolio Health Dashboard: Technical Walkthrough

This is a full walkthrough of the project: what was built, why it was built that way, and the real problems hit along the way. It’s designed to serve two audiences simultaneously: anyone evaluating the project can read straight through and follow the full rationale behind each decision made.

---

## 1. The Business Problem

A credit union makes money by lending money it holds on behalf of members, at an interest rate higher than what it pays those members for their deposits. The entire business model depends on two things staying in balance:

1. **Loans keep getting paid back.** If too many loans go delinquent or get charged off (written off as uncollectible), the credit union loses principal it can never recover, and its capital cushion shrinks.
2. **The spread between what's earned on loans and what's paid on deposits stays positive and healthy.** This gap, the **net interest margin**, functions much like a gross profit margin for the institution.

A **Loan Portfolio Health Dashboard** exists to answer, at a glance and on a recurring basis, five questions a credit union's board, CFO, and VP of Lending genuinely lose sleep over:

| Question | KPI |
|---|---|
| How much of what we've lent is currently past due? | **Delinquency Rate** |
| How much have we already had to write off as a loss? | **Charge-Off Rate** |
| If a borrower stops paying, how much of the collateral's value have we already lent against? | **Loan-to-Value (LTV) Ratio** |
| Are we actually making money on the spread between loan income and the cost of the deposits funding those loans? | **Net Interest Margin (NIM)** |
| Are we dangerously overexposed to one type of loan (e.g., 80% auto loans) if that market turns? | **Loan Concentration by Type** |

**Why the breakdowns matter as much as the top-line numbers:** A portfolio-wide delinquency rate of 3% can easily hide underlying issues. Every branch might be sitting at a healthy 3%, or four branches could sit at 0.5% while a single location spikes to 15%. Segmenting each KPI by **branch**, **loan officer**, and **member tier** transforms high-level metrics into actionable information. It lets team members flag specific operational issues, such as investigating performance at a single location, rather than relying on misleading averages.

---

## 2. Environment / Docker Setup

### Why Docker, and why SQL Server specifically

Since SQL Server lacks native macOS support, running it via a Docker container is the standard way to set up a local development environment on a Mac. Microsoft provides an official Linux container image ([mcr.microsoft.com/mssql/server](https://mcr.microsoft.com/mssql/server)), which allows you to run full SQL Server with complete T-SQL features like stored procedures, BULK INSERT, and window functions directly on your machine.

### What's in `docker-compose.yml`

```yaml
services:
  sqlserver:
    image: mcr.microsoft.com/mssql/server:2022-latest
    environment:
      ACCEPT_EULA: "Y"
      MSSQL_SA_PASSWORD: "${MSSQL_SA_PASSWORD}"
      MSSQL_PID: "Developer"
    ports:
      - "1433:1433"
    volumes:
      - sqlserver_data:/var/opt/mssql          # database files persist across restarts
      - ./data/processed:/var/opt/mssql/import:ro   # CSVs, visible inside the container
      - ./sql:/var/opt/mssql/scripts:ro              # SQL scripts, visible inside the container
```
**Key Architecture Decisions**

- **`MSSQL_PID: Developer`**: This sets the container to Microsoft's free Developer edition. It provides the full enterprise SQL Server feature set licensed specifically for non-production development, making it ideal for a realistic portfolio environment.
- **Named volume vs. Bind mounts**: The database uses a named volume (sqlserver_data) so data persists even when stopping or recreating containers. Source files like SQL scripts and CSVs are mounted directly from the repository as read-only directories. This configuration lets the container access local files safely without altering version-controlled project data.
- **Environment variables for credentials**: Sensitive values like passwords reside in a local, git-ignored `.env` file instead of hardcoding them in `docker-compose.yml`. The Compose file references `${MSSQL_SA_PASSWORD}` dynamically, following production security standards by keeping secrets out of source control.

### Step-by-step setup

```bash
# 1. Install Docker (Colima is a lightweight, CLI-only alternative to Docker Desktop —
#    no GUI, no privileged-helper install, works great for this)
brew install colima docker
colima start --cpu 2 --memory 4

# 2. Set your local SA password (never commit this file)
cp .env.example .env
# edit .env and set MSSQL_SA_PASSWORD to something meeting SQL Server's complexity rules
# (8+ chars, upper+lower+digit+symbol)

# 3. Start SQL Server
docker compose up -d

# 4. Wait until the healthcheck passes (docker-compose.yml polls sqlcmd every 10s)
docker compose ps

# 5. Get the real, public data (requires a Kaggle account + API token, see below)
./scripts/download_data.sh

# 6. Build the dataset (cleans the real data, adds the synthetic fields, writes CSVs)
pip3 install pandas numpy
python3 scripts/build_dataset.py

# 7. Run every SQL script in order: schema -> load -> views -> procedures
./scripts/run_sql.sh
```

**Getting a Kaggle API credential** (needed for step 5): on kaggle.com, go to Settings → API, and create a token. Depending on which flow Kaggle gives you, you'll either get a `kaggle.json` file (save it to `~/.kaggle/kaggle.json`) or a token string to save at `~/.kaggle/access_token`. Either is picked up automatically by the `kaggle` CLI (`pip3 install kaggle`).

### Where the data actually comes from

This project uses a **hybrid** approach to balance real-world patterns with institutional realism.

The base dataset comes from Kaggle's [`zaurbegiev/my-dataset`](https://www.kaggle.com/datasets/zaurbegiev/my-dataset) ("Bank Loan Status Dataset"), which contains roughly 100,000 peer-to-peer personal loan records. It provides realistic credit scores, incomes, loan purposes, terms, and repayment outcomes.

To make this dataset reflect how a real credit union operates, three adjustments were made:
1. **Adding institutional structure**: Peer-to-peer loans do not involve physical branches or loan officers. Fields like branch location, assigned loan officer, interest rates, and collateral value were generated synthetically to match a fictional six-branch Texas credit union.
2. **Fixing unrealistic numbers**: The source dataset includes some unusual numbers, such as a median annual income over $1.1M. Instead of using those values directly, `scripts/build_dataset.py` rescales the figures into realistic dollar amounts while keeping each borrower's original rank relative to others.
3. **Expanding product variety**: Personal loan datasets rarely include auto loans or mortgages. Because credit union portfolios heavily feature both, 9,500 synthetic auto and mortgage loans were generated with realistic rates and loan-to-value ratios, then added to the member base.

**What Is Real vs. Synthetic**
- **Real**: Member credit scores relative to peers, income tiers, debt ratios, loan purposes, and payoff or default outcomes for personal loans.
- **Synthetic**: Adjusted dollar amounts, interest rates, payment dates, branch assignments, loan officers, active delinquency tracking, and the auto/mortgage loan records.

**Reproducibility & Licensing**
Because the source data's Kaggle license is listed as "unknown," the raw and processed CSV files are excluded from this repository. The dataset generation script uses a fixed random seed `(RANDOM_SEED = 42)`, allowing anyone with access to the original Kaggle dataset to generate the exact same data locally.

---

## 3. Schema Design and Reasoning

### The shape: one fact table, four dimensions, one parameter table

```
Branches ──┐
           ├─→ Loans ←── LoanTypes
LoanOfficers ┘  ↑
                 │
              Members

InstitutionParameters (standalone reference table)
```
- **`lending.Loans`** is the central fact table. Each row represents an individual loan, defining the base level of detail for all higher-level aggregations.
- **`lending.Members`**, **`lending.Branches`**, **`lending.LoanOfficers`**, and `**lending.LoanTypes**` serve as dimension tables. These provide the context (who/where/what kind) used to slice and filter each metric.
- **`lending.InstitutionParameters`** holds portfolio-level variables, such as the cost-of-funds rate required for Net Interest Margin calculations. Storing this value in a configuration table rather than hardcoding it into SQL views allows financial assumptions to be updated without altering underlying code.

Organizing these tables into a star schema aligns with standard data modeling practices. Aggregations like `SUM()` and `GROUP BY` perform efficiently in this structure, and DAX measures in Power BI can easily drill down across dimensions without requiring custom SQL queries.

### Why borrower risk fields belong on `Members`

Credit score, annual income, monthly debt, and debt-to-income ratio describe the individual borrower rather than an isolated loan. When a member holds multiple accounts (for example, an auto loan and a personal loan), storing credit scores on both loan records creates redundancy and risks data inconsistency if one record updates while the other does not.

### Why `CurrentStatus` is a single column with a `CHECK` constraint instead of a separate status-history table

Production banking databases often store full status transaction logs tracking every historical state change. This project intentionally models a **point-in-time snapshot** reflecting current loan standings, which satisfies all primary KPI requirements without adding unnecessary complexity.

To preserve data integrity, `CHECK` constraints enforce logical consistency across fields. For instance, a constraint prevents conflicting states, such as a loan marked as charged off while still showing an active balance, catching data entry errors at write time before they reach downstream reporting layers.

```sql
CONSTRAINT CK_Loans_ChargeOffConsistency CHECK (
    (ChargeOffFlag = 1 AND CurrentStatus = 'Charged Off' AND OutstandingBalance = 0)
    OR (ChargeOffFlag = 0 AND CurrentStatus <> 'Charged Off')
)
```

This constraint prevents invalid data loads or manual updates from creating contradictory records, such as marking a loan as charged off while retaining an active balance. Validating business rules at write time stops data quality errors from propagating downstream into reporting views.

### Why indexes were added where they were

The `lending.Loans` table includes non-clustered indexes on all foreign keys (`MemberID`, `BranchID`, `LoanOfficerID`, `LoanTypeID`) as well as `CurrentStatus` and `OriginationDate`. Because every KPI view filters, groups, or joins on these specific fields, indexing them mirrors production database practices for query performance at scale.

---

## 4. The KPIs Definitions & Business Logic

All five KPIs build upon a foundational view, `lending.vw_LoanPortfolioBase`. This view joins Loans to every dimension table and defines two standardized status flags:

- **`IsActive`**: Identifies loans currently on the books that generate interest income (excluding Paid Off or Charged Off accounts).
- **`IsDelinquent`**: Identifies loans that are 30 or more days past due, ignoring short grace periods where `DelinquencyDays` remains zero.

Defining these once, in one view, means every KPI's definition of "active" and "delinquent" has consistent business logic across every downstream report.

### KPI 1: Delinquency Rate (`vw_KPI_DelinquencyRate`)

**Delinquency rate:** Measures the percentage of active loan balances currently 30 or more days past due.

**Why is it balance-weighted, not just a count:** Evaluating delinquency by balance rather than loan count properly reflects financial risk. A delinquent $400,000 mortgage impacts liquidity far more than a delinquent $300 personal loan. The view reports both metrics: `DelinquencyRateByCount` (volume counts for collections staffing/management) and `DelinquencyRateByBalance` (how many dollars are at risk).

```sql
SUM(CASE WHEN IsDelinquent = 1 THEN OutstandingBalance ELSE 0 END)
    / NULLIF(SUM(OutstandingBalance), 0)
```

The `NULLIF(..., 0)` expression prevents division-by-zero errors when filtering down to subsets with zero active loans.

### KPI 2: Charge-Off Rate (`vw_KPI_ChargeOffRate`)

**Charge-off rate:** Measures total written-off losses relative to total cumulative originations.

```sql
SUM(ChargeOffAmount) / NULLIF(SUM(LoanAmount), 0)
```

Standard institutional reporting typically tracks *net charge-offs* against *average outstanding balance* over a rolling twelve-month window. This project's version is a simplified, **cumulative, non-annualized** ratio (total charge-offs ever, divided by total ever originated) based on the available point-in-time snapshot, using `usp_GetPortfolioKPISummary`'s `@OriginationStartDate`/`@OriginationEndDate` parameters. This is not the same as an annualized rate against average balance. Check out Section 6 which addresses what real payments/balance-history table would add.

### KPI 3: Loan-to-Value (LTV) Ratio (`vw_KPI_LoanToValue`)

**Loan-to-value ratio:** Evaluates collateral coverage for secured products like auto loans and mortgages by comparing financed amounts against asset values.

Because unsecured personal loans carry no collateral, `CollateralValue` is `NULL` for those records, and the calculation applies exclusively `WHERE IsSecured = 1`,

```sql
SUM(LoanAmount) / NULLIF(SUM(CollateralValue), 0)   -- weighted average (the one that matters)
AVG(LoanAmount / NULLIF(CollateralValue, 0))          -- simple average, reported for context
```

**Why weighted is the "real" number:** A simple average treats a $5,000 loan and a $500,000 loan as equally important to the average. A weighted average (total financed divided by total collateral) reflects true portfolio dollar exposure, preventing small loans from distorting the overall metric. The view also flags accounts exceeding 90% LTV to monitor high-risk exposure (`LoansOverNinetyPctLTV`).

### KPI 4: Net Interest Margin (`vw_KPI_NetInterestMargin`)

**Net interest margin:** Measures the spread between interest earned on loans and interest paid on funding deposits.

```sql
AnnualInterestIncome  = SUM(OutstandingBalance * InterestRate)
AnnualInterestExpense = SUM(OutstandingBalance) * CostOfFundsRate
NetInterestMargin     = (AnnualInterestIncome - AnnualInterestExpense) / SUM(OutstandingBalance)
```
The cost of funds rate originates from `lending.InstitutionParameters` (set at 2.75%), representing a plausible blended rate a credit union might pay across all its deposit/savings products. In production environments, `Net Interest Margin` evaluates average daily balances across time periods rather than static snapshot balances.

### KPI 5: Loan Concentration by Type (`vw_KPI_LoanConcentrationByType`)

**Loan concentration by type:** Calculates the proportion of active balances tied up in each product type to evaluate portfolio diversification.

```sql
SUM(OutstandingBalance) / NULLIF(SUM(SUM(OutstandingBalance)) OVER (), 0) AS PctOfActiveBalance
```

The nested `SUM(SUM(...)) OVER ()` is a window function applied *after* the `GROUP BY` (the inner `SUM(OutstandingBalance)`) computes each loan type's total. The outer windowed `SUM(...) OVER ()` adds all those group totals back together to get the portfolio grand total, all in a single query without requiring additional self-joins.

---

## 5. Power BI Dashboard Steps

### Data connection setup

The original plan was Power BI Desktop connecting live to the Dockerized SQL Server. In practice, that path turned into hours of real infrastructure debugging on a 16GB Mac trying to run two virtual machines at once (Colima for Docker, plus a VMware Fusion VM for Windows/Power BI Desktop, since Power BI Desktop is Windows-only): a stuck first connection attempt that turned out to be a cached wrong password silently retrying forever, a working connection that later died because the Mac went to sleep mid-transfer and killed the VM's network state, and finally 80%+ swap usage from running both VMs simultaneously making everything crawl.

Rather than keep fighting the VM, the pragmatic call was to **switch to Power BI Service (the browser-based version)** and use a **static Excel export** instead of a live SQL connection:

1. Ran a query against `lending.vw_LoanPortfolioBase` directly in the container (`sqlcmd`), exported the result to CSV, then converted it to a proper Excel Table (`.xlsx`) with `openpyxl` — see the export step recorded in this project's history if you want to reproduce it.
2. Power BI Service's own "upload a local file" option turned out to be restricted on this account/tenant (a common enterprise-lite setting), which was confirmed by testing two different upload paths that both silently failed or greyed out the file. The workaround: uploaded the `.xlsx` to **OneDrive** first (a completely different, unrestricted upload flow), then in Power BI used **Get Data → Excel → "Link to file"** pointed at the OneDrive URL, instead of "Upload file."
3. In the Navigator, the workbook showed the same table twice (once as a raw worksheet, once as the named Excel Table) because the sheet and the table happened to share a name.

**The practical consequence:** The semantic model's table is called **`LoanPortfolioBase`**, not `vw_LoanPortfolioBase` like the SQL Server version since Excel doesn't carry over the SQL view name. Every DAX formula below uses `LoanPortfolioBase[...]`.

### Core DAX measures

1. **Action Balance**: Measures total outstanding balances on active accounts that have not resolved to Paid Off or Charged Off status, representing the primary earning assets of the portfolio.

```dax
Active Balance =
CALCULATE(SUM(LoanPortfolioBase[OutstandingBalance]), LoanPortfolioBase[IsActive] = 1)
```
2. **Delinquent Balance**: Filters active loans specifically to accounts that are 30 or more days past due, providing the numerator required for delinquency rate calculations.

```dax
Delinquent Balance =
CALCULATE(
    SUM(LoanPortfolioBase[OutstandingBalance]),
    LoanPortfolioBase[IsActive] = 1,
    LoanPortfolioBase[IsDelinquent] = 1
)
```
3. **Delinquency Rate**: Uses `DIVIDE` rather than standard division (`/`) to safely handle zero-value denominators, returning a blank result instead of a calculation error when filters yield zero active accounts.

```dax
Delinquency Rate =
DIVIDE([Delinquent Balance], [Active Balance])
```
4. **Charge-Off Rate**: Evaluates cumulative losses against total originated loan amounts rather than `[Active Balance]`, avoiding artificial rate inflation caused by removing inactive accounts from the denominator.

```dax
Charge-Off Rate =
DIVIDE(SUM(LoanPortfolioBase[ChargeOffAmount]), SUM(LoanPortfolioBase[LoanAmount]))
```

5. **Weighted Average LTV**: Divides total secured loan balances by total collateral value. Calculating a weighted ratio across totals prevents small individual loans from distorting the overall portfolio collateral risk.

```dax
Secured Loan Amount =
CALCULATE(SUM(LoanPortfolioBase[LoanAmount]), LoanPortfolioBase[IsSecured] = 1)

Secured Collateral Value =
CALCULATE(SUM(LoanPortfolioBase[CollateralValue]), LoanPortfolioBase[IsSecured] = 1)

Weighted Avg LTV =
DIVIDE([Secured Loan Amount], [Secured Collateral Value])
```
6. **Cost of Funds Rate**: Applies a fixed baseline funding cost rate. Production setups can replace this constant with a dynamic reference to a dedicated parameters table.

```dax
Cost of Funds Rate = 0.0275
```

7. **Net Interest Margin**: Uses `SUMX` to iterate row by row across active accounts, multiplying individual loan balances by their specific interest rates before summing total income. Variables store intermediate income and expense values to keep the return statement readable.

```dax
Net Interest Margin =
VAR InterestIncome =
    SUMX(
        FILTER(LoanPortfolioBase, LoanPortfolioBase[IsActive] = 1),
        LoanPortfolioBase[OutstandingBalance] * LoanPortfolioBase[InterestRate]
    )
VAR InterestExpense = [Active Balance] * [Cost of Funds Rate]
RETURN
    DIVIDE(InterestIncome - InterestExpense, [Active Balance])
```
8. **Total Active Loans**: Uses `COUNTROWS` to track active loan volume counts rather than dollar values.

```dax
Total Active Loans =
CALCULATE(COUNTROWS(LoanPortfolioBase), LoanPortfolioBase[IsActive] = 1)
```

For Loan Concentration, placing `[Active Balance]` directly into a donut chart with LoanTypeName as the legend allows Power BI to calculate percentage-of-total distributions automatically without requiring an additional measure.

### Dashboard troubleshooting

1. **Circular dependency error on `Weighted Avg LTV`.** Turned out `Secured Collateral Value` had never actually been created, a step got skipped. Power BI's error message ("circular dependency... Measure: X, Measure: X") was confusing at first glance, but the fix was simply going back and creating the missing measure. Lesson: when a DAX error blames a measure for depending on itself, check whether that measure actually exists yet.
2. **`SUM` failed with "cannot work with values of type String" on `Secured Collateral Value`.** The `CollateralValue` column had imported as **Text**, not a number — because it's blank for ~15,500 unsecured loans and numeric for the rest, and Power Query's automatic type detection got confused by that mix. Confirmed by checking the Data pane: numeric columns show a Σ (summarize) icon, and this one didn't. Fixed in Model view → click the column → Properties → Formatting → Data type → change to **Decimal Number**.
3. **The origination-trend line chart rendered as noisy daily static, with the x-axis showing raw numbers like `44000`–`46000` instead of dates.** Same root cause as #2: `OriginationDate` had imported as a plain number — those are literally Excel's internal date serial numbers — so Power BI had no date hierarchy to group by and plotted every unique value as a separate point. Fixed the same way: change the column's Data type to **Date**. (`ChargeOffDate` threw a transient "semantic model out of sync" error when set to Date specifically, but went through fine as **Date/time** instead — a fine substitute since none of this data has real time-of-day precision anyway.)
4. **Four slicers turned into one combined hierarchical slicer.** Dragging `BranchName`, `LoanTypeName`, `MemberSegment`, and `OriginationDate` one after another all landed in the *same* slicer visual's Field well, producing one nested checkbox tree instead of four independent filters. The fix, and the habit going forward: click "Slicer" again to create a brand-new visual *before* dragging in each additional field — never add a second field to a slicer that already has one, unless a combined hierarchy slicer is actually what you want.
5. **All the KPI cards suddenly showed different, smaller numbers** (a delinquency rate of ~20% instead of 9.35%, active balance of $4.98M instead of $768.67M). Nothing was broken — a slice of the donut chart (Home Improvement, which happens to total almost exactly $4.98M in active balance) had gotten clicked, and **Power BI cross-filters every visual on a page by default** when you click a data point. Clicking the same slice again (or clicking empty canvas) cleared the selection. Worth understanding deliberately: this default cross-filtering behavior is *also* what makes slicers and drill-throughs work — it's a feature, but it can surprise you mid-build.
6. **The `OriginationDate` slicer initially listed every individual day as its own checkbox** (~2,000 rows to scroll through) — because the default slicer style is "List." Changed via Format visual → Slicer settings → Options → Style → **"Between"**, which turns a date field into a proper two-box date-range picker with a range slider, instead of an unusable wall of checkboxes.

### Visuals Layout & Report Design

**Page 1: "Portfolio overview":**
1. **KPI header cards:** five cards featuring Delinquency Rate, Charge-Off Rate, Weighted Avg LTV, Net Interest Margin, Active Balance.
2. **"Active balance by loan type" donut chart:** `LoanTypeName` as legend, `[Active Balance]` as values. Confirms the ~81%-mortgage-by-balance concentration finding.
3. **"Delinquency Rate by member segment" column chart:** `MemberSegment` on the X-axis, `[Delinquency Rate]` as the Y-axis, showing risk distribution across credit tiers
4. **"Loan volume by year" line chart:** `OriginationDate` (as a proper date hierarchy after the fix above) on the X-axis, count of `LoanID` on the Y-axis.
5. **Interactive page slicers:** Branch, Loan Type, and Member Segment as **Dropdown** style; Origination Date as **Between** style (a real date-range picker).

**Page 2: "Branch officer & detail":**
1. **KPI performance by branch table:** `BranchName`, `[Active Balance]`, `[Delinquency Rate]`, `[Charge-Off Rate]`, `[Weighted Avg LTV]`, sorted descending by Active Balance (click the column header to sort).
2. **Top loan officers table:** `LoanOfficerName`, `BranchName`, `[Active Balance]`, sorted descending.
3. **Branch by loan type matrix:** `BranchName` on rows, `LoanTypeName` on columns, `[Active Balance]` as values, with **conditional formatting → background color → gradient** turned on (Format visual → Cell elements → Background color → the small `fx` icon) so the dollar amounts render as a heatmap instead of a plain number grid.
4. **Dedicated branch slicer:** A standalone dropdown filter allowing focused branch analysis without altering Page 1 filter states.

### Navigation Architecture

The report uses two dedicated page tabs paired with independent slicers on each page to provide full interactive filtering.

Direct visual drill-through from Page 1 to Page 2 was intentionally postponed during layout design. Right-click drill-through requires a source visual that uses the target field (`BranchName`) as a primary category. Because Page 1 focuses on portfolio-level trends by loan type, member segment, and origination year, Page 2 serves as a standalone detail view until a branch-level summary visual is added to Page 1.

---

## 6. What I'd Do Differently at Scale

Transitioning this snapshot project into a enterprise production reporting environment would involve several key architecture updates:

- **Add a real balance/payment history table.** The single biggest simplification here is that every KPI is computed off *today's snapshot*. There's no table of "what was the balance on this loan on each of the last 24 months." A real NIM or annualized charge-off rate needs a time series, not a point-in-time read. I'd add a `LoanBalanceHistory` (or `LoanTransactions`) fact table at a monthly or daily grain and recompute the KPIs as proper trailing-period aggregates.
- **Move from views to a proper semantic/aggregation layer for scale.** At 25,000 rows, views computed live on every query are instant. At the tens of millions of rows a real credit union's transaction history would produce, `vw_LoanPortfolioBase` recomputing five aggregate joins on every Power BI refresh would get slow. I'd introduce indexed views or a nightly ETL job that materializes daily KPI snapshots into a small summary table, and point Power BI at that instead of the live view.
- **Partition the fact table by origination date.** Once there's real transaction history, `Loans`/`LoanBalanceHistory` should be partitioned (e.g., by year) so both loads and time-filtered queries only touch the relevant partitions instead of scanning the whole table.
- **Separate the "current status" snapshot model from full status-history tracking**, using slowly changing dimensions (Type 2) on `Members` and a proper transaction-level `LoanStatusHistory` table, so it can answer "what did the portfolio look like on March 1st" instead of "what it looks like today?"
- **Move the SA password and connection details to a real secrets manager** (Azure Key Vault, AWS Secrets Manager, or at minimum a properly permissioned `.env` outside source control) instead of a local `.env` file.
- **Add row-level security in Power BI** so a branch manager only sees their own branch's data, not the whole portfolio — a real deployment of this dashboard would need that before any non-executive user got access.
- **Replace the synthetic branch/loan-officer/collateral data with the real system-of-record feeds** (loan origination system, core banking platform) via a proper ETL/ELT pipeline instead of a one-time CSV load.
- **Add the drill-through from Page 1 to Page 2 that got deliberately skipped** (see Section 5). Add a branch-level visual on the "Portfolio overview" page (e.g., a compact "Active Balance by Branch" bar chart) to serve as the right-click source, then wiring `BranchName` into Page 2's Drill-through field well.
- **Get a real live connection working between Power BI Desktop and SQL Server**, instead of the static Excel/OneDrive workaround this project ended up using (see Section 5).
