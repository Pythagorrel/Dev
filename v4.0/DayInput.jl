module DayInput

using Dates, CSV, DataFrames
using ..Config
using ..getdate

# =============================================================================
# DAYINPUT — turns "whatever the user supplied" into exactly one DayRecord.
#
# THE STRUCTURAL CHANGE: v2.1.1's csv1() collected an arbitrary number of days
# in one sitting, which is why it carried Dict{Symbol,Vector{Float64}} — a
# growing vector per category — plus a parallel `dates::Vector{Int}`, plus the
# recursive csv1a() that called itself once per day. All of that machinery
# existed only to hold multiple days in memory at once.
#
# One run now handles exactly ONE day, so the vectors collapse to scalars:
#     Dict{Symbol,Vector{Float64}}  ->  Dict{Symbol,Float64}
# and the recursion, the `day_no = 1 + length(dates)` index bookkeeping, and
# the "another day?" prompt all disappear. Multi-day work is done by running
# the program once per day; the month accumulates in the journal file on disk
# instead of in RAM.
#
# The payoff is in Ledger.jl: a single day's Dict{Symbol,Float64} has exactly
# the same shape as the old `total_cash_eq`/`total_expense`/... dicts, so
# build_ledger_rows can generate a DAILY ledger with no changes whatsoever.
# =============================================================================

export DayRecord, blank_amounts, read_day, read_day_csv, read_day_interactive,
       group_amounts,
       NOT_COUNTED, is_counted, not_counted, STATUS_TRADING, STATUS_CLOSED, is_closed,
       closed_day

"""
    DayRecord

One day of business. `amounts` is always fully populated — every key in
Config.KEY_ORDER is present, defaulting to 0.0. That invariant is what
implements the "any field left blank autopopulates with zero" rule: blankness
is resolved once, here at the boundary, so no code downstream ever has to
handle a `missing` amount.

Zero (not `missing`/`nothing`) is the right filler because every consumer of
these numbers is arithmetic — sums, subtractions, comparisons. `missing`
poisons all three (`missing + 1 === missing`), and `nothing` errors outright.
"""
# ---------------------------------------------------------------------------
# v4.0: blank vs zero, and trading vs closed
# ---------------------------------------------------------------------------
# NOT_COUNTED distinguishes "the drawer was counted and was empty" (0.0) from
# "nobody counted it" (NOT_COUNTED). Warnings Guide L1-C.
#
# For every POSTING category, blank genuinely does mean zero — no taxi fares
# today, so nothing was spent — and v3.0's rule of resolving blankness to 0.0 at
# this boundary stays exactly as it was. But a blank CLOSING BALANCE does not
# mean the drawer was empty, and silently reading it as zero would delete a real
# balance and never say so.
#
# WHY NaN RATHER THAN A UNION OR `missing`: the amounts dict has to stay
# Dict{Symbol,Float64} or every downstream consumer changes. NaN is a Float64,
# so the type is untouched; it propagates through arithmetic instead of
# throwing, so a stray one surfaces as a NaN result rather than a crash; and it
# is never equal to anything including itself, so it cannot be mistaken for a
# real figure by an `==` comparison. `missing` would poison sums the same way
# but requires widening the dict's type everywhere (Handover §4 rule 6).
const NOT_COUNTED = NaN

"True when a cash-book figure was actually entered."
is_counted(x::Float64) = !isnan(x)

"True when a cash-book figure was left blank. The complement of is_counted; both
exist because each reads correctly at a different call site."
not_counted(x::Float64) = isnan(x)

# A day is either trading or closed. A closed day is a REAL journal row with
# zero movement, no ledger, and its closing equal to its opening — not an
# absence. That is what keeps the chain continuous in the file and stops a
# forgotten Wednesday looking identical to a Sunday.
const STATUS_TRADING = "trading"
const STATUS_CLOSED  = "closed"

"""
    DayRecord

One day of business.

CHANGED IN v4.0: gained `status` and `reason`.
  * `status`  — STATUS_TRADING or STATUS_CLOSED.
  * `reason`  — the typed explanation for a Level 2 override (Warnings Guide
                §4). Empty on a clean day. Stored on the record rather than
                logged separately because it belongs to the day permanently: an
                email is a notification, not a record.

`amounts` is still fully populated for every key in Config.JOURNAL_KEYS, so no
code downstream handles a missing key. What changed is that the two cash-book
keys may hold NOT_COUNTED.

The two-argument constructor from v3.0 still works and defaults to a trading day
with no reason, so existing call sites are unaffected.
"""
struct DayRecord
    date::Date
    amounts::Dict{Symbol,Float64}
    status::String
    reason::String
end
DayRecord(d::Date, a::Dict{Symbol,Float64}) = DayRecord(d, a, STATUS_TRADING, "")
DayRecord(d::Date, a::Dict{Symbol,Float64}, s::AbstractString) = DayRecord(d, a, String(s), "")

is_closed(rec::DayRecord) = rec.status == STATUS_CLOSED

"""
    blank_amounts()

Every journal column present, with the v4.0 split described above:
  * posting categories -> 0.0        (blank really does mean none)
  * cash book          -> NOT_COUNTED (blank means nobody counted)
  * variances          -> 0.0        (computed later; zero until then)
"""
function blank_amounts()
    a = Dict{Symbol,Float64}(k => 0.0 for k in JOURNAL_KEYS)
    for k in CASH_BOOK_KEYS
        a[k] = NOT_COUNTED
    end
    return a
end

"""
    closed_day(date, opening)

A non-trading day. Every posting category is zero, and the closing balance
equals the opening, so the balance simply passes through to the next working
day. No opening balance is typed by the user and none is asked for — nobody
counts the drawer on a Sunday, so a typed figure would be fiction (Warnings
Guide L3-C).

`opening` is carried from the previous record. It is `NOT_COUNTED` only for a
closed genesis day, which should not happen but is not worth crashing over.
"""
function closed_day(d::Date, opening::Float64)
    a = blank_amounts()
    a[:opening_balance] = opening
    a[:closing_balance] = opening
    return DayRecord(d, a, STATUS_CLOSED, "")
end

"""
    group_amounts(rec)

Split one DayRecord back into the four per-group dicts that the ledger builder
expects: (cash, expense, deposit, related_party).

UNCHANGED IN v4.0, AND THAT IS THE POINT. It picks only from the four posting
arrays, so the cash-book and variance columns added in v4.0 can never reach
build_ledger_rows and can never generate a spurious ledger row.

This is the adapter that lets untouched v2.1.1 ledger code consume a single
day. `filter`-style comprehension over each config array pulls just that
group's keys out of the flat amounts dict.
"""
function group_amounts(rec::DayRecord)
    pick(categories) = Dict{Symbol,Float64}(c.key => rec.amounts[c.key] for c in categories)
    return pick(cash_eq_in), pick(expense), pick(deposit), pick(related_party)
end

# ---------------------------------------------------------------------------
# CSV input path (the one the HTML form will eventually target)
# ---------------------------------------------------------------------------
"""
    read_day_csv(path)

Reads a one-row CSV of the form:

    year,month,day,cash_sales,POS_Scotia,doctor_fees,deposits,...
    2026,9,14,620,0,80,500,...

Column ORDER is irrelevant and columns may be OMITTED entirely — anything
absent or blank is zero. This is deliberately the opposite of v2.1.1's input
file, which was a recording of menu keystrokes ("3", "610", "1", "2", ...) and
therefore broke silently if a category array was ever reordered.

The headers are Config keys, not labels — see Config.jl for why.
"""
function read_day_csv(path::AbstractString)
    isfile(path) || error("Input file not found: $path")

    # normalizenames=false keeps headers exactly as written so they match the
    # Symbol keys; a one-row file still comes back as a DataFrame.
    df = CSV.read(path, DataFrame; normalizenames=false)
    nrow(df) >= 1 || error("Input file $path has a header but no data row.")
    isone(nrow(df)) || @warn "Input file has $(nrow(df)) rows; only the first is used (one run = one day)."

    row = df[1, :]

    # --- date ---------------------------------------------------------------
    # Accept either three columns (year, month, day) or a single ISO `Date`.
    if hasproperty(row, :Date)
        d = row.Date isa Date ? row.Date : Date(String(row.Date))
    else
        y  = _as_int(row, :year,  "year")
        mo = _as_int(row, :month, "month")
        dy = _as_int(row, :day,   "day")
        d  = Date(y, mo, dy)   # Date() itself rejects e.g. 31 September
    end

    # --- amounts ------------------------------------------------------------
    # CHANGED IN v4.0: JOURNAL_KEYS, so opening_balance and closing_balance can
    # be supplied in the file. A cash-book column that is absent OR blank stays
    # NOT_COUNTED rather than becoming 0.0 — see _as_cashbook below.
    amounts = blank_amounts()
    for k in JOURNAL_KEYS
        col = colname_of(k)
        if hasproperty(row, Symbol(col))
            v = getproperty(row, Symbol(col))
            amounts[k] = k in CASH_BOOK_KEYS ? _as_cashbook(v) : _as_float(v)
        end
    end

    # Unknown columns are reported rather than ignored: a typo'd header would
    # otherwise be silently dropped and read as a zero.
    known = Set(vcat(["year", "month", "day", "Date", STATUS_COL, REASON_COL],
                     [colname_of(k) for k in JOURNAL_KEYS]))
    for c in names(df)
        c in known || @warn "Unrecognised column in input file, ignored: \"$c\""
    end

    return DayRecord(d, amounts)
end

# `ismissing` guards the case where CSV.jl parsed an empty cell as `missing`.
function _as_int(row, sym::Symbol, human::String)
    hasproperty(row, sym) || error("Input file is missing the required \"$human\" column.")
    v = getproperty(row, sym)
    (ismissing(v) || v === nothing) && error("Input file has a blank \"$human\".")
    return v isa Integer ? Int(v) : parse(Int, strip(string(v)))
end

"""
    _as_cashbook(v)

Like `_as_float`, except a blank cell means NOT_COUNTED rather than zero.

The whole point of the distinction: for a posted category, an empty cell means
nothing was spent. For a balance, it means nobody counted the drawer, and
reading it as 0.0 would invent a figure the operator never observed.
"""
function _as_cashbook(v)
    (ismissing(v) || v === nothing) && return NOT_COUNTED
    v isa Number && return Float64(v)
    s = strip(string(v))
    isempty(s) && return NOT_COUNTED
    return parse(Float64, s)
end

function _as_float(v)
    (ismissing(v) || v === nothing) && return 0.0
    v isa Number && return Float64(v)
    s = strip(string(v))
    isempty(s) && return 0.0
    return parse(Float64, s)
end

# ---------------------------------------------------------------------------
# Interactive input path (v2.1.1's prompts, kept for manual testing)
# ---------------------------------------------------------------------------
"""
    read_day_interactive()

The v2.1.1 prompt flow, trimmed to a single day. Retained verbatim in spirit
so the program is still driveable by hand.

FIXED FROM v2.1.1:
  * `cash_eq_in[c1]` indexed an array with the raw String from readline().
    Julia arrays cannot be indexed by String, so this crashed on the first
    real selection. Reverted to parsing the input as an Int first, as the
    original did (`c1 = parse(Int, readline())`), which also makes the bounds
    check below possible.
  * Same fix for `expense[c3]`.
  * `deposit[c1]` / `related_party[c1]` reused an index belonging to an
    unrelated menu; both groups have exactly one entry and no menu, so they
    are referenced as [1] directly.
  * Out-of-range menu selections now re-prompt instead of throwing BoundsError.
"""
function read_day_interactive()
    m, y = get_date()                       # from the getdate module

    println("\nPlease enter the date [number from 1-31] of this balance sheet.")
    d = Date(y, m, parse(Int, strip(readline())))

    amounts = blank_amounts()

    # NEW IN v4.0. A closed day short-circuits everything: no figures are typed
    # because nobody counted the drawer on a day the clinic was shut.
    println("\nWas the clinic CLOSED on this day (no trading)? [y/N]: ")
    if lowercase(strip(readline())) in ("y", "yes")
        println("Opening balance carried from the previous working day: ")
        carried = tryparse(Float64, strip(readline()))
        return closed_day(d, carried === nothing ? 0.0 : carried)
    end

    # The opening balance is TYPED, not carried, even though the program knows
    # what it should be. That is the whole overnight check — filling it in would
    # compare a number against itself and pass every time.
    println("\nOpening balance — what was in the drawer at the start of the day: ")
    amounts[:opening_balance] = _as_cashbook(strip(readline()))

    _menu_loop!(amounts, cash_eq_in,
        "cash or cash equivalent sales", "sales")
    _menu_loop!(amounts, expense,
        "expense", "expenses")

    println("\nPlease enter the total deposits for the day: ")
    amounts[deposit[1].key] = parse(Float64, strip(readline()))

    println("\nIf any money was taken out on behalf of a related party, please indicate the sum.\nOtherwise, enter 0: ")
    amounts[related_party[1].key] = parse(Float64, strip(readline()))

    # The closing balance is COUNTED. Asked for last, after every other figure,
    # so the operator is reporting the drawer rather than reconciling to it.
    println("\nClosing balance — COUNT the drawer and enter what is actually there.")
    println("Do not work it out from the figures above: ")
    amounts[:closing_balance] = _as_cashbook(strip(readline()))

    # NOTE: v2.1.1 ended here with "If you have another day's balance sheet to
    # record, enter 1" and recursed. Deliberately removed — one run, one day.

    # A difference will be reported by the checks; if one is found the run stops
    # and asks for a reason, which is collected here so the CLI path can supply
    # it the same way the form does.
    return DayRecord(d, amounts)
end

# The two near-identical while-loops from v2.1.1 (`pending` / `pending1`)
# collapsed into one function, since they differed only in which array they
# walked and what the prompt said.
function _menu_loop!(amounts::Dict{Symbol,Float64}, categories, noun::String, plural::String)
    pending = true
    while pending
        println("\nPlease select the $noun category you would like to update for the current day from the menu below:")
        for (i, category) in enumerate(categories)
            println("$i. $(category.label)")
        end
        println("\nEnter 0 if there were no $plural on this day. This will take you to the next section.")

        sel = tryparse(Int, strip(readline()))          # tryparse returns nothing instead of throwing
        if sel === nothing || sel < 0 || sel > length(categories)
            println("That is not one of the options. Please try again.")
            continue
        elseif sel == 0
            pending = false
        else
            chosen = categories[sel]
            println("\nOkay, you have selected $(chosen.label).\nPlease enter the total amount for the current day:")
            amounts[chosen.key] = parse(Float64, strip(readline()))

            println("\nAmount: \$$(amounts[chosen.key]) stored. Enter 1 to return to the menu.\nOtherwise, enter any other key to proceed to the next section.")
            strip(readline()) == "1" || (pending = false)
        end
    end
    return amounts
end

# ---------------------------------------------------------------------------
"""
    read_day(args)

Dispatcher: a path in ARGS means file mode, no path means interactive mode.
"""
function read_day(args::Vector{String})
    paths = filter(a -> !startswith(a, "--"), args)   # ignore flags like --force
    return isempty(paths) ? read_day_interactive() : read_day_csv(first(paths))
end

end # module DayInput
