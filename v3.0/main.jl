# =============================================================================
# main.jl — the driver. This file replaces the ~10 loose lines at the bottom of
# v2_1_1.jl and is the only entry point.
#
# USAGE
#   julia main.jl path/to/day.csv          # file mode (what the HTML form targets)
#   julia main.jl path/to/day.csv --force  # allow overwriting an existing daily ledger
#   julia main.jl                          # interactive mode, prompts as before
#
# WHAT ONE RUN DOES, IN ORDER
#   1. read exactly one day
#   2. ensure <ROOT>/<year>/<mm>/ exists                        (creating both levels)
#   3. ensure the Daily Journal for that month exists           (creating if absent)
#   4. upsert this day into the journal and write it back       <- only mutation of record
#   5. ensure the "Daily Ledgers mm-yyyy" folder exists
#   6. write the daily ledger for this date, warning first if one already exists
#   7. rebuild the monthly ledger FROM THE JOURNAL (always overwritten)
#   8. flush the audit log
#
# FIXED FROM v2.1.1: `incldue("get_date.jl")` was misspelled, so the file never
# loaded; and `using .get_date` referred to a module that had no name. Both are
# corrected in the include block below.
# =============================================================================

using Dates, DataFrames, CSV

# Include order matters: a module that does `using ..X` needs X already
# defined. Config has no dependencies, so it goes first; main.jl is the only
# place this ordering is expressed.
include("Config.jl");   using .Config
include("AuditLog.jl"); using .AuditLog
include("Layout.jl");   using .Layout
include("getdate.jl");  using .getdate
include("DayInput.jl"); using .DayInput
include("Journal.jl");  using .Journal
include("Ledger.jl");   using .Ledger

"""
    process_day(rec; force=false, echo=true)

Steps 2 to 8 for one day, callable from anywhere.

WHY THIS WAS SPLIT OUT OF main(): the web server needs to run exactly the same
pipeline, and the only alternative would have been for the server to re-implement
these steps — which is precisely how two code paths drift apart. main() is now
just "get a day, hand it to process_day"; the server is "get a day, hand it to
process_day". One pipeline, two front doors.

Returns a NamedTuple describing what happened, so a caller that has no terminal
(i.e. the server) can report it to the user some other way.
"""
function process_day(rec::DayRecord; force::Bool=false, echo::Bool=true)
    y, m, d = year(rec.date), month(rec.date), day(rec.date)

    session = AuditSession(joinpath(Layout.ROOT, "audit_log.txt"))
    echo && println("\nProcessing $(rec.date)...")

    # --- 2. year / month folders -------------------------------------------
    mdir, mdir_created = ensure_month_dir(y, m)
    mkpath(Layout.ROOT)   # guarantees the audit log has somewhere to live
    log_event(session, mdir_created ? "created month folder $mdir" : "month folder exists: $mdir")

    # --- 3 & 4. the Daily Journal ------------------------------------------
    jpath = journal_path(y, m)
    journal_existed = isfile(jpath)
    df = read_journal(jpath)          # returns an empty, correctly-typed frame if absent
    log_event(session, journal_existed ?
        "journal exists ($(nrow(df)) day(s) recorded): $(basename(jpath))" :
        "created journal: $(basename(jpath))")

    df, replaced = upsert_day!(df, rec)
    write_journal(jpath, df)
    log_event(session, replaced ?
        "REPLACED existing entry for $(rec.date) in the journal" :
        "added entry for $(rec.date) to the journal")

    # --- 5 & 6. the daily ledger -------------------------------------------
    dldir, dldir_created = ensure_daily_ledger_dir(y, m)
    log_event(session, dldir_created ? "created daily-ledger folder $(basename(dldir))" :
                                       "daily-ledger folder exists: $(basename(dldir))")

    dlpath = daily_ledger_path(rec.date)
    day_cash, day_expense, day_deposit, day_rp = DayInput.group_amounts(rec)

    if isfile(dlpath) && !force
        # The "warn before generation" requirement, resolved for a headless
        # program. There is no operator to answer a prompt, so the policy is:
        # refuse, report, and leave the existing file untouched. Re-run with
        # --force to overwrite deliberately. The journal above was still
        # updated, so no data is lost by refusing here.
        @warn "A daily ledger already exists for $(rec.date):\n  $dlpath\n" *
              "It has NOT been overwritten. Re-run with --force if that is what you want."
        log_event(session, "REFUSED to overwrite existing daily ledger $(basename(dlpath))")
        daily_ledger_status = "skipped"
    else
        overwriting = isfile(dlpath)
        write_ledger_csv(day_cash, day_expense, day_deposit, day_rp, dlpath)
        log_event(session, overwriting ?
            "OVERWROTE daily ledger $(basename(dlpath)) (--force)" :
            "wrote daily ledger $(basename(dlpath))")
        daily_ledger_status = overwriting ? "overwritten" : "written"
    end

    # --- 7. the monthly ledger, rebuilt from the journal --------------------
    # Note what is NOT happening here: nothing accumulates the month in memory.
    # The totals are column sums of the file that was just written, so the
    # monthly ledger is correct even if earlier days were entered on a
    # different machine, out of order, or corrected after the fact.
    mtot_cash, mtot_expense, mtot_deposit, mtot_rp = journal_totals(df)
    mlpath = monthly_ledger_path(y, m)
    monthly_existed = isfile(mlpath)
    write_ledger_csv(mtot_cash, mtot_expense, mtot_deposit, mtot_rp, mlpath)
    log_event(session, monthly_existed ?
        "rebuilt monthly ledger from journal ($(nrow(df)) day(s))" :
        "created monthly ledger from journal ($(nrow(df)) day(s))")

    # --- 8. audit ------------------------------------------------------------
    log_entry(session; header="day $(rec.date)")

    return (date            = rec.date,
            journal         = replaced ? "replaced" : "added",
            daily_ledger    = daily_ledger_status,
            monthly_ledger  = monthly_existed ? "rebuilt" : "created",
            days_in_month   = nrow(df),
            output_dir      = mdir,
            events          = copy(session.events))
end

"""
    main(args)

The command-line front door. Unchanged in behaviour from before the server was
added: read one day, process it, print a summary.
"""
function main(args::Vector{String}=ARGS)
    force = "--force" in args        # explicit opt-in to overwrite a daily ledger
    rec = DayInput.read_day(args)    # file if a path was given, prompts if not
    result = process_day(rec; force=force)
    print_day_summary(rec)
    println("\nDone. Files under: $(result.output_dir)")
    return nothing
end

"""
Console summary. This is the one place LABELS are used rather than keys —
files on disk are keyed, humans read labels.
"""
function print_day_summary(rec::DayRecord)
    println("\n  Entries recorded for $(rec.date):")
    any_nonzero = false
    for k in KEY_ORDER
        v = rec.amounts[k]
        if v != 0.0
            any_nonzero = true
            println("    $(rpad(label_of(k), 34)) \$$(round(v, digits=2))")
        end
    end
    any_nonzero || println("    (no activity — all categories zero)")
end

# Runs only when this file is executed as a script, not when it is included
# from a test file. PROGRAM_FILE is the path Julia was invoked with.
if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
