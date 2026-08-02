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

    # Date range. Future days cannot have happened yet; anything before 2000 is
    # a typo rather than a record.
    d > Dates.today() && throw(ArgumentError("$(d) is in the future."))
    year(d) < 2000 && throw(ArgumentError("$(d) is too far in the past to be a real entry."))

    amounts = DayInput.blank_amounts()               # every category starts at zero
    raw = get(body, :amounts, nothing)
    if raw !== nothing
        valid = Set(String(colname_of(k)) for k in KEY_ORDER)
        for (name, value) in pairs(raw)
            key = String(name)
            key in valid || throw(ArgumentError("Unknown category \"$key\"."))
            v = value === nothing ? 0.0 : (value isa Number ? Float64(value) :
                                           something(tryparse(Float64, strip(String(value))), NaN))
            isnan(v) && throw(ArgumentError("\"$(label_of(Symbol(key)))\" is not a number."))
            v < 0 && throw(ArgumentError("\"$(label_of(Symbol(key)))\" cannot be negative."))
            amounts[Symbol(key)] = v
        end
    end

    return DayRecord(d, amounts)
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
        ],
        keyOrder = [String(k) for k in KEY_ORDER],
        # Sent so the running total on the entry screen can show the banked figure
        # without the browser having to know that a category called "deposits"
        # exists. The front end holds no category names of its own.
        depositKey = String(deposit[1].key),
        labels = Dict(String(k) => label_of(k) for k in KEY_ORDER),
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
        (date = string(rec.date),
         amounts = Dict(String(colname_of(k)) => rec.amounts[k] for k in KEY_ORDER),
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

    count, replaced = Staging.stage_day!(rec)
    return json(200, (ok=true, date=string(rec.date), replaced=replaced, staged=count))
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
    force = get(body, :force, false) === true

    records = Staging.staged_records()
    isempty(records) && return fail(400, "There is nothing to save yet.")

    results = []
    failures = 0
    for rec in records
        warnings = String[]
        logger = CollectLogger(warnings, Logging.current_logger())
        try
            r = Logging.with_logger(logger) do
                process_day(rec; force=force, echo=false)
            end
            push!(results, (date=string(r.date), ok=true,
                            journal=r.journal, dailyLedger=r.daily_ledger,
                            monthlyLedger=r.monthly_ledger, daysInMonth=r.days_in_month,
                            outputDir=r.output_dir, warnings=warnings))
        catch e
            failures += 1
            push!(results, (date=string(rec.date), ok=false,
                            journal="failed", dailyLedger="failed",
                            monthlyLedger="failed", daysInMonth=0,
                            outputDir="", warnings=[sprint(showerror, e)]))
        end
    end

    failures == 0 && Staging.clear_staged!()

    return json(200, (ok = failures == 0, results = results,
                      cleared = failures == 0, failures = failures,
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
