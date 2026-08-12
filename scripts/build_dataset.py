"""
Builds the loan-portfolio-health-dashboard dataset.

Source of real data: Kaggle "Bank Loan Status Dataset" (zaurbegiev/my-dataset),
downloaded to data/raw/credit_train.csv via download_data.sh.

That dataset is real, messy peer-to-peer lending data: unsecured personal loans
with a Fully-Paid/Charged-Off outcome, credit score, income, DTI-related fields,
and a purpose (debt consolidation, medical, business, home improvement, etc).
It is used here for the UNSECURED side of the portfolio, keeping its real
credit-score/income/status signal but rescaling the loan-amount field, which
in the source data does not vary sensibly by purpose (median ~$267K regardless
of whether the purpose was "medical bills" or "debt consolidation" -- not
usable as-is for a credible loan-amount KPI).

It has almost no auto-loan or home-purchase rows (<2,000 out of 100K, out of
the box for a P2P personal-loan platform) and no interest rate, origination
date, branch, loan officer, member segment, or collateral value at all -- so
the SECURED side of the portfolio (auto loans, mortgages) and every
operational field are synthesized from scratch, fixed random seed for
reproducibility. Every synthesized field/segment is marked SYNTHETIC below.

Re-run: python3 scripts/build_dataset.py
"""
import csv
from datetime import date, timedelta
from pathlib import Path

import numpy as np
import pandas as pd

RANDOM_SEED = 42
UNSECURED_SAMPLE_SIZE = 15_500
AUTO_LOAN_COUNT = 6_500
MORTGAGE_COUNT = 3_000
TODAY = date(2026, 8, 12)

ROOT = Path(__file__).resolve().parents[1]
RAW_PATH = ROOT / "data" / "raw" / "credit_train.csv"
OUT_DIR = ROOT / "data" / "processed"

rng = np.random.default_rng(RANDOM_SEED)

# ---------------------------------------------------------------------------
# 1. Reference data (SYNTHETIC) -- a fictional credit union's footprint
# ---------------------------------------------------------------------------

BRANCHES = pd.DataFrame([
    (1, "Austin Main",       "Austin",       "TX", "Central"),
    (2, "Dallas North",      "Dallas",       "TX", "North"),
    (3, "Houston Gulf",      "Houston",      "TX", "Southeast"),
    (4, "San Antonio Alamo", "San Antonio",  "TX", "South"),
    (5, "Fort Worth West",   "Fort Worth",   "TX", "North"),
    (6, "El Paso Border",    "El Paso",      "TX", "West"),
], columns=["BranchID", "BranchName", "City", "State", "Region"])
BRANCHES["OpenDate"] = ["2005-03-01", "2008-06-15", "2011-01-10",
                         "2013-09-01", "2016-04-20", "2019-11-05"]

FIRST_NAMES = ["James","Mary","Robert","Patricia","John","Jennifer","Michael","Linda",
               "David","Elizabeth","William","Barbara","Richard","Susan","Joseph","Jessica",
               "Thomas","Sarah","Carlos","Maria","Luis","Ana","Jose","Laura","Miguel","Sofia",
               "Kevin","Amanda","Brian","Nicole","Daniel","Emily","Mark","Rachel","Steven","Megan"]
LAST_NAMES = ["Smith","Johnson","Williams","Brown","Jones","Garcia","Miller","Davis",
              "Rodriguez","Martinez","Hernandez","Lopez","Gonzalez","Wilson","Anderson","Thomas",
              "Taylor","Moore","Jackson","Martin","Lee","Perez","Thompson","White","Harris","Sanchez",
              "Clark","Ramirez","Lewis","Robinson"]

def make_loan_officers(branches: pd.DataFrame, per_branch=(3, 5)) -> pd.DataFrame:
    rows, officer_id = [], 1
    for _, b in branches.iterrows():
        n = rng.integers(per_branch[0], per_branch[1] + 1)
        for _ in range(n):
            first, last = rng.choice(FIRST_NAMES), rng.choice(LAST_NAMES)
            hire_days_ago = int(rng.integers(180, 6000))
            rows.append((officer_id, first, last, b.BranchID,
                         (TODAY - timedelta(days=hire_days_ago)).isoformat()))
            officer_id += 1
    return pd.DataFrame(rows, columns=["LoanOfficerID", "FirstName", "LastName", "BranchID", "HireDate"])

LOAN_OFFICERS = make_loan_officers(BRANCHES)

# BaseInterestRate = SYNTHETIC starting point per product before credit-tier adjustment.
LOAN_TYPES = pd.DataFrame([
    (1, "Auto Loan",                 1, 0.075),
    (2, "Mortgage / Home Purchase",  1, 0.065),
    (3, "Home Improvement",          0, 0.085),
    (4, "Debt Consolidation",        0, 0.110),
    (5, "Business Loan",             0, 0.090),
    (6, "Personal / Medical",        0, 0.130),
    (7, "Education",                 0, 0.070),
    (8, "Other",                     0, 0.120),
], columns=["LoanTypeID", "LoanTypeName", "IsSecured", "BaseInterestRate"])
LT = LOAN_TYPES.set_index("LoanTypeName")

PURPOSE_TO_LOANTYPE = {
    "Home Improvements": "Home Improvement",
    "Debt Consolidation": "Debt Consolidation",
    "Business Loan": "Business Loan",
    "small_business": "Business Loan",
    "Medical Bills": "Personal / Medical",
    "Educational Expenses": "Education",
    "Take a Trip": "Personal / Medical",
    "vacation": "Personal / Medical",
    "wedding": "Personal / Medical",
    "major_purchase": "Other",
    "moving": "Other",
    "renewable_energy": "Home Improvement",
    "other": "Other",
    "Other": "Other",
    # "Buy a Car" / "Buy House" are dropped from the real-data pool: <2K rows in the
    # entire 100K-row source, too few to model a credit union's secured book on.
    # Auto loans and mortgages are built as a separate synthetic population below instead.
}

# SYNTHETIC realistic amount bands per unsecured loan type: (low, median, high).
# The real data's own LoanAmount field is discarded for the reason explained in the
# module docstring; only its *rank order within each purpose group* is kept, so a
# borrower who had a relatively larger raw loan still gets a relatively larger,
# but now realistic, loan.
UNSECURED_AMOUNT_BANDS = {
    "Home Improvement":   (2_000, 12_000, 50_000),
    "Debt Consolidation": (2_000, 14_000, 45_000),
    "Business Loan":      (5_000, 35_000, 150_000),
    "Personal / Medical": (1_000, 7_000, 25_000),
    "Education":          (1_500, 10_000, 40_000),
    "Other":              (1_000, 8_000, 30_000),
}

INSTITUTION_PARAMETERS = pd.DataFrame([
    ("CostOfFundsRate", "0.0275",
     "Blended annual rate the credit union pays on member deposits/borrowings; "
     "the cost side of Net Interest Margin."),
], columns=["ParamName", "ParamValue", "ParamDescription"])

# ---------------------------------------------------------------------------
# 2. Load + clean the real Kaggle data (unsecured loans only)
# ---------------------------------------------------------------------------

def parse_years_in_job(v):
    if pd.isna(v) or v in ("n/a", ""):
        return np.nan
    if v == "10+ years":
        return 10
    if v == "< 1 year":
        return 0
    return int(v.split()[0])

def rank_rescale(series: pd.Series, low: float, median: float, high: float) -> pd.Series:
    """Map a series to a realistic [low, high] band via a log-space rank transform,
    preserving each value's relative position within its group. Good for right-skewed
    dollar fields (loan amount, income)."""
    pct = series.rank(pct=True, method="first")
    log_low, log_med, log_high = np.log(low), np.log(median), np.log(high)
    # piecewise-linear in log space around the median so the distribution stays right-skewed
    log_val = np.where(
        pct <= 0.5,
        log_low + (log_med - log_low) * (pct / 0.5),
        log_med + (log_high - log_med) * ((pct - 0.5) / 0.5),
    )
    return np.exp(log_val).round(0)

def rank_rescale_linear(series: pd.Series, low: float, high: float) -> pd.Series:
    """Map a series to [low, high] by percentile rank, linearly. Good for
    roughly-symmetric fields (credit score, DTI ratio)."""
    pct = series.rank(pct=True, method="first")
    return (low + (high - low) * pct).round(0)

def load_and_clean_unsecured() -> pd.DataFrame:
    df = pd.read_csv(RAW_PATH, dtype=str)
    df = df[df["Loan Status"].notna() & (df["Loan Status"] != "")]
    df = df[df["Purpose"].isin(PURPOSE_TO_LOANTYPE.keys())]

    df["Current Loan Amount"] = pd.to_numeric(df["Current Loan Amount"], errors="coerce")
    df["Credit Score"] = pd.to_numeric(df["Credit Score"], errors="coerce")
    df["Annual Income"] = pd.to_numeric(df["Annual Income"], errors="coerce")
    df["Monthly Debt"] = pd.to_numeric(df["Monthly Debt"], errors="coerce")
    df["Years of Credit History"] = pd.to_numeric(df["Years of Credit History"], errors="coerce")

    # Known Kaggle data-quality bug: some credit scores are stored x10 (e.g. 7290 instead of 729).
    df.loc[df["Credit Score"] > 850, "Credit Score"] = df["Credit Score"] / 10

    # Source placeholder for "unknown" loan amount; drop those rows.
    df = df[(df["Current Loan Amount"] > 0) & (df["Current Loan Amount"] < 99_999_999)]

    df["YearsInJob"] = df["Years in current job"].apply(parse_years_in_job)

    # Median-impute the few remaining missing scores/incomes; flag so it's auditable.
    df["CreditScoreImputed"] = df["Credit Score"].isna().astype(int)
    df["Credit Score"] = df["Credit Score"].fillna(df["Credit Score"].median())
    df["IncomeImputed"] = df["Annual Income"].isna().astype(int)
    df["Annual Income"] = df["Annual Income"].fillna(df["Annual Income"].median())
    df["Monthly Debt"] = df["Monthly Debt"].fillna(df["Monthly Debt"].median())

    df["LoanTypeName"] = df["Purpose"].map(PURPOSE_TO_LOANTYPE)
    df["TermMonths"] = df["Term"].map({"Short Term": 36, "Long Term": 60})
    df = df[df["TermMonths"].notna()]

    # Rescale loan amount to a realistic band within each purpose group.
    df["LoanAmount"] = 0.0
    for lt, (low, med, high) in UNSECURED_AMOUNT_BANDS.items():
        mask = df["LoanTypeName"] == lt
        df.loc[mask, "LoanAmount"] = rank_rescale(df.loc[mask, "Current Loan Amount"], low, med, high)

    df["LoanTypeID"] = df["LoanTypeName"].map(LT["LoanTypeID"])
    df["SourceLoanID"] = df["Loan ID"]
    df["MaturedOutcomeHint"] = df["Loan Status"]  # "Fully Paid" / "Charged Off", real signal

    sample_n = min(UNSECURED_SAMPLE_SIZE, len(df))
    df = df.sample(n=sample_n, random_state=RANDOM_SEED).reset_index(drop=True)

    return df[["Customer ID", "SourceLoanID", "LoanTypeID", "LoanTypeName", "LoanAmount", "TermMonths",
               "Credit Score", "Annual Income", "YearsInJob", "Home Ownership",
               "Monthly Debt", "Years of Credit History", "MaturedOutcomeHint",
               "CreditScoreImputed", "IncomeImputed"]].rename(columns={
        "Credit Score": "CreditScoreRaw", "Annual Income": "AnnualIncomeRaw",
        "Home Ownership": "HomeOwnership", "Monthly Debt": "MonthlyDebtRaw",
        "Years of Credit History": "YearsOfCreditHistory",
    })

# ---------------------------------------------------------------------------
# 3. Members
# ---------------------------------------------------------------------------

def credit_tier(score):
    if score >= 750:
        return "Excellent"
    if score >= 700:
        return "Good"
    if score >= 650:
        return "Fair"
    return "Subprime"

def income_tier(income):
    if income >= 85_000:
        return "High"
    if income >= 45_000:
        return "Mid"
    return "Low"

def member_segment(ctier, itier):
    if ctier in ("Excellent", "Good"):
        return "Prime" if itier != "Low" else "Prime - Budget Conscious"
    if ctier == "Fair":
        return "Near-Prime"
    return "Subprime"

# SYNTHETIC realistic bands: the raw Kaggle CreditScore/AnnualIncome/MonthlyDebt fields
# are not on a believable real-world scale for this population (income median comes in
# over $1.1M/year, monthly debt over $18K/month -- a known quality issue in this source
# file). Their *relative order* (who looks stronger vs. weaker than their peers) is real
# and worth keeping, so each is rank-rescaled into a realistic band rather than discarded.
CREDIT_SCORE_BAND = (560, 830)          # realistic FICO-like spread
ANNUAL_INCOME_BAND = (18_000, 52_000, 220_000)   # (low, median, high), log-shaped like real income
DTI_BAND = (0.05, 0.55)                 # realistic debt-to-income spread

def build_members(unsecured: pd.DataFrame) -> pd.DataFrame:
    members = (
        unsecured.groupby("Customer ID")
        .agg(CreditScoreRaw=("CreditScoreRaw", "first"),
             AnnualIncomeRaw=("AnnualIncomeRaw", "first"),
             MonthlyDebtRaw=("MonthlyDebtRaw", "first"),
             YearsOfCreditHistory=("YearsOfCreditHistory", "first"),
             YearsInJob=("YearsInJob", "first"),
             HomeOwnership=("HomeOwnership", "first"))
        .reset_index()
    )
    members["MemberID"] = np.arange(1, len(members) + 1)

    members["CreditScore"] = rank_rescale_linear(members["CreditScoreRaw"], *CREDIT_SCORE_BAND).astype(int)
    members["AnnualIncome"] = rank_rescale(members["AnnualIncomeRaw"], *ANNUAL_INCOME_BAND)

    raw_dti = (members["MonthlyDebtRaw"] * 12) / members["AnnualIncomeRaw"]
    members["DebtToIncomeRatio"] = (rank_rescale_linear(raw_dti, DTI_BAND[0] * 100, DTI_BAND[1] * 100) / 100).round(4)
    members["MonthlyDebt"] = (members["DebtToIncomeRatio"] * members["AnnualIncome"] / 12).round(2)

    members["CreditTier"] = members["CreditScore"].apply(credit_tier)
    members["IncomeTier"] = members["AnnualIncome"].apply(income_tier)
    members["MemberSegment"] = [member_segment(c, i) for c, i in zip(members["CreditTier"], members["IncomeTier"])]

    # SYNTHETIC: names, "home" branch affiliation, membership join date.
    members["FirstName"] = rng.choice(FIRST_NAMES, size=len(members))
    members["LastName"] = rng.choice(LAST_NAMES, size=len(members))
    members["HomeBranchID"] = rng.choice(BRANCHES["BranchID"], size=len(members))
    join_days_ago = rng.integers(30, 20 * 365, size=len(members))
    members["MemberSinceDate"] = [(TODAY - timedelta(days=int(d))).isoformat() for d in join_days_ago]

    return members[["MemberID", "Customer ID", "FirstName", "LastName", "HomeBranchID",
                     "MemberSinceDate", "CreditScore", "AnnualIncome", "MonthlyDebt",
                     "DebtToIncomeRatio", "YearsOfCreditHistory", "YearsInJob",
                     "HomeOwnership", "CreditTier", "IncomeTier", "MemberSegment"]]

# ---------------------------------------------------------------------------
# 4. Loan lifecycle simulation (shared by both unsecured and secured loans)
# ---------------------------------------------------------------------------

DELINQ_WEIGHTS = {
    "Excellent": [0.97, 0.02, 0.007, 0.003],
    "Good":      [0.94, 0.035, 0.015, 0.01],
    "Fair":      [0.85, 0.08, 0.05, 0.02],
    "Subprime":  [0.68, 0.15, 0.10, 0.07],
}
DELINQ_BUCKETS = ["Current", "30-59 DPD", "60-89 DPD", "90+ DPD"]

# SYNTHETIC matured-loan outcome probabilities for the secured book (auto/mortgage),
# since the source data has no real outcome signal for these loan types. Mirrors
# typical credit-union charge-off patterns by credit tier (secured loans default less
# often than unsecured, so charge-off probabilities are set lower than the real
# unsecured outcomes imply for the same tier).
SYNTH_CHARGEOFF_PROB = {"Excellent": 0.01, "Good": 0.02, "Fair": 0.05, "Subprime": 0.12}

def assign_officer_for_branch(branch_id):
    pool = LOAN_OFFICERS[LOAN_OFFICERS["BranchID"] == branch_id]["LoanOfficerID"].values
    return rng.choice(pool)

def simulate_loans(seed: pd.DataFrame) -> pd.DataFrame:
    """seed needs: MemberID, HomeBranchID, CreditTier, LoanTypeID, LoanTypeName,
    LoanAmount, TermMonths, SourceLoanID (nullable), MaturedOutcomeHint (nullable)."""
    n = len(seed)
    seed = seed.reset_index(drop=True)

    same_branch = rng.random(n) < 0.85
    other_branch = rng.choice(BRANCHES["BranchID"], size=n)
    branch_id = np.where(same_branch, seed["HomeBranchID"], other_branch)
    officer_id = [assign_officer_for_branch(b) for b in branch_id]

    days_ago = rng.integers(1, 6 * 365, size=n)
    origination = [TODAY - timedelta(days=int(d)) for d in days_ago]
    maturity = [o + timedelta(days=int(t) * 30) for o, t in zip(origination, seed["TermMonths"])]

    tier_adj = {"Excellent": -0.010, "Good": -0.003, "Fair": 0.012, "Subprime": 0.035}
    base_rate = seed["LoanTypeName"].map(LT["BaseInterestRate"])
    adj = seed["CreditTier"].map(tier_adj)
    noise = rng.normal(0, 0.004, size=n)
    interest_rate = (base_rate + adj + noise).clip(0.03, 0.24).round(4)

    is_secured = seed["LoanTypeName"].map(LT["IsSecured"]).astype(bool)
    ltv_target = np.where(
        seed["LoanTypeName"] == "Mortgage / Home Purchase",
        rng.uniform(0.70, 0.95, size=n),
        rng.uniform(0.60, 1.05, size=n),  # used-auto collateral can run under water
    )
    collateral_value = np.where(is_secured, (seed["LoanAmount"] / ltv_target).round(2), np.nan)

    statuses, delinq_days, outstanding, chargeoff_amt, chargeoff_date = [], [], [], [], []
    for i in range(n):
        term = seed["TermMonths"].iloc[i]
        amount = seed["LoanAmount"].iloc[i]
        tier = seed["CreditTier"].iloc[i]
        o_date, m_date = origination[i], maturity[i]
        hint = seed["MaturedOutcomeHint"].iloc[i] if "MaturedOutcomeHint" in seed.columns else None

        if m_date < TODAY:
            if hint is not None and not pd.isna(hint):
                charged_off = (hint == "Charged Off")
            else:
                charged_off = rng.random() < SYNTH_CHARGEOFF_PROB[tier]

            if charged_off:
                statuses.append("Charged Off"); delinq_days.append(0); outstanding.append(0.0)
                co_date = o_date + (m_date - o_date) * rng.uniform(0.2, 0.9)
                chargeoff_date.append(co_date.isoformat())
                chargeoff_amt.append(round(amount * rng.uniform(0.4, 0.9), 2))
            else:
                statuses.append("Paid Off"); delinq_days.append(0); outstanding.append(0.0)
                chargeoff_date.append(None); chargeoff_amt.append(0.0)
        else:
            months_elapsed = max((TODAY - o_date).days / 30.0, 0)
            frac_remaining = max(1 - months_elapsed / term, 0.02)
            bal = round(amount * frac_remaining, 2)
            bucket = rng.choice(DELINQ_BUCKETS, p=DELINQ_WEIGHTS[tier])

            if bucket == "90+ DPD" and rng.random() < 0.20:
                statuses.append("Charged Off"); delinq_days.append(0)
                chargeoff_date.append((TODAY - timedelta(days=int(rng.integers(1, 30)))).isoformat())
                chargeoff_amt.append(round(bal * rng.uniform(0.7, 1.0), 2))
                outstanding.append(0.0)
            else:
                statuses.append(bucket)
                dmap = {"Current": 0, "30-59 DPD": rng.integers(30, 60),
                        "60-89 DPD": rng.integers(60, 90), "90+ DPD": rng.integers(90, 181)}
                delinq_days.append(int(dmap[bucket]))
                outstanding.append(bal); chargeoff_date.append(None); chargeoff_amt.append(0.0)

    out = seed.copy()
    out["BranchID"] = branch_id
    out["LoanOfficerID"] = officer_id
    out["OriginationDate"] = [d.isoformat() for d in origination]
    out["MaturityDate"] = [d.isoformat() for d in maturity]
    out["InterestRate"] = interest_rate
    out["CollateralValue"] = collateral_value
    out["CurrentStatus"] = statuses
    out["DelinquencyDays"] = delinq_days
    out["OutstandingBalance"] = outstanding
    out["ChargeOffAmount"] = chargeoff_amt
    out["ChargeOffDate"] = chargeoff_date
    out["ChargeOffFlag"] = (out["CurrentStatus"] == "Charged Off").astype(int)
    return out

# ---------------------------------------------------------------------------
# 5. Synthetic secured-loan seeds (auto loans, mortgages)
# ---------------------------------------------------------------------------

def lognormal_amounts(n, low, median, high):
    sigma = 0.45
    vals = rng.lognormal(mean=np.log(median), sigma=sigma, size=n)
    return np.clip(vals, low, high).round(0)

def build_secured_seed(members: pd.DataFrame) -> pd.DataFrame:
    # Mortgages skew toward higher income / better credit (real-world underwriting norm).
    mort_weights = members["AnnualIncome"].rank(pct=True) * members["CreditScore"].rank(pct=True)
    mort_weights = (mort_weights / mort_weights.sum()).values
    mort_members = rng.choice(members["MemberID"], size=MORTGAGE_COUNT, replace=True, p=mort_weights)

    # Auto loans are broad-based across the membership.
    auto_members = rng.choice(members["MemberID"], size=AUTO_LOAN_COUNT, replace=True)

    mem_idx = members.set_index("MemberID")

    auto = pd.DataFrame({
        "MemberID": auto_members,
        "LoanTypeID": LT.loc["Auto Loan", "LoanTypeID"],
        "LoanTypeName": "Auto Loan",
        "LoanAmount": lognormal_amounts(AUTO_LOAN_COUNT, 8_000, 24_000, 65_000),
        "TermMonths": rng.choice([36, 48, 60, 72], size=AUTO_LOAN_COUNT, p=[0.15, 0.30, 0.35, 0.20]),
    })
    mortgage = pd.DataFrame({
        "MemberID": mort_members,
        "LoanTypeID": LT.loc["Mortgage / Home Purchase", "LoanTypeID"],
        "LoanTypeName": "Mortgage / Home Purchase",
        "LoanAmount": lognormal_amounts(MORTGAGE_COUNT, 90_000, 220_000, 550_000),
        "TermMonths": rng.choice([180, 360], size=MORTGAGE_COUNT, p=[0.25, 0.75]),
    })

    seed = pd.concat([auto, mortgage], ignore_index=True)
    seed["HomeBranchID"] = mem_idx.loc[seed["MemberID"], "HomeBranchID"].values
    seed["CreditTier"] = mem_idx.loc[seed["MemberID"], "CreditTier"].values
    seed["SourceLoanID"] = None
    seed["MaturedOutcomeHint"] = None
    return seed

# ---------------------------------------------------------------------------
# 6. Run
# ---------------------------------------------------------------------------

def main():
    if not RAW_PATH.exists():
        raise SystemExit(f"Missing {RAW_PATH}. Run scripts/download_data.sh first.")
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    unsecured = load_and_clean_unsecured()
    members = build_members(unsecured)

    unsecured_seed = unsecured.merge(members[["MemberID", "Customer ID"]], on="Customer ID")
    unsecured_seed = unsecured_seed.merge(members[["MemberID", "HomeBranchID", "CreditTier"]], on="MemberID")

    secured_seed = build_secured_seed(members)

    # Note: Kaggle's own "Loan ID" is not a unique key in the source file (it repeats),
    # so SourceLoanID is retained purely as a provenance/traceability column, never used
    # as a join key downstream.
    common_cols = ["MemberID", "HomeBranchID", "CreditTier", "LoanTypeID", "LoanTypeName",
                    "LoanAmount", "TermMonths", "SourceLoanID", "MaturedOutcomeHint"]
    all_seed = pd.concat([unsecured_seed[common_cols], secured_seed[common_cols]], ignore_index=True)

    loans = simulate_loans(all_seed)
    loans.insert(0, "LoanID", np.arange(1, len(loans) + 1))

    loans_out = loans[[
        "LoanID", "SourceLoanID", "MemberID", "BranchID", "LoanOfficerID", "LoanTypeID",
        "LoanAmount", "InterestRate", "TermMonths", "OriginationDate", "MaturityDate",
        "OutstandingBalance", "CollateralValue", "CurrentStatus", "DelinquencyDays",
        "ChargeOffFlag", "ChargeOffAmount", "ChargeOffDate",
    ]]

    BRANCHES.to_csv(OUT_DIR / "branches.csv", index=False, quoting=csv.QUOTE_MINIMAL)
    LOAN_OFFICERS.to_csv(OUT_DIR / "loan_officers.csv", index=False, quoting=csv.QUOTE_MINIMAL)
    LOAN_TYPES.to_csv(OUT_DIR / "loan_types.csv", index=False, quoting=csv.QUOTE_MINIMAL)
    INSTITUTION_PARAMETERS.to_csv(OUT_DIR / "institution_parameters.csv", index=False, quoting=csv.QUOTE_MINIMAL)
    members.drop(columns=["Customer ID"]).to_csv(OUT_DIR / "members.csv", index=False, quoting=csv.QUOTE_MINIMAL)
    loans_out.to_csv(OUT_DIR / "loans.csv", index=False, quoting=csv.QUOTE_MINIMAL)

    print(f"Members:      {len(members):,}")
    print(f"Loans:        {len(loans_out):,}")
    print(f"  Unsecured (real Kaggle-derived): {len(unsecured_seed):,}")
    print(f"  Auto (synthetic):                {AUTO_LOAN_COUNT:,}")
    print(f"  Mortgage (synthetic):            {MORTGAGE_COUNT:,}")
    print(f"Branches:     {len(BRANCHES)}")
    print(f"LoanOfficers: {len(LOAN_OFFICERS)}")
    print(f"Wrote CSVs to {OUT_DIR}")

if __name__ == "__main__":
    main()
