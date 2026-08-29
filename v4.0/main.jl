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
include("Checks.jl");   using .Checks      # NEW in v4.0 — the four warning tiers
include("Chain.jl");    using .Chain       # NEW in v4.0 — prior-day lookup and the ledger gate
include("Report.jl");   using .Report      # NEW in v4.0 — local daily report

"""
    process_day(rec; force, echo, reason, allow_genesis, skip_checks)

One day, end to end. Returns a NamedTuple describing what happened.

REWRITTEN IN v4.0. v3.0 recorded whatever it was given. This version computes
the day's two variances, submits the day to Checks, refuses it outright if
anything impossible is present, and gates the ledger on the previous day being
on record. The v3.0 sequence (folders, journal upsert, daily ledger, monthly
rebuild, audit) is still there and still in that order — steps have been added
around it, not replaced.

ORDER IS DELIBERATE AND LOAD-BEARING:

  1. variances first, because the checks need them
  2. checks second, because a STOP must prevent the journal being touched at all
  3. journal third — the only mutation of record
  4. ledger fourth, and only if the gate opens
  5. held-day retry fifth, which is what makes a filled gap self-heal
  6. monthly rebuild last, so it sees everything the run did

A STOP THROWS. It does not warn and continue. A Level 1 finding describes
something that cannot physically have happened, so there is no version of
recording it that is useful, and letting it through would put a figure in the
journal that every later check would then have to work around.

A LEVEL 2 IS NOT A STOP. An unexplained difference is real and gets recorded,
with its reason, and posts to Cash Over/Short. Refusing it would not make the
cash reappear — it would push the operator to adjust a figure until the day fit,
and a plugged figure is undetectable by construction. The only requirement is
that the reason is not blank.
"""
function process_day(rec::DayRecord; force::Bool=false, echo::Bool=true,
                     allow_genesis::Bool=false, skip_checks::Bool=false)
    y, m, d = year(rec.date), month(rec.date), day(rec.date)

    # The audit log must exist before ANY refusal can be recorded. v3.0 created
    # the root at step 2, which was fine when nothing could fail earlier; v4.0
    # can refuse a day during the checks, and a refusal that cannot be logged
    # is worse than no check at all.
    mkpath(Layout.ROOT)
    session = AuditSession(joinpath(Layout.ROOT, "audit_log.txt"))
    echo && println("\nProcessing $(rec.date)...")

    # --- 1. Look back, and compute the two variances ------------------------
    # The ONLY place a day consults another day. Everything else in this
    # function uses figures typed for this date alone.
    # prior_day, not prior_record: the comparison is only meaningful against the
    # immediately preceding calendar day. With a date missing in between, the
    # difference would be that missing day's whole trading movement, and posting
    # it as an overnight variance would relabel a real day's takings as
    # unexplained cash. See Chain.prior_day.
    prior   = Chain.prior_day(rec.date)
    genesis = Chain.is_genesis_date(rec.date)
    prior_closing = prior === nothing ? nothing : prior.closing

    # A closed day has no counted figures, so it has no variances — it simply
    # carries the balance through. Computing one would compare a pass-through
    # against itself and always produce zero anyway, but stating it here keeps
    # the intent visible.
    if is_closed(rec)
        dv, ov = 0.0, 0.0
    else
        dv = Checks.day_residual(rec)
        ov = Checks.overnight_variance(rec, prior_closing)
    end

    # --- 2. Checks ----------------------------------------------------------
    findings = Checks.Finding[]
    if !skip_checks
        findings = check_day(rec;
                             prior_closing = prior_closing,
                             prior_date    = prior === nothing ? nothing : prior.date,
                             is_genesis    = genesis,
                             ledger_exists = isfile(daily_ledger_path(rec.date)))

        # STOP — refuse before anything is written.
        if has_stops(findings)
            msgs = join(["[$(f.code)] $(f.message)" for f in stops(findings)], "\n  ")
            log_event(session, "REFUSED $(rec.date): $(length(stops(findings))) blocking problem(s)"; echo=echo)
            log_entry(session; header="day $(rec.date) REFUSED")
            error("This day cannot be saved:\n  $msgs")
        end

        # EXPLAIN with no explanation — also refused, but for a different
        # reason: the difference is acceptable, the silence is not.
        if needs_reason(findings) && isempty(strip(rec.reason))
            log_event(session, "REFUSED $(rec.date): difference recorded with no reason given"; echo=echo)
            log_entry(session; header="day $(rec.date) REFUSED")
            error("This day does not balance and no reason was given.\n" *
                  "  Enter a short explanation and save again. \"Could not locate\" is a valid reason.")
        end

        # Genesis has to be authorised once, explicitly, and the authorisation
        # recorded. Without it the gate below would hold the very first ledger
        # forever and nothing would ever post.
        if genesis && !allow_genesis
            error("$(rec.date) would be the first day on record. Its opening balance " *
                  "cannot be checked against anything.\n" *
                  "  Re-run with --first-day (or tick the box in the form) to accept it " *
                  "as the starting point.")
        end
        genesis && log_event(session, "GENESIS: accepted $(rec.date) opening balance on trust"; echo=echo)

        for f in findings
            f.level == Checks.LEVEL_HINT && continue
            log_event(session, "[$(f.code)] $(level_name(f.level)): $(f.message)"; echo=echo)
        end
    end

    # Variances are stored on the record so they land in the journal as columns.
    # A journal column rather than a separate residuals file, because the whole
    # architecture rests on the journal being the only source of truth.
    rec.amounts[:day_variance]       = dv
    rec.amounts[:overnight_variance] = ov
    if abs(dv) >= 0.005 || abs(ov) >= 0.005
        log_event(session, "variance recorded — day $(round(dv, digits=2)), overnight $(round(ov, digits=2)); reason: $(isempty(rec.reason) ? "(none)" : rec.reason)"; echo=echo)
    end

    # --- 3. Folders and the journal (v3.0 behaviour, unchanged) -------------
    mdir, mdir_created = ensure_month_dir(y, m)
    log_event(session, mdir_created ? "created month folder $mdir" : "month folder exists: $mdir"; echo=echo)

    jpath = journal_path(y, m)
    journal_existed = isfile(jpath)
    df = read_journal(jpath)
    log_event(session, journal_existed ?
        "journal exists ($(nrow(df)) day(s) recorded): $(basename(jpath))" :
        "created journal: $(basename(jpath))"; echo=echo)

    df, replaced = upsert_day!(df, rec)
    write_journal(jpath, df)
    log_event(session, replaced ?
        "REPLACED existing entry for $(rec.date) in the journal" :
        "added entry for $(rec.date) to the journal"; echo=echo)

    # --- 4. The daily ledger, behind the gate -------------------------------
    ensure_daily_ledger_dir(y, m)
    ready, _, _ = Chain.ledger_ready(rec)
    ready = ready || genesis            # genesis has no predecessor and never will

    daily_ledger_status = _write_daily_ledger!(session, rec, dv, ov, ready, force, echo)

    # --- 5. Retry days that were waiting on this one ------------------------
    # THIS IS WHAT MAKES A FILLED GAP SELF-HEAL. Entering the missing Wednesday
    # releases Thursday's ledger on this run, with no separate command and no
    # event system — every pending day in the affected months is simply
    # re-offered to the gate.
    released = _retry_pending!(session, y, m, force, echo)

    # --- 6. The monthly ledger, rebuilt from the journal --------------------
    # Now carries the month's variance totals, so the monthly ledger and the sum
    # of the daily ledgers still agree.
    df = read_journal(jpath)
    mtot_cash, mtot_expense, mtot_deposit, mtot_rp = journal_totals(df)
    mvar = variance_totals(df)
    mlpath = monthly_ledger_path(y, m)
    monthly_existed = isfile(mlpath)
    write_ledger_csv(mtot_cash, mtot_expense, mtot_deposit, mtot_rp, mlpath;
                     day_variance=mvar.day, overnight_variance=mvar.overnight)
    log_event(session, monthly_existed ?
        "rebuilt monthly ledger from journal ($(nrow(df)) day(s))" :
        "created monthly ledger from journal ($(nrow(df)) day(s))"; echo=echo)

    log_entry(session; header="day $(rec.date)")

    return (date               = rec.date,
            ok                 = true,
            closed             = is_closed(rec),
            journal            = replaced ? "replaced" : "added",
            daily_ledger       = daily_ledger_status,
            monthly_ledger     = monthly_existed ? "rebuilt" : "created",
            days_in_month      = nrow(df),
            day_variance       = dv,
            overnight_variance = ov,
            reason             = rec.reason,
            released           = released,
            findings           = findings,
            output_dir         = mdir,
            events             = copy(session.events))
end

"""
    _write_daily_ledger!(...) -> status string

Steps 5–6 of the v3.0 pipeline plus the v4.0 gate. Split out because the retry
loop needs exactly the same behaviour for a day it is releasing.

The overwrite policy is unchanged from v3.0 and still asymmetric on purpose:
daily ledgers refuse to overwrite (there is no operator at a terminal to answer
a prompt, so the warning became a policy), monthly ledgers always overwrite
(they are derived, and rewriting them every run is what stops them drifting).
What v4.0 adds is that the refusal now has a name the operator sees — L3-B — and
the confirmation is recorded rather than merely acted on.
"""
function _write_daily_ledger!(session, rec::DayRecord, dv::Float64, ov::Float64,
                              ready::Bool, force::Bool, echo::Bool)
    # A closed day generates no ledger at all. Nothing moved, so there is
    # nothing to post, and an empty ledger file would just be noise in the
    # folder and a duplicate risk in QuickBooks.
    if is_closed(rec)
        log_event(session, "closed day — no ledger generated for $(rec.date)"; echo=echo)
        return "not applicable (closed)"
    end

    if !ready
        log_event(session, "HELD ledger for $(rec.date) — the day before it is not on record"; echo=echo)
        return "held"
    end

    dlpath = daily_ledger_path(rec.date)
    day_cash, day_expense, day_deposit, day_rp = DayInput.group_amounts(rec)

    if isfile(dlpath) && !force
        @warn "A daily ledger already exists for $(rec.date). It has NOT been overwritten."
        log_event(session, "REFUSED to overwrite existing daily ledger $(basename(dlpath))"; echo=echo)
        return "skipped"
    end

    overwriting = isfile(dlpath)
    write_ledger_csv(day_cash, day_expense, day_deposit, day_rp, dlpath;
                     day_variance=dv, overnight_variance=ov)
    log_event(session, overwriting ?
        "OVERWROTE daily ledger $(basename(dlpath)) — operator confirmed re-import is safe" :
        "wrote daily ledger $(basename(dlpath))"; echo=echo)
    return overwriting ? "overwritten" : "written"
end

"""
    _retry_pending!(session, y, m, force, echo) -> Vector{Date}

Re-offer every held day in this month and the next to the gate.

The NEXT month as well, because a day held on the 1st was waiting on the last
day of the previous month, and entering that day is exactly the event that
should release it.

Days are rebuilt from the journal rather than from anything held in memory, so
this works no matter how long ago they were entered or who entered them.
"""
function _retry_pending!(session, y::Integer, m::Integer, force::Bool, echo::Bool)
    released = Date[]
    ny, nm = m == 12 ? (y + 1, 1) : (y, m + 1)

    for (yy, mm) in ((y, m), (ny, nm))
        jp = journal_path(yy, mm)
        isfile(jp) || continue
        jdf = read_journal(jp)

        for pend in Chain.pending_ledgers(yy, mm)
            i = findfirst(==(pend), jdf[!, DATE_COL])
            i === nothing && continue

            amounts = Dict{Symbol,Float64}(k => Float64(jdf[i, colname_of(k)]) for k in JOURNAL_KEYS)
            prec = DayRecord(pend, amounts,
                             String(jdf[i, STATUS_COL]), String(jdf[i, REASON_COL]))

            ready, _, _ = Chain.ledger_ready(prec)
            ready || continue

            # --- Recompute variances against the now-available prior day ----
            # The values stored in the journal were computed at first entry,
            # when the prior day did not exist yet — so overnight_variance was
            # computed against `nothing` and stored as 0.0. Now the gap is
            # filled and the real prior closing is known; replaying the stale
            # zero would silently hide a genuine overnight movement.
            prior = Chain.prior_day(pend)
            new_dv = is_closed(prec) ? 0.0 : Checks.day_residual(prec)
            new_ov = is_closed(prec) ? 0.0 : Checks.overnight_variance(prec, prior === nothing ? nothing : prior.closing)

            if abs(new_ov - amounts[:overnight_variance]) >= 0.005 ||
               abs(new_dv - amounts[:day_variance]) >= 0.005
                # Update the journal row so the source of truth carries the
                # corrected figures. The monthly rebuild at step 6 re-reads
                # the journal, so it will pick these up automatically.
                amounts[:overnight_variance] = new_ov
                amounts[:day_variance]       = new_dv
                prec.amounts[:overnight_variance] = new_ov
                prec.amounts[:day_variance]       = new_dv
                jdf, _ = upsert_day!(jdf, prec)
                write_journal(jp, jdf)
                log_event(session, "RECOMPUTED variances for $pend — overnight $(round(new_ov, digits=2)), day $(round(new_dv, digits=2))"; echo=echo)
            end

            st = _write_daily_ledger!(session, prec,
                                      new_dv, new_ov,
                                      true, force, echo)
            if st in ("written", "overwritten")
                push!(released, pend)
                log_event(session, "RELEASED previously held ledger for $pend"; echo=echo)
            end
        end
    end
    return released
end

"""
    main(args)

The command-line front door. Unchanged in behaviour from before the server was
added: read one day, process it, print a summary.
"""
function main(args::Vector{String}=ARGS)
    force     = "--force" in args        # confirm a daily ledger may be regenerated
    genesis   = "--first-day" in args    # accept the very first opening balance on trust
    rec = DayInput.read_day(args)        # file if a path was given, prompts if not
    result = process_day(rec; force=force, allow_genesis=genesis)
    print_day_summary(rec)

    # NEW in v4.0. Written on every run, not only when something is wrong:
    # silence is ambiguous. A report that says "entered, balanced" also proves
    # the program ran, which an absent report cannot.
    rp = Report.write_report([result])
    println("\nDone. Files under: $(result.output_dir)")
    println("Report: $rp")
    return nothing
end

"""
Console summary. This is the one place LABELS are used rather than keys —
files on disk are keyed, humans read labels.
"""
function print_day_summary(rec::DayRecord)
    println("\n  Entries recorded for $(rec.date):")
    # v4.0: walk JOURNAL_KEYS so the balances and any variance appear too. A
    # summary that omitted the closing balance would hide the one figure the
    # day is actually checked against.
    any_nonzero = false
    for k in JOURNAL_KEYS
        v = rec.amounts[k]
        if isnan(v)
            println("    $(rpad(label_of(k), 34)) (not counted)")
            any_nonzero = true
        elseif v != 0.0
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
