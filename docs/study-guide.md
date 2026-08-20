# Loan Portfolio Health Dashboard — Technical Walkthrough

This is a full walkthrough of the project: what was built, why it was built that way, and the real problems hit along the way. It serves two audiences at once — anyone reviewing this project can read it top to bottom for the complete reasoning behind every decision, and it's written so I can use it as a reference to rebuild pieces from memory or explain the project in an interview.

---

## 1. The Business Problem

A credit union makes money by lending money it holds on behalf of members, at an interest rate higher than what it pays those members for their deposits. The entire business model depends on two things staying in balance:

1. **Loans keep getting paid back.** If too many loans go delinquent or get charged off (written off as uncollectible), the credit union loses principal it can never recover, and its capital cushion shrinks.
2. **The spread between what's earned on loans and what's paid on deposits stays positive and healthy.** That spread — net interest margin — is essentially the credit union's gross profit margin.

A **Loan Portfolio Health Dashboard** exists to answer, at a glance and on a recurring basis, five questions a credit union's board, CFO, and VP of Lending genuinely lose sleep over:

| Question | KPI |
|---|---|
| How much of what we've lent is currently past due? | **Delinquency Rate** |
| How much have we already had to write off as a loss? | **Charge-Off Rate** |
| If a borrower stops paying, how much of the collateral's value have we already lent against? | **Loan-to-Value (LTV) Ratio** |
| Are we actually making money on the spread between loan income and the cost of the deposits funding those loans? | **Net Interest Margin (NIM)** |
| Are we dangerously overexposed to one type of loan (e.g., 80% auto loans) if that market turns? | **Loan Concentration by Type** |

These aren't abstract metrics — they're the numbers a NCUA examiner (the credit union industry's federal regulator) and the board's risk committee review every quarter. Being able to say "I built a dashboard that tracks exactly these five KPIs, broken down by branch, loan officer, and member risk segment" is a direct, credible answer to "why should we hire you as a Data Specialist" for a credit union.

**Why the breakdowns matter as much as the top-line numbers:** A portfolio-wide delinquency rate of 3% could mean every branch is a healthy 3%, or it could mean four branches are at 0.5% and one branch is at 15% and getting buried by that number. Breaking every KPI down by **branch**, **loan officer**, and **member segment** is what turns a vanity metric into something operations can act on — "go find out what's happening at the Fort Worth branch," not just "delinquency is fine on average."

---

## 2. Environment / Docker Setup

### Why Docker, and why SQL Server specifically

The job posting/role calls for SQL Server skills, and this is a Mac. SQL Server doesn't run natively on macOS — Microsoft ships it as a Linux container image (`mcr.microsoft.com/mssql/server`), so Docker is the standard way to run real SQL Server, with real T-SQL syntax (stored procedures, `BULK INSERT`, window functions), on a Mac laptop.

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

A few decisions worth being able to explain:

- **`MSSQL_PID: Developer`** — the free Developer edition. Full SQL Server feature set, licensed for development/learning only (not production). Exactly right for a portfolio project.
- **A named volume (`sqlserver_data`) for the database files, bind mounts for the CSVs/scripts.** The database itself should persist even if you tear down and recreate the container; the CSVs and SQL files are your source-controlled project files, mounted read-only so the container can read them but never write back into your repo.
- **Password in `.env`, not in `docker-compose.yml`.** The compose file references `${MSSQL_SA_PASSWORD}`; the actual value lives in a local `.env` file that's git-ignored. This is the same pattern used for any real secret — never commit a password to source control, even a throwaway local dev one.

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

### Where the data actually comes from (read this before you present the project)

This matters enough to call out explicitly, because it's the first thing a technically sharp interviewer will ask about: **"is this real data?"**

It's a **hybrid**. The real-data source is Kaggle's [`zaurbegiev/my-dataset`](https://www.kaggle.com/datasets/zaurbegiev/my-dataset) ("Bank Loan Status Dataset") — ~100,000 real peer-to-peer personal loan records with credit score, income, purpose, term, and a Fully-Paid/Charged-Off outcome. Two hard limits in that source data meant it couldn't be used as-is:

1. **No credit union ever tracks branch, loan officer, interest rate, origination date, or collateral value in a P2P lending dataset — because P2P platforms don't have branches or loan officers.** Those fields are 100% synthesized, matched to a fictional 6-branch Texas credit union footprint.
2. **The dataset's own dollar fields (loan amount, income, monthly debt) are not on a believable real-world scale** — e.g., its median reported annual income is over $1.1M, and loan amounts don't vary sensibly by purpose (a "medical bills" loan and a "debt consolidation" loan have the same distribution). This is a known quality issue in this particular Kaggle dataset. Rather than pass those numbers through, `scripts/build_dataset.py` **rank-preserves and rescales** them: each member/loan keeps its relative position (a borrower who looked relatively higher-income in the raw data still ends up relatively higher-income after rescaling) but lands in a realistic dollar band for that field.
3. **The source data has almost no auto loans or mortgages** (fewer than 2,000 combined, out of 100K rows) — because it's unsecured P2P personal lending. A credit union book is meaningfully auto- and mortgage-heavy, so those two loan types (9,500 of the 25,000 final loans) are generated as an entirely synthetic population with realistic amount/rate/LTV distributions, layered onto the same member base.

**What's real:** which members had which credit scores, incomes, and debt loads *relative to their peers*; which loan purposes they borrowed for; and — for the unsecured loans — whether that specific loan was ultimately paid off or charged off.

**What's synthetic:** exact dollar amounts (rescaled from real relative ranking), interest rates, origination/maturity dates, branch, loan officer, current delinquency status for still-open loans, and the entire auto-loan/mortgage population.

Being able to explain *why* each field is real vs. synthetic, unprompted, is a stronger interview answer than pretending it's all one or the other. It also demonstrates something the job actually needs: judgment about data quality, not just SQL syntax.

Because the source dataset's Kaggle license is listed as "unknown," the raw and processed CSVs are **not committed to this repo** (see `.gitignore`) — only the generation script is, with a fixed random seed (`RANDOM_SEED = 42`) so anyone with Kaggle access can reproduce the *exact* same dataset byte-for-byte.

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

- **`lending.Loans`** is the fact table — one row per loan, the grain everything else rolls up from.
- **`lending.Members`**, **`lending.Branches`**, **`lending.LoanOfficers`**, **`lending.LoanTypes`** are dimensions — the "who/where/what kind" that every KPI gets sliced by.
- **`lending.InstitutionParameters`** is a small key-value table holding the one portfolio-level assumption a KPI needs that doesn't belong to any single loan or member: the cost-of-funds rate used in Net Interest Margin. It's a table, not a hardcoded number in a view, specifically so Finance could update that assumption without a code change — a small thing, but it's the kind of decision that signals you're thinking about who maintains this after you.

This is a deliberate, textbook **star schema** shape — the same modeling pattern Power BI's own documentation recommends, because it's exactly what a `SUM()`/`GROUP BY` and DAX measures are optimized for, and it's what makes "drill down by branch" a one-click Power BI operation instead of a SQL rewrite.

### Why borrower risk fields live on `Members`, not `Loans`

Credit score, annual income, monthly debt, and debt-to-income ratio describe **the person**, not any one loan. A member who has both an auto loan and a personal loan still has exactly one credit score — storing it on both loan rows would be redundant, and worse, it would let the two rows silently disagree if one got updated and the other didn't. This is basic normalization (a value belongs where its natural key determines it, per Boyd-Codd), but it's worth being able to say out loud in an interview: *"I put credit score on Members because it's a property of the borrower, and a normalized schema doesn't repeat a fact in two places."*

### Why `CurrentStatus` is a single column with a `CHECK` constraint instead of a separate status-history table

A real core banking system would track full status history (every date a loan moved from Current to 30-days-late and back). This project models a **snapshot** — where every loan stands *as of today* — because that's what the five required KPIs need, and adding a full history table would be scope the KPIs don't use. The `CHECK` constraint —

```sql
CONSTRAINT CK_Loans_ChargeOffConsistency CHECK (
    (ChargeOffFlag = 1 AND CurrentStatus = 'Charged Off' AND OutstandingBalance = 0)
    OR (ChargeOffFlag = 0 AND CurrentStatus <> 'Charged Off')
)
```

— is there so that a bad load (or a future manual `UPDATE`) can't create a nonsensical row, like a loan marked charged off that still shows a $5,000 balance. Constraints like this catch data-quality bugs at write time instead of silently producing a wrong KPI three views downstream — which is a much worse place to discover them.

### Why indexes were added where they were

`lending.Loans` gets a non-clustered index on every foreign key (`MemberID`, `BranchID`, `LoanOfficerID`, `LoanTypeID`) plus `CurrentStatus` and `OriginationDate`, because every KPI view either joins on those foreign keys or filters/groups on those two columns. At 25,000 rows this project doesn't *need* indexes to be fast — but the habit of indexing what you know you'll `JOIN`/`WHERE`/`GROUP BY` on is worth demonstrating even at small scale, because it's exactly what breaks first at real scale if you never practiced it.

---

## 4. The KPIs — Business Logic in Plain Language

All five KPIs are built on top of one view, `lending.vw_LoanPortfolioBase`, which joins Loans to every dimension and pre-computes two flags used everywhere downstream:

- **`IsActive`** — is this loan still on the books? (Not yet Paid Off or Charged Off.) Only active loans are "earning assets" — a paid-off or charged-off loan isn't generating interest income anymore.
- **`IsDelinquent`** — is this loan 30+ days past due? A loan that's a few days late (inside a grace period) is not counted as delinquent; `DelinquencyDays` is 0 for anything in the `Current` bucket.

Defining these once, in one view, means every KPI's definition of "active" and "delinquent" is guaranteed to match — a very common real-world bug is when the delinquency dashboard and the charge-off dashboard quietly use different definitions of "active loan" and the numbers stop reconciling.

### KPI 1 — Delinquency Rate (`vw_KPI_DelinquencyRate`)

**Plain language:** Of all the loans still on the books, what fraction of the dollars owed is currently 30+ days late?

**Why balance-weighted, not just a count:** A delinquent $400,000 mortgage is a much bigger risk to the credit union's balance sheet than a delinquent $300 personal loan, even though both count as "one delinquent loan." The view reports both `DelinquencyRateByCount` (what collections staffing needs — how many accounts need a phone call) and `DelinquencyRateByBalance` (what the CFO needs — how many dollars are actually at risk).

```sql
SUM(CASE WHEN IsDelinquent = 1 THEN OutstandingBalance ELSE 0 END)
    / NULLIF(SUM(OutstandingBalance), 0)
```

`NULLIF(..., 0)` guards the division: if there are zero active loans (e.g., a branch-filtered query with no active loans left), this returns `NULL` instead of erroring out with a divide-by-zero.

### KPI 2 — Charge-Off Rate (`vw_KPI_ChargeOffRate`)

**Plain language:** Of everything the credit union has ever lent, what share has it had to give up on and write off as a loss?

```sql
SUM(ChargeOffAmount) / NULLIF(SUM(LoanAmount), 0)
```

**An honest caveat, worth stating out loud in an interview:** the industry-standard version of this metric is *net charge-offs / average outstanding loan balance, annualized* — a rate over a specific trailing period (e.g., trailing twelve months), computed against the average balance during that period. This project's version is a simplified, **cumulative, non-annualized** ratio (total charge-offs ever, divided by total ever originated), because there's no multi-period balance history table here — just today's snapshot. `usp_GetPortfolioKPISummary`'s `@OriginationStartDate`/`@OriginationEndDate` parameters let you approximate a period view by filtering to loans *originated* in a window, but that's not the same as an annualized rate against average balance. Section 6 talks about what a real payments/balance-history table would add.

### KPI 3 — Loan-to-Value (LTV) Ratio (`vw_KPI_LoanToValue`)

**Plain language:** For a secured loan (auto, mortgage), how much did we lend compared to what the collateral is actually worth? If a borrower stops paying and the credit union has to repossess/foreclose, LTV is a rough proxy for "will selling the collateral cover what's still owed."

LTV only applies to **secured** loans — there's no collateral behind a personal loan or a debt-consolidation loan, so `CollateralValue` is `NULL` for those, and the view filters to `WHERE IsSecured = 1`.

```sql
SUM(LoanAmount) / NULLIF(SUM(CollateralValue), 0)   -- weighted average (the one that matters)
AVG(LoanAmount / NULLIF(CollateralValue, 0))          -- simple average, reported for context
```

**Why weighted, not simple average, is the "real" number:** a simple average treats a $5,000 loan and a $500,000 loan as equally important to the average. The weighted version (total financed ÷ total collateral) reflects the actual dollar risk — a few large, low-LTV loans shouldn't hide a portfolio's exposure the way they can in a simple average. The view also flags `LoansOverNinetyPctLTV` — loans where the credit union has lent more than 90% of the collateral's value, a common internal risk threshold.

### KPI 4 — Net Interest Margin (`vw_KPI_NetInterestMargin`)

**Plain language:** the credit union earns interest on loans and pays interest on the deposits that fund those loans. NIM is what's left of that spread as a percentage — it's the closest thing a bank/credit union has to a profit margin.

```sql
AnnualInterestIncome  = SUM(OutstandingBalance * InterestRate)
AnnualInterestExpense = SUM(OutstandingBalance) * CostOfFundsRate
NetInterestMargin     = (AnnualInterestIncome - AnnualInterestExpense) / SUM(OutstandingBalance)
```

`CostOfFundsRate` comes from `lending.InstitutionParameters` — currently 2.75%, a plausible blended rate a credit union might pay across all its deposit/savings products.

**Simplification worth naming:** real NIM is computed against *average* earning assets over a period (e.g., average daily balance across a quarter), not a single snapshot balance. This project only has one snapshot (today), so `EarningAssets` here is "current outstanding balance," a reasonable stand-in for a portfolio-level demo but not what a bank's actual finance team would report externally.

### KPI 5 — Loan Concentration by Type (`vw_KPI_LoanConcentrationByType`)

**Plain language:** what percentage of the active portfolio is tied up in each loan product? A credit union that's 70% auto loans is much more exposed to a used-car-price crash than one with a diversified 25/25/25/25 split across auto, mortgage, personal, and business lending.

```sql
SUM(OutstandingBalance) / NULLIF(SUM(SUM(OutstandingBalance)) OVER (), 0) AS PctOfActiveBalance
```

The nested `SUM(SUM(...)) OVER ()` is a window function applied *after* the `GROUP BY` — the inner `SUM(OutstandingBalance)` computes each loan type's total, and the outer windowed `SUM(...) OVER ()` adds all those group totals back together to get the portfolio grand total, all in a single query with no self-join needed. This is a genuinely useful T-SQL pattern worth having in your back pocket for any "percent of total" calculation.

---

## 5. Power BI Dashboard Steps

*(This section is a manual build guide — everything in Power BI itself was built by hand, in the browser; nothing here could be built by an AI assistant, since it lives entirely inside the Power BI application. What follows is what was **actually** done, including the real problems hit along the way, not just the clean happy path.)*

### How the data actually got connected (read this first — it's not what Section 2 assumes)

The original plan was Power BI Desktop connecting live to the Dockerized SQL Server. In practice, that path turned into hours of real infrastructure debugging on a 16GB Mac trying to run two virtual machines at once (Colima for Docker, plus a VMware Fusion VM for Windows/Power BI Desktop, since Power BI Desktop is Windows-only): a stuck first connection attempt that turned out to be a cached wrong password silently retrying forever, a working connection that later died because the Mac went to sleep mid-transfer and killed the VM's network state, and finally 80%+ swap usage from running both VMs simultaneously making everything crawl.

Rather than keep fighting the VM, the pragmatic call was to **switch to Power BI Service (the browser-based version)** and use a **static Excel export** instead of a live SQL connection:

1. Ran a query against `lending.vw_LoanPortfolioBase` directly in the container (`sqlcmd`), exported the result to CSV, then converted it to a proper Excel Table (`.xlsx`) with `openpyxl` — see the export step recorded in this project's history if you want to reproduce it.
2. Power BI Service's own "upload a local file" option turned out to be restricted on this account/tenant (a common enterprise-lite setting) — confirmed by testing two different upload paths that both silently failed or greyed out the file. The workaround: uploaded the `.xlsx` to **OneDrive** first (a completely different, unrestricted upload flow), then in Power BI used **Get Data → Excel → "Link to file"** pointed at the OneDrive URL, instead of "Upload file."
3. In the Navigator, the workbook showed the same table twice (once as a raw worksheet, once as the named Excel Table) because the sheet and the table happened to share a name — picked the actual named Table.

**The practical consequence:** the semantic model's table is called **`LoanPortfolioBase`**, not `vw_LoanPortfolioBase` like the SQL Server version — Excel doesn't carry over the SQL view name. Every DAX formula below uses `LoanPortfolioBase[...]`. If you ever do get a live Desktop-to-SQL-Server connection working (e.g., on a machine that can natively run Power BI Desktop, or a cloud VM with a data gateway), the same DAX works unchanged — just swap the table name back to `vw_LoanPortfolioBase`.

This whole detour is worth being able to explain in an interview, honestly: it's a real example of hitting an infrastructure wall, recognizing when to stop fighting it, and re-scoping to a workaround that still delivers a fully-functional, interactive result — which is a more realistic day-in-the-life story than "everything connected on the first try."

### DAX measures — what was built, and why each one is shaped the way it is

Ten measures, all created via **Model view → New measure** (Power BI Service's Editing mode — the page opens in read-only "Viewing" mode by default, and you have to explicitly switch to "Editing" via a dropdown near the top right before any changes save).

```dax
Active Balance =
CALCULATE(SUM(LoanPortfolioBase[OutstandingBalance]), LoanPortfolioBase[IsActive] = 1)
```
The total dollars still owed on loans that haven't resolved to Paid Off or Charged Off — the "earning assets" figure everything else gets measured against.

```dax
Delinquent Balance =
CALCULATE(
    SUM(LoanPortfolioBase[OutstandingBalance]),
    LoanPortfolioBase[IsActive] = 1,
    LoanPortfolioBase[IsDelinquent] = 1
)
```
Same idea, narrowed to loans that are both active *and* 30+ days late — the numerator for delinquency rate.

```dax
Delinquency Rate =
DIVIDE([Delinquent Balance], [Active Balance])
```
`DIVIDE` instead of a plain `/` on purpose: `DIVIDE` returns `BLANK` instead of throwing an error when the denominator is 0 — which happens the moment a slicer filters down to a branch or segment with zero active loans. A plain `/` would break the visual entirely in that case.

```dax
Charge-Off Rate =
DIVIDE(SUM(LoanPortfolioBase[ChargeOffAmount]), SUM(LoanPortfolioBase[LoanAmount]))
```
Denominated against total *originated* amount, not `[Active Balance]` — a charged-off loan is by definition no longer active, so dividing by Active Balance would shrink the denominator exactly where the losses live, inflating the rate.

```dax
Secured Loan Amount =
CALCULATE(SUM(LoanPortfolioBase[LoanAmount]), LoanPortfolioBase[IsSecured] = 1)

Secured Collateral Value =
CALCULATE(SUM(LoanPortfolioBase[CollateralValue]), LoanPortfolioBase[IsSecured] = 1)

Weighted Avg LTV =
DIVIDE([Secured Loan Amount], [Secured Collateral Value])
```
Two separate SUM-based measures divided at the end, rather than one measure that averages each loan's individual LTV — averaging per-loan ratios would let a handful of small loans skew the number regardless of actual dollar exposure. This is the same weighted-vs-simple-average reasoning as the SQL version.

```dax
Cost of Funds Rate = 0.0275
```
A plain constant here, not pulled from a table. The real SQL Server version has a small `InstitutionParameters` table for exactly this so Finance can update the assumption without a code change — but the Excel-based Power BI model doesn't carry that table over, so a literal number is the pragmatic stand-in. Worth flagging as a "what I'd fix" if this became a real recurring report: add a tiny one-row parameters table and reference it here instead.

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
`SUMX` instead of a flat `SUM`, and this is the one worth really understanding: interest income has to be computed **per loan** (that loan's balance × that loan's own rate) and then summed, since every loan carries a different rate. `SUM(Balance) * AVERAGE(Rate)` is mathematically wrong here — it's not the same as a properly weighted calculation unless you multiply row-by-row first. `SUMX` iterates the table row by row for exactly this reason. The `VAR`s are just there for readability, so the income and expense pieces are named instead of repeating the `SUMX` expression twice.

```dax
Total Active Loans =
CALCULATE(COUNTROWS(LoanPortfolioBase), LoanPortfolioBase[IsActive] = 1)
```
`COUNTROWS`, not `SUM` — this one's a loan *count*, not a dollar total.

For **loan concentration**, no special measure was needed — `[Active Balance]` dropped straight into a donut chart with `LoanTypeName` as the legend does the job; Power BI computes the percentage-of-total automatically.

### Real bugs hit while building this, and what each one actually teaches

Worth keeping in the story for an interview — these aren't embarrassing, they're the actual mechanics of working in Power BI:

1. **Circular dependency error on `Weighted Avg LTV`.** Turned out `Secured Collateral Value` had never actually been created — a step got skipped. Power BI's error message ("circular dependency... Measure: X, Measure: X") was confusing at first glance, but the fix was simply going back and creating the missing measure. Lesson: when a DAX error blames a measure for depending on itself, check whether that measure actually exists yet.
2. **`SUM` failed with "cannot work with values of type String" on `Secured Collateral Value`.** The `CollateralValue` column had imported as **Text**, not a number — because it's blank for ~15,500 unsecured loans and numeric for the rest, and Power Query's automatic type detection got confused by that mix. Confirmed by checking the Data pane: numeric columns show a Σ (summarize) icon, and this one didn't. Fixed in Model view → click the column → Properties → Formatting → Data type → change to **Decimal Number**.
3. **The origination-trend line chart rendered as noisy daily static, with the x-axis showing raw numbers like `44000`–`46000` instead of dates.** Same root cause as #2: `OriginationDate` had imported as a plain number — those are literally Excel's internal date serial numbers — so Power BI had no date hierarchy to group by and plotted every unique value as a separate point. Fixed the same way: change the column's Data type to **Date**. (`ChargeOffDate` threw a transient "semantic model out of sync" error when set to Date specifically, but went through fine as **Date/time** instead — a fine substitute since none of this data has real time-of-day precision anyway.)
4. **Four slicers turned into one combined hierarchical slicer.** Dragging `BranchName`, `LoanTypeName`, `MemberSegment`, and `OriginationDate` one after another all landed in the *same* slicer visual's Field well, producing one nested checkbox tree instead of four independent filters. The fix, and the habit going forward: click "Slicer" again to create a brand-new visual *before* dragging in each additional field — never add a second field to a slicer that already has one, unless a combined hierarchy slicer is actually what you want.
5. **All the KPI cards suddenly showed different, smaller numbers** (a delinquency rate of ~20% instead of 9.35%, active balance of $4.98M instead of $768.67M). Nothing was broken — a slice of the donut chart (Home Improvement, which happens to total almost exactly $4.98M in active balance) had gotten clicked, and **Power BI cross-filters every visual on a page by default** when you click a data point. Clicking the same slice again (or clicking empty canvas) cleared the selection. Worth understanding deliberately: this default cross-filtering behavior is *also* what makes slicers and drill-throughs work — it's a feature, but it can surprise you mid-build.
6. **The `OriginationDate` slicer initially listed every individual day as its own checkbox** (~2,000 rows to scroll through) — because the default slicer style is "List." Changed via Format visual → Slicer settings → Options → Style → **"Between"**, which turns a date field into a proper two-box date-range picker with a range slider, instead of an unusable wall of checkboxes.

### Visuals actually built

**Page 1 — "Portfolio overview":**
1. **KPI card row:** five cards — Delinquency Rate, Charge-Off Rate, Weighted Avg LTV, Net Interest Margin, Active Balance.
2. **Donut chart — "Active Balance by LoanTypeName":** `LoanTypeName` as legend, `[Active Balance]` as values. Confirms the ~81%-mortgage-by-balance concentration finding.
3. **Clustered column chart — "Delinquency Rate by MemberSegment":** `MemberSegment` on the X-axis, `[Delinquency Rate]` as the Y-axis. The clearest risk-segmentation story on the dashboard — Subprime visibly towers over Prime.
4. **Line chart — "Count of LoanID by Year":** `OriginationDate` (as a proper date hierarchy after the fix above) on the X-axis, count of `LoanID` on the Y-axis.
5. **Four independent slicers:** Branch, Loan Type, and Member Segment as **Dropdown** style; Origination Date as **Between** style (a real date-range picker).

**Page 2 — "Branch officer & detail":**
1. **Table — KPI by branch:** `BranchName`, `[Active Balance]`, `[Delinquency Rate]`, `[Charge-Off Rate]`, `[Weighted Avg LTV]`, sorted descending by Active Balance (click the column header to sort).
2. **Ranked table — top loan officers:** `LoanOfficerName`, `BranchName`, `[Active Balance]`, sorted descending.
3. **Matrix — Branch × Loan Type:** `BranchName` on rows, `LoanTypeName` on columns, `[Active Balance]` as values, with **conditional formatting → background color → gradient** turned on (Format visual → Cell elements → Background color → the small `fx` icon) so the dollar amounts render as an actual heatmap instead of a plain number grid.
4. **One Branch slicer** (Dropdown style), so this page can be explored independently of Page 1's filters.

### Drill-through: deliberately skipped, and why that's the right call here

The original plan was a drill-through from a branch-level visual on Page 1 straight into Page 2, filtered to that branch. In practice, none of Page 1's visuals actually use `BranchName` as a category (the KPI cards are portfolio-wide aggregates, and the donut/bar/line charts are sliced by loan type, member segment, and date respectively) — the branch-level table ended up on Page 2 as the pages were built out. Right-click drill-through needs a source visual with the target field as a category, so there was no natural place to trigger it from without adding a visual to Page 1 purely to serve as a drill-through launchpad.

Given that, the call was to skip it rather than force something awkward under time pressure. **Two page tabs plus slicers on both pages already provide real, working interactivity** — that's a legitimate, common pattern, not a shortcut to be embarrassed about. Drill-through is listed as a concrete next step in Section 6 below, with the specific fix already scoped out.

---

## 6. What I'd Do Differently at Scale

Honest reflection on where this project's shortcuts would need to be replaced in a real production system:

- **Add a real balance/payment history table.** The single biggest simplification here is that every KPI is computed off *today's snapshot* — there's no table of "what was the balance on this loan on each of the last 24 months." A real NIM or annualized charge-off rate needs a time series, not a point-in-time read. I'd add a `LoanBalanceHistory` (or `LoanTransactions`) fact table at a monthly or daily grain and recompute the KPIs as proper trailing-period aggregates.
- **Move from views to a proper semantic/aggregation layer for scale.** At 25,000 rows, views computed live on every query are instant. At the tens of millions of rows a real credit union's transaction history would produce, `vw_LoanPortfolioBase` recomputing five aggregate joins on every Power BI refresh would get slow. I'd introduce indexed views or a nightly ETL job that materializes daily KPI snapshots into a small summary table, and point Power BI at that instead of the live view.
- **Partition the fact table by origination date.** Once there's real transaction history, `Loans`/`LoanBalanceHistory` should be partitioned (e.g., by year) so both loads and time-filtered queries only touch the relevant partitions instead of scanning the whole table.
- **Separate the "current status" snapshot model from full status-history tracking**, using slowly changing dimensions (Type 2) on `Members` and a proper transaction-level `LoanStatusHistory` table, so you can answer "what did the portfolio look like on March 1st" — not just "what does it look like today."
- **Move the SA password and connection details to a real secrets manager** (Azure Key Vault, AWS Secrets Manager, or at minimum a properly permissioned `.env` outside source control) instead of a local `.env` file — fine for a laptop demo, not fine for anything with real member data.
- **Add row-level security in Power BI** so a branch manager only sees their own branch's data, not the whole portfolio — a real deployment of this dashboard would need that before any non-executive user got access.
- **Replace the synthetic branch/loan-officer/collateral data with the real system-of-record feeds** (loan origination system, core banking platform) via a proper ETL/ELT pipeline instead of a one-time CSV load — this project's `BULK INSERT` approach is a fine one-time load for a portfolio piece, not a repeatable production pattern.
- **Add the drill-through from Page 1 to Page 2 that got deliberately skipped** (see Section 5). It needs one small addition first — a branch-level visual on the "Portfolio overview" page (e.g., a compact "Active Balance by Branch" bar chart) to serve as the right-click source — then wiring `BranchName` into Page 2's Drill-through field well. Small, well-scoped, and exactly the kind of thing to knock out in a follow-up pass rather than force in under deadline pressure.
- **Get a real live connection working between Power BI Desktop and SQL Server**, instead of the static Excel/OneDrive workaround this project ended up using (see Section 5). That would mean either running Power BI Desktop on hardware that can actually spare the RAM for a second VM alongside Docker, or moving SQL Server to a small always-on cloud instance so no VM is needed on the client side at all — either fixes the root cause (resource contention) rather than routing around it.
