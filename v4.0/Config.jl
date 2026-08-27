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
       SALES_ACCOUNT, CASH_ACCOUNT, CASH_OVER_SHORT_ACCOUNT,
       ALL_CATEGORIES, KEY_ORDER, DATE_COL, STATUS_COL, REASON_COL,
       label_of, colname_of,
       cash_book, CASH_BOOK_KEYS, VARIANCE_KEYS, JOURNAL_KEYS,
       CASH_SALES_KEY, POS_KEYS,
       IDENTITY_INFLOW_KEYS, IDENTITY_OUTFLOW_KEYS

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


# =============================================================================
# v4.0 ADDITIONS — the cash book, the variance columns, and the identity.
#
# NOTHING ABOVE THIS LINE HAS CHANGED. The four posting arrays, the two counter
# accounts and KEY_ORDER are exactly as v3.0 left them, which matters because
# KEY_ORDER is what Ledger.jl walks — see the comment on JOURNAL_KEYS below for
# why the new columns are deliberately kept out of it.
# =============================================================================

# --- The cash book (Warnings Guide §1) --------------------------------------
# Opening and closing balances. These are RECORDED, never POSTED: they carry no
# `account` field at all, which is the structural marker that keeps them out of
# the ledger. Handover §7 flagged this as the obstacle to adding them — every
# entry in the four arrays above is assumed by build_ledger_rows to map to an
# account, so appending balances there would have generated spurious ledger
# rows. A separate list with no `account` key makes that mistake impossible
# rather than merely discouraged.
#
# WHY THEY ARE NOT DERIVED: the closing balance is a physical count of the
# drawer, and the opening balance is typed from the sheet. Their entire value as
# a check comes from being observations rather than calculations. If either were
# computed, the day check would pass by construction and detect nothing, forever
# (Warnings Guide §8).
const cash_book = [(key=:opening_balance, label="Opening Balance"),
                   (key=:closing_balance, label="Closing Balance")]

const CASH_BOOK_KEYS = [c.key for c in cash_book]

# --- The variance columns ---------------------------------------------------
# Where an unexplained difference is stored. Two columns, not one, deliberately:
#   :day_variance       arose while the clinic was trading
#   :overnight_variance arose between the last working day's close and this
#                       day's open
# Both are cash over/short and both post to the same account, but they have
# different causes and different people to ask, and collapsing them would throw
# away the attribution that makes the figure actionable.
#
# These are journal columns rather than a separate residuals file on purpose.
# The whole v3.0 architecture rests on the journal being the only source of
# truth (Handover §2); a parallel store of discrepancies would be a second one.
const variance_cols = [(key=:day_variance,       label="Day Variance"),
                       (key=:overnight_variance, label="Overnight Variance")]

const VARIANCE_KEYS = [c.key for c in variance_cols]

# --- Journal columns vs ledger columns --------------------------------------
# KEY_ORDER  — the POSTING categories. Unchanged from v3.0. Ledger.jl walks this
#              and every member must map to an account.
# JOURNAL_KEYS — every NUMERIC column in the Daily Journal: the posting
#              categories, plus the cash book, plus the variances.
#
# Keeping these separate is what lets the balances be stored without ever
# reaching the ledger builder. DayInput.group_amounts still picks only from the
# four posting arrays, so a balance can never leak into a ledger row.
const JOURNAL_KEYS = vcat(KEY_ORDER, CASH_BOOK_KEYS, VARIANCE_KEYS)

# Non-numeric journal columns.
#   Status — "trading" or "closed". A closed day is a real journal row with zero
#            movement, not an absence. That is what keeps the chain continuous
#            in the file itself and stops a forgotten day looking identical to a
#            Sunday.
#   Reason — the typed explanation for a Level 2 override. Empty on a clean day.
const STATUS_COL = "Status"
const REASON_COL = "Reason"

# --- The identity (Warnings Guide §1) ---------------------------------------
#   Opening + Cash sales − Expenses − Deposit − Mr. Boyle = Closing
#
# CASH_SALES_KEY is singled out because it is the only member of cash_eq_in that
# is physical cash. The other three are card takings, which settle straight to
# the bank and never pass through the drawer. v3.0's Ledger.jl already made this
# distinction inline (`c.key != :cash_sales` when totalling POS); naming it here
# means the two places cannot drift apart.
const CASH_SALES_KEY = :cash_sales
const POS_KEYS = [c.key for c in cash_eq_in if c.key != CASH_SALES_KEY]

# Cash INTO the drawer.
const IDENTITY_INFLOW_KEYS = [CASH_SALES_KEY]

# Cash OUT of the drawer: every expense, the banking, and the related-party
# transfer. Built from the arrays rather than listed literally, so a new expense
# category joins the identity by itself and cannot be forgotten.
#
# NOTE ON DEPOSITS: `deposit` is "cash to be deposited" — physical notes leaving
# the till for the bank. It is cash out. The POS keys are NOT here and NOT in
# the inflow list; they appear on neither side. Nothing in this program can
# check a POS figure, and no arrangement of these lists would change that.
const IDENTITY_OUTFLOW_KEYS = vcat([c.key for c in expense],
                                   [c.key for c in deposit],
                                   [c.key for c in related_party])

# --- Where an unexplained difference is posted ------------------------------
# A variance is credited or debited against this account so that QuickBooks'
# petty cash balance continues to match the counted drawer. Without the posting,
# QuickBooks silently drifts and nothing in it ever shows the gap.
#
# ⚠ NOT YET CONFIRMED. "Unidentified Income" is the candidate discussed, chosen
# because it is a current asset and so holds a balance rather than clearing
# itself to the P&L each period. Two open questions before this goes live:
#   1. Is that account already in use for unidentified RECEIPTS? If so, a
#      shortage and an unidentified receipt would net against each other and the
#      balance-sheet review would show nothing.
#   2. The direction reads backwards — a cash SHORTAGE increases an account
#      called "Unidentified Income".
# A dedicated "Cash Over/Short" current-asset account avoids both. Get the exact
# string from a CSV export of the chart of accounts, not by typing what it ought
# to be — two of the handful of strings checked so far were wrong (Handover §8).
const CASH_OVER_SHORT_ACCOUNT = "Unidentified Income"

# --- Labels for the new columns ---------------------------------------------
# LABEL_OF above is built from ALL_CATEGORIES only, so the cash book and
# variance keys would otherwise have no label and label_of() would throw.
for c in vcat(cash_book, variance_cols)
    LABEL_OF[c.key]   = c.label
    COLNAME_OF[c.key] = String(c.key)
end

end # module Config
