module AuditLog

using Dates

export log_entry

function log_entry(filepath::String="audit_log.txt")
    username = get(ENV, "USERNAME", get(ENV, "USER", "unknown"))
    timestamp = Dates.format(now(), "yyyy-mm-dd HH:MM:SS")
    open(filepath, "a") do io
        println(io, "$(timestamp) — $(username)")
    end
end

end # module