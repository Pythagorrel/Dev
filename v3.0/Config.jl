module Config

# =============================================================================
# CONFIG — single source of truth for the chart of accounts.
#
# UNCHANGED FROM v2.1.1: the four category arrays and the two counter-account
# constants are copied verbatim out of the old v2_1_1.jl. Nothing about their
# contents, order, key names, labels or account strings has been touched.
#
# WHAT IS NEW: they now live in their own module, and a handful of derived
# lookups (KEY_ORDER, LABEL_OF, ...) are built from them. Every other file in
# the codebase reads the schema from here rather than hardcoding column names,
# so adding a category is still a one-line edit to one array.
# =============================================================================

export cash_eq_in, expense, deposit, related_party,
       SALES_ACCOUNT, CASH_ACCOUNT,
       ALL_CATEGORIES, KEY_ORDER, DATE_COL,
       label_of, colname_of

const cash_eq_in = [(key=:cash_sales, label="Cash Sales", account="Cash & Cash Equivalent:Petty Cash:Petty Cash Urgent Care"),
    (key=:POS_Scotia, label="POS Deposits To Scotiabank", account="Cash & Cash Equivalent:Scotia Bank"),
    (key=:POS_RBL, label="POS Deposits to Republic Bank", account="Cash & Cash Equivalent:RBL - CHQ-13739"),
    (key=:POS_U, label="POS Deposits To Unspecified Bank", account="Cash & Cash Equivalent:POS Unidentified Urgent Care")]

const expense = [(key=:doctor_fees, label="Doctor's Fees", account="Cost of sales:Sub-contractor-  COS"),
    (key=:medical_supply_costs, label="Medical Supplies", account="Cost of sales:Purchases-COS"),
    (key=:miscellaneous_costs, label="Miscellaneous Items", account="Cost of sales:Purchases-COS"),
    (key=:taxi_fare, label="Taxi Fare", account="Local Travel")]

const deposit = [(key=:deposits, label="Deposits", account="Undeposited Funds Urgent Care")]

const related_party = [(key=:Mr_Boyle, label="Transfers Out to Mr. Boyle", account="Related Party:Related Party-Mr.Boyle")]

# The two "counter accounts" that don't live in any config array —
# every cash_eq_in category credits SALES_ACCOUNT on sale, every expense /
# related_party category credits CASH_ACCOUNT when paid out.
const SALES_ACCOUNT = "Medical & Lab Tests"
const CASH_ACCOUNT  = "Cash & Cash Equivalent:Petty Cash:Petty Cash Urgent Care"
# NOTE: no separate UNDEPOSITED_ACCOUNT const needed — deposit[1].account already holds it.

# --- Derived lookups -------------------------------------------------------
# NEW. vcat glues the four arrays into one flat list in a FIXED order. That
# order is the column order of the Daily Journal, so it must never be shuffled
# — appending to the end of any single array is safe, reordering is not.
const ALL_CATEGORIES = vcat(cash_eq_in, expense, deposit, related_party)

# NEW. The canonical list of category keys. `[c.key for c in ...]` is a
# comprehension: it walks ALL_CATEGORIES and pulls the `key` field out of each
# NamedTuple, giving Vector{Symbol}.
const KEY_ORDER = [c.key for c in ALL_CATEGORIES]

# NEW. Header of the date column in the Daily Journal.
const DATE_COL = "Date"

# NEW. Symbol => String maps built once at load time.
#   LABEL_OF  — key => human-readable label, used for anything a person reads.
#   COLNAME_OF — key => CSV header, used for anything a machine reads.
# This is the split you asked for: the journal is now keyed by `key`, so a
# label can be reworded at any time without invalidating historical journals.
const LABEL_OF   = Dict{Symbol,String}(c.key => c.label      for c in ALL_CATEGORIES)
const COLNAME_OF = Dict{Symbol,String}(c.key => String(c.key) for c in ALL_CATEGORIES)

label_of(k::Symbol)   = LABEL_OF[k]
colname_of(k::Symbol) = COLNAME_OF[k]

end # module Config
