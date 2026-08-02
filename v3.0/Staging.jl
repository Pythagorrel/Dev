module Staging

using Dates, DataFrames, CSV
using ..Config
using ..Layout
using ..DayInput
using ..Journal

# =============================================================================
# STAGING — days that have been entered but not yet committed.
#
# WHY THIS EXISTS: the browser must not be the only place a completed day lives.
# If the staging area were an array in JavaScript, closing the tab would lose
# an afternoon's work. So every completed day is POSTed to the server the
# moment it is finished and lands in a file here. The browser holds nothing it
# cannot re-fetch.
#
# WHAT IT DELIBERATELY IS NOT: this is not the journal. Nothing in this folder
# has been committed to the books — no ledger has been generated from it and
# the journal has not been touched. It is a notepad. Committing empties it.
#
# THE FORMAT IS THE JOURNAL FORMAT. The staging file has exactly the same
# columns as a Daily Journal, which means read_journal, upsert_day! and
# write_journal from Journal.jl all work on it unmodified — including the
# replace-don't-duplicate behaviour, which is what makes "edit a day I already
# entered" free. The one difference is that a staging file may span more than
# one month; nothing in those functions cares.
# =============================================================================

export staging_path, load_staged, stage_day!, unstage_day!, clear_staged!,
       staged_records, staged_count

"Where the notepad lives. Deliberately outside any year/month folder — it is not records."
staging_path() = joinpath(Layout.ROOT, "Staging", "Pending Entries.csv")

"""
    load_staged() -> DataFrame

The staged days, or an empty correctly-typed frame if nothing is staged.
Reuses Journal.read_journal, so a staging file written by an older version of
Config is repaired on read exactly as a journal would be.
"""
load_staged() = Journal.read_journal(staging_path())

"""
    stage_day!(rec) -> (count, replaced)

Add or replace one day in the notepad. `replaced` is true when this date was
already staged — the UI uses it to say "updated" rather than "added".
"""
function stage_day!(rec::DayRecord)
    df = load_staged()
    df, replaced = Journal.upsert_day!(df, rec)
    mkpath(dirname(staging_path()))
    Journal.write_journal(staging_path(), df)
    return nrow(df), replaced
end

"Remove one day from the notepad. Returns true if there was one to remove."
function unstage_day!(d::Date)
    df = load_staged()
    idx = findfirst(==(d), df[!, DATE_COL])
    idx === nothing && return false
    deleteat!(df, idx)
    Journal.write_journal(staging_path(), df)
    return true
end

"""
    clear_staged!()

Empty the notepad. Called only after a successful commit — by which point
every staged day is in a journal, so nothing is lost.
"""
function clear_staged!()
    p = staging_path()
    isfile(p) && rm(p)
    return nothing
end

"""
    staged_records() -> Vector{DayRecord}

The notepad turned back into DayRecords, in date order, ready to be fed to
process_day one at a time.
"""
function staged_records()
    df = load_staged()
    return [DayRecord(df[i, DATE_COL],
                      Dict{Symbol,Float64}(k => Float64(df[i, colname_of(k)]) for k in KEY_ORDER))
            for i in 1:nrow(df)]
end

staged_count() = nrow(load_staged())

end # module Staging
