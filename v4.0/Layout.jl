module Layout

using Dates

# =============================================================================
# LAYOUT — every folder path and filename in the system is built here.
#
# ENTIRELY NEW FILE. v2.1.1 built its paths inline in the driver:
#     ledger_dir = "$(y)_ledgers"; daily_dir = "$(y)_daily_records"
#     mkpath(ledger_dir); mkpath(daily_dir)
# Those two lines are superseded by this module. Nothing outside this file is
# permitted to construct a path — that is what makes the folder rules
# changeable in one place.
#
# TWO CORRECTIONS TO THE SPEC AS WRITTEN:
#   1. "m/year" cannot be a filename — `/` is the path separator on every OS.
#      Folders nest as <ROOT>/<year>/<mm>/ and filenames use `-` as the
#      separator instead.
#   2. Months and days are zero-padded and dates are written year-first, so
#      that alphabetical sorting in a file browser equals chronological order.
#      "09-2026" sorts before "10-2026"; "9-2026" would not.
# =============================================================================

export ROOT, month_tag, iso_tag,
       year_dir, month_dir, journal_path, monthly_ledger_path,
       daily_ledger_dir, daily_ledger_path,
       ensure_month_dir, ensure_daily_ledger_dir

# NEW. v2.1.1 wrote relative to `pwd()`, which is whatever directory the
# program happened to be launched from — so double-clicking it vs. running it
# from a terminal scattered files in two different places. ROOT is now an
# absolute path anchored to the source folder, overridable by an environment
# variable for testing or for pointing at a shared drive.
#   @__DIR__  — the directory containing this source file.
#   get(ENV, k, default) — returns ENV[k] if the variable is set, else default.
const ROOT = get(ENV, "LEDGER_ROOT", joinpath(@__DIR__, "Records"))

# --- Name fragments --------------------------------------------------------
# lpad(9, 2, '0') => "09". Applied to months and days everywhere.
pad2(n::Integer) = lpad(n, 2, '0')

"Month stamp used in month-scoped filenames, e.g. 09-2026."
month_tag(y::Integer, m::Integer) = "$(pad2(m))-$(y)"

"Date stamp used in day-scoped filenames, e.g. 2026-09-14. Year-first so it sorts."
iso_tag(d::Date) = "$(year(d))-$(pad2(month(d)))-$(pad2(day(d)))"

# --- Directories -----------------------------------------------------------
year_dir(y::Integer)  = joinpath(ROOT, string(y))
month_dir(y, m)       = joinpath(year_dir(y), pad2(m))

"Folder holding the per-day ledgers for one month."
daily_ledger_dir(y, m) = joinpath(month_dir(y, m), "Daily Ledgers $(month_tag(y, m))")

# --- Files -----------------------------------------------------------------
"The month's Daily Journal — the single source of truth for that month."
journal_path(y, m) = joinpath(month_dir(y, m), "Daily Journal $(month_tag(y, m)).csv")

"The month's ledger. Derived from the journal; safe to overwrite on every run."
monthly_ledger_path(y, m) = joinpath(month_dir(y, m), "Monthly Ledger $(month_tag(y, m)).csv")

"One day's ledger."
daily_ledger_path(d::Date) =
    joinpath(daily_ledger_dir(year(d), month(d)), "Daily Ledger $(iso_tag(d)).csv")

# --- Creation --------------------------------------------------------------
# Each ensure_* returns (path, created) where `created` is true only if the
# folder did not already exist. The driver uses that flag to report what it
# had to build, which is the "checks whether a folder exists; if not,
# generates it" requirement.
#
# mkpath (unlike mkdir) creates every missing parent level in one call and is
# a no-op if the directory already exists — so <year>/ and <year>/<mm>/ are
# both handled by the single call below.

function ensure_month_dir(y, m)
    p = month_dir(y, m)
    created = !isdir(p)
    mkpath(p)
    return (p, created)
end

function ensure_daily_ledger_dir(y, m)
    p = daily_ledger_dir(y, m)
    created = !isdir(p)
    mkpath(p)
    return (p, created)
end

end # module Layout
