module Journal

using Dates, CSV, DataFrames
using ..Config
using ..DayInput

# =============================================================================
# JOURNAL — the Daily Journal file, and the only thing this program treats as
# authoritative.
#
# THE CENTRAL CHANGE FROM v2.1.1. Previously both output files were products of
# one input session: the ledger was built from totals that existed only in RAM
# while csv1() was running, so a ledger's time period was "whatever the user
# happened to type that sitting". That is the direct cause of the missed dates
# and awkwardly grouped periods.
#
# Now a run mutates exactly one piece of persistent state: it upserts one row
# into this file. Both ledgers are pure functions of file contents, recomputed
# on demand. Consequences worth stating plainly:
#   * Re-running the same date REPLACES that date's row rather than appending a
#     duplicate, so a correction is just a re-run.
#   * The monthly ledger cannot drift from the journal, because it is rebuilt
#     from the journal every single run.
#
# This module also supersedes v2.1.1's build_daily_records/write_daily_records_csv.
# Those built a whole month's table in one shot from in-memory vectors; the
# equivalents here (row_of, upsert_day!) work one row at a time against disk.
# =============================================================================

export empty_journal, read_journal, write_journal, upsert_day!,
       journal_totals, row_of, display_view, variance_totals, day_count

"""
    empty_journal()

A zero-row DataFrame carrying the correct schema: a `Date` column typed as
`Date`, then one Float64 column per configured category, in KEY_ORDER.

`DataFrame(pairs)` builds columns from `name => vector` pairs; the vectors are
empty here, which is what fixes the element types without adding any rows.
"""
function empty_journal()
    cols = Pair{String,Any}[DATE_COL => Date[]]
    # CHANGED IN v4.0: JOURNAL_KEYS, not KEY_ORDER. KEY_ORDER is the POSTING
    # categories and is what Ledger.jl walks; JOURNAL_KEYS is that list plus the
    # cash book and the two variance columns. Keeping them distinct is what lets
    # a balance be stored without ever reaching the ledger builder.
    for k in JOURNAL_KEYS
        push!(cols, colname_of(k) => Float64[])
    end
    # NEW IN v4.0. Two text columns:
    #   Status — "trading" or "closed". A closed day is a real row with zero
    #            movement, which is what keeps the chain continuous in the file.
    #   Reason — the typed explanation for a Level 2 override. It lives with the
    #            day permanently; a report is a notification, not a record.
    push!(cols, STATUS_COL => String[])
    push!(cols, REASON_COL => String[])
    return DataFrame(cols)
end

"""
    row_of(rec)

One DayRecord as a NamedTuple ready to be pushed into the journal.

Replaces v2.1.1's build_daily_records, which produced the whole table at once.
Note the header source: `colname_of(k)` (the key), not `category.label`. This
is the change you asked for — labels are now display-only, so rewording one
can never orphan a historical journal.
"""
function row_of(rec::DayRecord)
    vals = Any[rec.date]
    names_ = Symbol[Symbol(DATE_COL)]
    for k in JOURNAL_KEYS
        push!(names_, Symbol(colname_of(k)))
        push!(vals, rec.amounts[k])
    end
    push!(names_, Symbol(STATUS_COL)); push!(vals, rec.status)
    push!(names_, Symbol(REASON_COL)); push!(vals, rec.reason)
    return NamedTuple{Tuple(names_)}(Tuple(vals))
end

"""
    read_journal(path)

Loads the journal if it exists, otherwise hands back an empty one with the
right schema. The caller therefore never has to branch on "first run of the
month" — that case is just a journal with no rows.
"""
function read_journal(path::AbstractString)
    isfile(path) || return empty_journal()
    df = CSV.read(path, DataFrame; normalizenames=false)
    return conform!(df)
end

"""
    conform!(df)

Forces a journal read off disk into the current schema.

This is the migration hook. If a new category is added to Config, last month's
journals will not have that column; rather than crashing, the column is added
and backfilled with zeros. Columns present on disk but no longer in Config are
left alone — the program will not delete a client's historical data because a
category was retired.
"""
function conform!(df::DataFrame)
    # Date column: CSV.jl usually infers Date from an ISO string, but if the
    # file was ever hand-edited it can come back as String.
    if DATE_COL in names(df)
        if !(eltype(df[!, DATE_COL]) <: Date)
            df[!, DATE_COL] = Date.(string.(df[!, DATE_COL]))
        end
    else
        error("Journal file is missing its \"$DATE_COL\" column — refusing to guess.")
    end

    # CHANGED IN v4.0. Two things happen here that did not before.
    #
    # 1. The loop walks JOURNAL_KEYS, so the cash book and variance columns are
    #    conformed alongside the posting categories.
    #
    # 2. A BLANK CELL NO LONGER ALWAYS MEANS ZERO. For a posting category it
    #    still does — no taxi fares that day, so nothing was spent. For a cash
    #    BALANCE it does not: blank means the drawer was never counted, and
    #    reading that as zero would invent a balance nobody observed. Blank
    #    balances therefore come back as NOT_COUNTED, which the stop checks pick
    #    up as L1-C.
    #
    #    This also protects the migration case. A journal written by v3.0 has no
    #    balance columns at all. Backfilling them with zeros would assert that
    #    every historical drawer closed empty, and the month-level check would
    #    then read those zeros as real. Backfilling with NOT_COUNTED says the
    #    truthful thing: v3.0 did not record this.
    for k in JOURNAL_KEYS
        col = colname_of(k)
        blank = k in CASH_BOOK_KEYS ? NOT_COUNTED : 0.0
        if col in names(df)
            df[!, col] = Float64.(coalesce.(df[!, col], blank))
        else
            @info "Journal predates column \"$(label_of(k))\" — backfilling."
            df[!, col] = fill(blank, nrow(df))
        end
    end

    # Text columns. A journal predating v4.0 has neither; every existing row in
    # such a file was a day somebody traded, so "trading" is the correct
    # backfill rather than a guess.
    if STATUS_COL in names(df)
        df[!, STATUS_COL] = String.(coalesce.(df[!, STATUS_COL], STATUS_TRADING))
    else
        df[!, STATUS_COL] = fill(STATUS_TRADING, nrow(df))
    end
    if REASON_COL in names(df)
        df[!, REASON_COL] = String.(coalesce.(df[!, REASON_COL], ""))
    else
        df[!, REASON_COL] = fill("", nrow(df))
    end

    # Backfilled columns are appended wherever they land, so the frame is
    # re-ordered into canonical KEY_ORDER before it is written back. Any column
    # NOT in the current config (a retired category) is kept and pushed to the
    # end rather than dropped — the program does not delete a client's
    # historical data just because a category was removed from Config.
    canonical = vcat(DATE_COL, [colname_of(k) for k in JOURNAL_KEYS], STATUS_COL, REASON_COL)
    extras = setdiff(names(df), canonical)
    isempty(extras) || @info "Journal has retired column(s), preserved at the end: $(join(extras, ", "))"
    select!(df, vcat(canonical, extras))

    return df
end

"""
    upsert_day!(df, rec) -> (df, replaced::Bool)

Insert this day, or replace it if it is already present, then re-sort by date.

`findfirst(==(rec.date), df[!, DATE_COL])` returns the index of the matching
row or `nothing`. This is the whole idempotency guarantee — running the same
date twice can never produce two rows for it, so the month's totals cannot be
double-counted.

`replaced` is returned rather than swallowed so the driver can report an
overwrite instead of performing it silently.
"""
function upsert_day!(df::DataFrame, rec::DayRecord)
    idx = findfirst(==(rec.date), df[!, DATE_COL])
    row = row_of(rec)

    if idx === nothing
        # A journal carrying retired columns (see conform!) has MORE columns
        # than the NamedTuple built from the current config, and push! of a
        # short NamedTuple is an error. Widen the row to whatever the frame
        # actually has, zeroing anything the config no longer knows about.
        newrow = Dict{String,Any}(String(k) => v for (k, v) in pairs(row))
        for c in names(df)
            # CHANGED IN v4.0: a retired column may now be text as well as
            # numeric, and filling a String column with 0.0 is a type error.
            haskey(newrow, c) || (newrow[c] = eltype(df[!, c]) <: AbstractString ? "" : 0.0)
        end
        push!(df, newrow; cols=:setequal)
        replaced = false
    else
        # On replace, retired columns are left at their existing values rather
        # than zeroed — that is historical data this program did not author and
        # has no business erasing.
        for (name, val) in pairs(row)
            df[idx, string(name)] = val
        end
        replaced = true
    end

    sort!(df, Symbol(DATE_COL))   # keeps the file in date order regardless of entry order
    return df, replaced
end

write_journal(path::AbstractString, df::DataFrame) = CSV.write(path, df)

"""
    journal_totals(df)

Column-sum the whole journal into the four per-group dicts.

This is the inverse of DayInput.group_amounts, and it returns the identical
shape — Dict{Symbol,Float64} per group. That is why the monthly ledger needs no
ledger code of its own: whether the numbers came from one day in memory or
thirty days on disk, build_ledger_rows sees the same four dicts.

`sum(col; init=0.0)` gives 0.0 for an empty journal rather than erroring.

UNCHANGED IN v4.0 AND DELIBERATELY SO: it totals only the four posting arrays,
so the cash book and variance columns cannot leak into the ledger through this
route either. Variance totals are fetched separately by `variance_totals`.
"""
function journal_totals(df::DataFrame)
    tot(categories) = Dict{Symbol,Float64}(
        c.key => sum(df[!, colname_of(c.key)]; init=0.0) for c in categories)
    return tot(cash_eq_in), tot(expense), tot(deposit), tot(related_party)
end

"""
    display_view(df)

A copy of the journal with key headers swapped for human labels. Used only for
on-screen summaries — never written to disk, so the file on disk stays keyed.
"""
function display_view(df::DataFrame)
    out = copy(df)
    rename!(out, Dict(colname_of(k) => label_of(k) for k in JOURNAL_KEYS if colname_of(k) in names(out)))
    return out
end

"""
    variance_totals(df) -> (day, overnight, total)

Sum of the two variance columns across a journal.

Kept out of `journal_totals` on purpose. That function returns the four dicts
`build_ledger_rows` consumes, and variances are not a category — they are a
correction applied once, at the end, against a single account. Mixing them in
would have meant giving them a fake category entry, which is exactly the
Config.jl obstacle the cash book was restructured to avoid.
"""
function variance_totals(df::DataFrame)
    get_sum(k) = colname_of(k) in names(df) ?
        sum(x -> isnan(x) ? 0.0 : x, df[!, colname_of(k)]; init=0.0) : 0.0
    dv = get_sum(:day_variance)
    ov = get_sum(:overnight_variance)
    return (day = dv, overnight = ov, total = dv + ov)
end

"Number of days recorded, excluding closed days."
function day_count(df::DataFrame)
    STATUS_COL in names(df) || return nrow(df)
    return count(i -> String(df[i, STATUS_COL]) != STATUS_CLOSED, 1:nrow(df))
end

end # module Journal
