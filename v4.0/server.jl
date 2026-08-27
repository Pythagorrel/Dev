#!/usr/bin/env julia
# =============================================================================
# server.jl — the local web server.
#
# RUN IT:   julia server.jl          then open http://127.0.0.1:8000
#           julia server.jl 9000     to use a different port
#
# WHAT THIS FILE IS: the boundary between the browser and the bookkeeping code.
# It is the ONLY place where those two meet. The browser speaks JSON about days;
# this file turns that JSON into a DayRecord and hands it to the same
# process_day the command line uses. The browser never learns that ledgers,
# journals, accounts or double-entry exist.
#
# WHY A SERVER RATHER THAN A DOWNLOADED FILE: the old form produced a file you
# then had to find, open a terminal for, and run by hand. Three manual steps per
# day. It also meant every run re-loaded DataFrames and CSV from scratch —
# several seconds before any work began. This process loads them once at
# startup and stays warm, so each submission is effectively instant.
#
# IT LISTENS ON 127.0.0.1 ONLY. That is the loopback address: reachable from
# this machine and nothing else. It is not exposed to the network, and it has
# no authentication because it does not need any. Do not change that host to
# 0.0.0.0 without adding authentication first.
# =============================================================================

using HTTP, JSON3, Dates, DataFrames, Logging

include("main.jl")                        # Config, Layout, DayInput, Journal, Ledger, AuditLog, process_day
include("Staging.jl"); using .Staging

# v4.0: Checks/Chain/Report come in through main.jl above.

const PUBLIC_DIR = joinpath(@__DIR__, "public")
const PORT = isempty(ARGS) ? 8000 : parse(Int, ARGS[1])

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
json(status::Int, data) = HTTP.Response(status,
    ["Content-Type" => "application/json; charset=utf-8",
     "Cache-Control" => "no-store"], JSON3.write(data))

fail(status::Int, msg::AbstractString; field::Union{Nothing,String}=nothing) =
    json(status, (ok=false, error=msg, field=field))

const MIMES = Dict(".html" => "text/html; charset=utf-8",
                   ".js"   => "application/javascript; charset=utf-8",
                   ".css"  => "text/css; charset=utf-8",
                   ".ico"  => "image/x-icon")

"""
    serve_static(path)

Serve a file from public/. `basename` strips any directory component from the
requested path before it is used, so a request for `../../etc/passwd` becomes a
request for `passwd` and simply 404s. Even on loopback, a server should not be
willing to read outside its own folder.
"""
function serve_static(reqpath::AbstractString)
    name = basename(reqpath)
    isempty(name) && (name = "index.html")
    file = joinpath(PUBLIC_DIR, name)
    isfile(file) || return HTTP.Response(404, "Not found")
    ext = lowercase(splitext(name)[2])
    return HTTP.Response(200, ["Content-Type" => get(MIMES, ext, "application/octet-stream"),
                               "Cache-Control" => "no-store"], read(file))
end

# ---------------------------------------------------------------------------
# Capturing warnings so the browser can show them
# ---------------------------------------------------------------------------
"""
A logger that copies warnings into a list while still printing them to the
server console.

WHY: the negative-undeposited-funds warning is raised deep inside Ledger.jl with
`@warn`, which writes to the terminal. Nobody is looking at the terminal any
more. Rather than change Ledger.jl to return warnings (which would mean editing
accounting code for a user-interface reason), the warnings are simply collected
as they pass by and attached to the response.
"""
struct CollectLogger <: Logging.AbstractLogger
    sink::Vector{String}
    parent::Logging.AbstractLogger
end
Logging.min_enabled_level(::CollectLogger) = Logging.Debug
Logging.shouldlog(::CollectLogger, args...) = true
Logging.catch_exceptions(::CollectLogger) = false
function Logging.handle_message(l::CollectLogger, level, message, _module, group, id, file, line; kwargs...)
    level >= Logging.Warn && push!(l.sink, replace(string(message), "\n" => " "))
    Logging.handle_message(l.parent, level, message, _module, group, id, file, line; kwargs...)
end

# ---------------------------------------------------------------------------
# Turning a JSON body into a DayRecord — the trust boundary
# ---------------------------------------------------------------------------
"""
    record_from_payload(body) -> DayRecord

Validates and converts. The browser validates too, but that is purely so the
user gets instant feedback; it is not security and it is not correctness. A
browser can be bypassed, a page can be stale, JavaScript can be disabled. Every
rule the front end enforces is enforced again here, and this is the copy that
counts.

Throws ArgumentError with a human-readable message on any bad input.
"""
function record_from_payload(body)
    haskey(body, :date) || throw(ArgumentError("No date was supplied."))

    d = try
        Date(String(body.date))                      # expects YYYY-MM-DD
    catch
        throw(ArgumentError("\"$(body.date)\" is not a valid date."))
    end

    d > Dates.today() && throw(ArgumentError("$(d) is in the future."))
    year(d) < 2000 && throw(ArgumentError("$(d) is too far in the past to be a real entry."))

    # NEW IN v4.0 — closed days.
    # A closed day is built here rather than trusted from the browser: the
    # opening is carried from the previous record and the closing is set equal
    # to it, so the balance passes through and nobody types a figure for a
    # drawer nobody counted (Warnings Guide L3-C).
    status = String(get(body, :status, DayInput.STATUS_TRADING))
    if status == DayInput.STATUS_CLOSED
        prior = Chain.prior_day(d)
        carried = prior === nothing ? 0.0 : prior.closing
        return DayInput.closed_day(d, carried)
    end

    amounts = DayInput.blank_amounts()               # posting keys 0.0, balances NOT_COUNTED
    raw = get(body, :amounts, nothing)
    if raw !== nothing
        valid = Set(String(colname_of(k)) for k in JOURNAL_KEYS)
        for (name, value) in pairs(raw)
            key = String(name)
            key in valid || throw(ArgumentError("Unknown category \"$key\"."))

            # NEW IN v4.0. An empty string on a CASH BOOK field means the drawer
            # was not counted and must stay NOT_COUNTED so that L1-C fires. On
            # every other field an empty string still means zero, exactly as
            # before. This is the one place the blank/zero distinction crosses
            # the wire, and getting it wrong here would silently invent a
            # balance — so the two cases are separated explicitly rather than
            # sharing a default.
            if value === nothing || (value isa AbstractString && isempty(strip(String(value))))
                amounts[Symbol(key)] = Symbol(key) in CASH_BOOK_KEYS ? DayInput.NOT_COUNTED : 0.0
                continue
            end

            v = value isa Number ? Float64(value) :
                something(tryparse(Float64, strip(String(value))), NaN)
            isnan(v) && throw(ArgumentError("\"$(label_of(Symbol(key)))\" is not a number."))
            v < 0 && throw(ArgumentError("\"$(label_of(Symbol(key)))\" cannot be negative."))
            amounts[Symbol(key)] = v
        end
    end

    reason = String(get(body, :reason, ""))
    return DayRecord(d, amounts, DayInput.STATUS_TRADING, reason)
end

"""
    findings_json(rec) -> Vector

Run the checks for one day and render them for the browser.

The browser NEVER decides severity for itself. It is told the level, the code
and the message, and it renders what it is told. That is what keeps the two
copies of a rule from drifting: there is only one copy, here, and app.js is a
display layer for its output (Handover §4 rule 5).
"""
function findings_json(rec::DayRecord)
    prior   = Chain.prior_day(rec.date)
    genesis = Chain.is_genesis_date(rec.date)
    fs = check_day(rec;
                   prior_closing = prior === nothing ? nothing : prior.closing,
                   prior_date    = prior === nothing ? nothing : prior.date,
                   is_genesis    = genesis,
                   ledger_exists = isfile(daily_ledger_path(rec.date)))
    return [(code=f.code, level=f.level, levelName=level_name(f.level),
             field=f.field === nothing ? nothing : String(f.field),
             message=f.message) for f in fs]
end

# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

"""
GET /api/config

The shape of the form, built from Config.jl at request time.

THIS IS WHY THE FRONT END HAS NO HARDCODED CATEGORY LIST. Add a category to
Config.jl, restart the server, and the field appears in the browser by itself.
The old form had its own copy of the category list, which meant adding one
required editing two files that had no way of noticing they disagreed.
"""
function handle_config()
    group(cats) = [(key=String(c.key), label=c.label) for c in cats]
    return json(200, (
        ok = true,
        today = string(Dates.today()),
        groups = [
            (id="cash",     title="Cash & Card Takings",
             hint="Money taken in over the counter and through the card machines.",
             categories=group(cash_eq_in)),
            (id="expenses", title="Expenses",
             hint="Money paid out of petty cash during the day.",
             categories=group(expense)),
            (id="other",    title="Banking & Related Party",
             hint="What was banked, and anything drawn on behalf of a related party.",
             categories=group(vcat(deposit, related_party))),
            # NEW IN v4.0. The cash book is sent as its own group so the form
            # can render the balances separately and label them as counted
            # figures. It is generated from Config like every other group, so
            # the front end still holds no category names of its own.
            (id="cashbook", title="Cash Book — counted, not calculated",
             hint="Count the drawer. Do not work these out from the figures above — " *
                  "that is what makes the check meaningful.",
             categories=group(cash_book)),
        ],
        keyOrder = [String(k) for k in KEY_ORDER],
        # Sent so the running total on the entry screen can show the banked figure
        # without the browser having to know that a category called "deposits"
        # exists. The front end holds no category names of its own.
        depositKey = String(deposit[1].key),
        # v4.0: sent so app.js can compute a live PREDICTED closing balance to
        # display beside the counted one, without knowing any category names.
        openingKey  = String(:opening_balance),
        closingKey  = String(:closing_balance),
        inflowKeys  = [String(k) for k in IDENTITY_INFLOW_KEYS],
        outflowKeys = [String(k) for k in IDENTITY_OUTFLOW_KEYS],
        labels = Dict(String(k) => label_of(k) for k in JOURNAL_KEYS),
    ))
end

"""
GET /api/staged

Everything currently on the notepad, annotated with what committing it would do.

The annotations are the reason the review screen is worth having. `inJournal`
means this date is already recorded and committing will replace it;
`hasDailyLedger` means a ledger file already exists and will be left alone
unless the overwrite box is ticked. Both are visible before anything is
written, rather than discovered afterwards.
"""
function handle_staged()
    days = map(Staging.staged_records()) do rec
        y, m = year(rec.date), month(rec.date)
        jpath = journal_path(y, m)
        in_journal = false
        if isfile(jpath)
            jdf = Journal.read_journal(jpath)
            in_journal = findfirst(==(rec.date), jdf[!, DATE_COL]) !== nothing
        end
        # NaN cannot be represented in JSON, so an uncounted balance is sent as
        # null and app.js renders it as an empty box.
        amt = Dict{String,Any}()
        for k in JOURNAL_KEYS
            v = rec.amounts[k]
            amt[String(colname_of(k))] = isnan(v) ? nothing : v
        end
        (date = string(rec.date),
         amounts = amt,
         status = rec.status,
         reason = rec.reason,
         findings = findings_json(rec),
         inJournal = in_journal,
         hasDailyLedger = isfile(daily_ledger_path(rec.date)))
    end
    return json(200, (ok=true, days=days))
end

"POST /api/staged — add or replace one day on the notepad."
function handle_stage(req)
    body = try
        JSON3.read(String(req.body))
    catch
        return fail(400, "The request could not be read.")
    end

    rec = try
        record_from_payload(body)
    catch e
        return fail(400, e isa ArgumentError ? e.msg : "That day could not be accepted.")
    end

    # v4.0: a STOP is refused at staging time, not merely at commit. There is no
    # value in letting an impossible day sit on the notepad until the end of the
    # session — the operator is looking at the figures now.
    fs = findings_json(rec)
    if any(f -> f.level == Checks.LEVEL_STOP, fs)
        return json(400, (ok=false, error="This day cannot be saved yet.", findings=fs))
    end

    count, replaced = Staging.stage_day!(rec)
    return json(200, (ok=true, date=string(rec.date), replaced=replaced,
                      staged=count, findings=fs,
                      needsReason=any(f -> f.level == Checks.LEVEL_EXPLAIN, fs)))
end

"""
GET /api/prior?date=YYYY-MM-DD

What the previous calendar day closed at, so the form can show the operator what
their opening balance is expected to match.

DELIBERATELY NOT PRE-FILLED INTO THE FIELD. Showing the figure helps; typing it
into the box would make the overnight check compare a number against itself and
pass every time (Warnings Guide §8). The response is labelled `expected` rather
than `value` for that reason.
"""
function handle_prior(uri)
    q = HTTP.queryparams(uri)
    haskey(q, "date") || return fail(400, "No date given.")
    d = try Date(q["date"]) catch; return fail(400, "Not a valid date.") end

    prior = Chain.prior_day(d)
    return json(200, (ok = true,
                      genesis = Chain.is_genesis_date(d),
                      hasPrior = prior !== nothing,
                      priorDate = prior === nothing ? nothing : string(prior.date),
                      expected = prior === nothing ? nothing : prior.closing))
end

"""
POST /api/check — run the checks WITHOUT saving anything.

Lets the form show a Level 2 difference and ask for a reason before the day is
committed, rather than rejecting it afterwards.
"""
function handle_check(req)
    body = try JSON3.read(String(req.body)) catch; return fail(400, "The request could not be read.") end
    rec = try record_from_payload(body) catch e
        return fail(400, e isa ArgumentError ? e.msg : "That day could not be read.")
    end
    fs = findings_json(rec)
    return json(200, (ok = true,
                      findings = fs,
                      predicted = is_closed(rec) ? nothing : Checks.predicted_closing(rec),
                      needsReason = any(f -> f.level == Checks.LEVEL_EXPLAIN, fs),
                      blocked = any(f -> f.level == Checks.LEVEL_STOP, fs)))
end

"DELETE /api/staged?date=YYYY-MM-DD — take one day back off the notepad."
function handle_unstage(uri)
    q = HTTP.queryparams(uri)
    haskey(q, "date") || return fail(400, "No date given.")
    d = try
        Date(q["date"])
    catch
        return fail(400, "Not a valid date.")
    end
    removed = Staging.unstage_day!(d)
    return json(200, (ok=true, removed=removed, staged=Staging.staged_count()))
end

"""
POST /api/commit — the only endpoint that writes to the books.

Runs the staged days through process_day one at a time, oldest first, exactly
as the command line would. Nothing new happens here; this is a loop around
existing behaviour.

The notepad is cleared only if every day succeeded. A partial failure leaves the
remaining days staged so nothing has to be retyped.
"""
function handle_commit(req)
    body = isempty(req.body) ? Dict{Symbol,Any}() : try
        JSON3.read(String(req.body))
    catch
        Dict{Symbol,Any}()
    end
    force        = get(body, :force, false) === true          # QuickBooks re-import confirmed
    allowGenesis = get(body, :allowGenesis, false) === true    # first-ever opening balance accepted

    records = Staging.staged_records()
    isempty(records) && return fail(400, "There is nothing to save yet.")

    results  = []
    outcomes = []            # v4.0: the raw NamedTuples, for the report
    failures = 0
    for rec in records
        warnings = String[]
        logger = CollectLogger(warnings, Logging.current_logger())
        try
            r = Logging.with_logger(logger) do
                process_day(rec; force=force, echo=false, allow_genesis=allowGenesis)
            end
            push!(outcomes, r)
            push!(results, (date=string(r.date), ok=true, closed=r.closed,
                            journal=r.journal, dailyLedger=r.daily_ledger,
                            monthlyLedger=r.monthly_ledger, daysInMonth=r.days_in_month,
                            dayVariance=r.day_variance, overnightVariance=r.overnight_variance,
                            reason=r.reason, released=[string(d) for d in r.released],
                            outputDir=r.output_dir, warnings=warnings))
        catch e
            failures += 1
            push!(results, (date=string(rec.date), ok=false,
                            closed=false, journal="failed", dailyLedger="failed",
                            monthlyLedger="failed", daysInMonth=0,
                            dayVariance=0.0, overnightVariance=0.0, reason="",
                            released=String[],
                            outputDir="", warnings=[sprint(showerror, e)]))
        end
    end

    failures == 0 && Staging.clear_staged!()

    # v4.0: the report is written on EVERY commit, not only when something went
    # wrong. Silence is ambiguous — a report saying "entered, balanced" also
    # proves the program ran, which an absent report cannot.
    reportPath = ""
    try
        isempty(outcomes) || (reportPath = Report.write_report(outcomes))
    catch e
        @warn "Report could not be written" exception=e
    end

    return json(200, (ok = failures == 0, results = results,
                      cleared = failures == 0, failures = failures,
                      report = reportPath,
                      pending = [string(d) for d in
                                 Chain.pending_ledgers(year(Dates.today()), month(Dates.today()))],
                      root = Layout.ROOT))
end

# ---------------------------------------------------------------------------
# Routing
# ---------------------------------------------------------------------------
# Routing is written out by hand rather than using HTTP.Router so that this file
# does not depend on which version of HTTP.jl happens to be installed.
function router(req::HTTP.Request)
    uri = HTTP.URI(req.target)
    path = uri.path
    m = req.method

    try
        if m == "GET" && (path == "/" || path == "/index.html")
            return serve_static("index.html")
        elseif m == "GET" && path == "/api/config"
            return handle_config()
        elseif m == "GET" && path == "/api/staged"
            return handle_staged()
        elseif m == "POST" && path == "/api/staged"
            return handle_stage(req)
        elseif m == "DELETE" && path == "/api/staged"
            return handle_unstage(uri)
        elseif m == "GET" && path == "/api/prior"
            return handle_prior(uri)
        elseif m == "POST" && path == "/api/check"
            return handle_check(req)
        elseif m == "POST" && path == "/api/commit"
            return handle_commit(req)
        elseif m == "GET"
            return serve_static(path)
        else
            return HTTP.Response(405, "Method not allowed")
        end
    catch e
        # An unhandled error must not take the server down mid-session; report it
        # and keep listening.
        @error "Unhandled error" exception=(e, catch_backtrace())
        return fail(500, "Something went wrong on the server. Check the terminal window.")
    end
end

# ---------------------------------------------------------------------------
function start()
    mkpath(Layout.ROOT)
    n = Staging.staged_count()
    println()
    println("  Bookkeeping entry form")
    println("  ----------------------")
    println("  Records folder : $(Layout.ROOT)")
    println("  Staged days    : $n" * (n > 0 ? "  (a previous session is waiting to be finished)" : ""))
    println()
    println("  Open this in your browser:  http://127.0.0.1:$PORT")
    println("  Press Ctrl+C in this window to stop.")
    println()
    flush(stdout)          # so the address above appears immediately, not when buffered
    HTTP.serve(router, "127.0.0.1", PORT)
end

if abspath(PROGRAM_FILE) == @__FILE__
    start()
end
