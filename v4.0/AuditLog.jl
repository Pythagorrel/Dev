module AuditLog

using Dates

# =============================================================================
# AUDITLOG — who ran what, when, and what it touched.
#
# v2.1.1's version wrote a bare "timestamp — username" line, once, at the very
# end of the run. It recorded that *something* happened but not what, which is
# no use for the question that actually gets asked in a two-person bookkeeping
# setup: "who entered the wrong figure on the 14th?"
#
# It matters more now than it did before, because the HTML form removes the
# operator from the terminal entirely. There is nobody present to read a
# println, so the log is where "a file already existed and was left alone" or
# "a previously-entered day was overwritten" has to be recorded.
#
# The original single-argument log_entry(filepath) signature is preserved so
# nothing that called it the old way breaks.
# =============================================================================

export log_entry, log_event, AuditSession

"Original v2.1.1 behaviour: one timestamp/user line. Kept for compatibility."
function log_entry(filepath::String="audit_log.txt")
    username = get(ENV, "USERNAME", get(ENV, "USER", "unknown"))
    timestamp = Dates.format(now(), "yyyy-mm-dd HH:MM:SS")
    open(filepath, "a") do io
        println(io, "$(timestamp) — $(username)")
    end
end

"""
    AuditSession(filepath)

NEW. Collects events over a run so the whole run lands in the log as one
indented block, rather than as scattered lines that interleave badly when two
people run the program at nearly the same time.
"""
mutable struct AuditSession
    filepath::String
    events::Vector{String}
end
AuditSession(filepath::String="audit_log.txt") = AuditSession(filepath, String[])

"Record one thing that happened. Also echoed to the console for interactive runs."
function log_event(session::AuditSession, msg::AbstractString; echo::Bool=true)
    push!(session.events, msg)
    echo && println("  • ", msg)
    return session
end

"""
    log_entry(session; header)

Flushes the session to disk. `open(...) do io ... end` opens in append mode and
closes the handle even if writing throws.
"""
function log_entry(session::AuditSession; header::AbstractString="")
    username = get(ENV, "USERNAME", get(ENV, "USER", "unknown"))
    timestamp = Dates.format(now(), "yyyy-mm-dd HH:MM:SS")
    open(session.filepath, "a") do io
        println(io, "$(timestamp) — $(username)$(isempty(header) ? "" : " — " * header)")
        for e in session.events
            println(io, "    $e")
        end
    end
    return session
end

end # module AuditLog
