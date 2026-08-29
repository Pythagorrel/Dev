# =============================================================================
# test_endtoend_edge.jl — multi-day / chain-level edge cases not covered by
# test_endtoend.jl. Uses its own fresh chain (own genesis), so run with a
# DIFFERENT LEDGER_ROOT than the original suite.
#
# Run:  LEDGER_ROOT=/tmp/ldgr_test_edge julia test_endtoend_edge.jl
#
# Writes to LEDGER_ROOT only. Never point this at the real Records folder.
# =============================================================================

using Dates
include("main.jl")

rm(Layout.ROOT; recursive=true, force=true)

const PASS = Ref(0); const FAIL = Ref(0)

function ok(label, cond)
    cond ? (PASS[] += 1; println("  PASS  $label")) : (FAIL[] += 1; println("  FAIL  $label"))
end

function blocks(label, frag, f)
    try
        f(); ok(label, false)
    catch e
        msg = sprint(showerror, e)
        ok(label * "  [blocked: $(occursin(frag, msg) ? "correct reason" : "WRONG reason")]",
           occursin(frag, msg))
    end
end

function day(d; o=1270.0, s=98400.0, e=22400.0, dep=75000.0, b=0.0, c=2270.0, reason="")
    a = blank_amounts()
    a[:opening_balance] = o; a[:closing_balance] = c
    a[:cash_sales] = s; a[:doctor_fees] = e; a[:deposits] = dep; a[:Mr_Boyle] = b
    DayRecord(d, a, STATUS_TRADING, reason)
end

println("\n", repeat("=", 70), "\n  LDGR v4.0 END-TO-END — EDGE CASES\n  ROOT: $(Layout.ROOT)\n", repeat("=", 70))

# ---------------------------------------------------------------- GENESIS + IMMEDIATE GAP
println("\nGenesis followed immediately by a gap")
g1 = process_day(day(Date(2025,12,30); o=1670.0, s=174600.0, e=49000.0, dep=126000.0, c=1270.0);
                  echo=false, allow_genesis=true)
ok("genesis accepted", g1.ok && g1.daily_ledger == "written")

# 2025-12-31 is deliberately skipped. Opening (1720) deliberately does NOT
# match what the eventual prior closing (1270, via the closed day below) will
# be — a real +450 overnight movement that isn't knowable yet.
g2 = process_day(day(Date(2026,1,1); o=1720.0, c=1720.0, dep=98400.0, e=0.0); echo=false)
ok("day right after a genesis-adjacent gap is HELD", g2.daily_ledger == "held")

# ---------------------------------------------------------------- CLOSED DAY RIGHT AFTER GENESIS
println("\nClosed day filling the gap (also: closed day right after genesis-adjacent span)")
g3 = process_day(closed_day(Date(2025,12,31), 1270.0); echo=false)
ok("closed day accepted with no ledger", g3.daily_ledger == "not applicable (closed)")
ok("filling the gap with a closed day releases the held day", Date(2026,1,1) in g3.released)
# EXPECTED once fixed: overnight variance should recompute to +450 now that the
# real prior closing (1270) is known. Documents current (suspected buggy) behaviour.
println("  overnight variance on release: $(g2.overnight_variance) (real movement is +450.00 — investigate if this shows 0.00)")

# ---------------------------------------------------------------- MULTIPLE CLOSED DAYS ACROSS A MONTH BOUNDARY
println("\nMultiple closed days spanning a month boundary")
process_day(day(Date(2026,1,30); o=1270.0, c=1270.0, dep=98400.0, e=0.0); echo=false)
c1 = process_day(closed_day(Date(2026,1,31), 1270.0); echo=false)
c2 = process_day(closed_day(Date(2026,2,1), 1270.0); echo=false)
ok("first closed day (month-end) generates no ledger", c1.daily_ledger == "not applicable (closed)")
ok("second closed day (month-start) generates no ledger", c2.daily_ledger == "not applicable (closed)")

# ---------------------------------------------------------------- CLOSED DAY RIGHT BEFORE A GAP
println("\nClosed day immediately before a gap")
# 2026-02-02 is deliberately skipped — it comes right after the closed 2026-02-01.
h1 = process_day(day(Date(2026,2,3); o=1270.0, c=1270.0, dep=98400.0, e=0.0); echo=false)
ok("day after a gap that starts right after a closed day is HELD", h1.daily_ledger == "held")

h2 = process_day(day(Date(2026,2,2); o=1270.0, c=1270.0, dep=98400.0, e=0.0); echo=false)
ok("filling the gap releases the held day", Date(2026,2,3) in h2.released)
ok("balance carried through the closed days is still correct",
   abs(h2.overnight_variance) < 0.005)

# ---------------------------------------------------------------- LEAP YEAR
println("\nLeap year (2024) boundary")
# Fresh dates a chain has never seen before will always HELD on the immediate
# prior day being missing — that's expected gate behaviour, not a leap-year bug.
process_day(day(Date(2024,2,28); o=1270.0, c=1270.0, dep=98400.0, e=0.0); echo=false, allow_genesis=true)
lp = process_day(day(Date(2024,2,29); o=1270.0, c=1270.0, dep=98400.0, e=0.0); echo=false)
ok("Feb 29 posts normally with a real prior day", lp.daily_ledger == "written")
mar = process_day(day(Date(2024,3,1); o=1270.0, c=1270.0, dep=98400.0, e=0.0); echo=false)
ok("Mar 1 finds Feb 29 across the leap-year month boundary", mar.daily_ledger == "written")
ok("no false overnight variance across the leap day", abs(mar.overnight_variance) < 0.005)

# ---------------------------------------------------------------- RE-ENTERING A DAY TWICE
println("\nRe-entering the same day twice with --force")
f1 = process_day(day(Date(2024,3,1); o=1270.0, c=1270.0, dep=98400.0, e=0.0); echo=false, force=true)
f2 = process_day(day(Date(2024,3,1); o=1270.0, c=1270.0, dep=98400.0, e=0.0); echo=false, force=true)
ok("first --force overwrites", f1.daily_ledger == "overwritten")
ok("second consecutive --force also overwrites (idempotent, no crash)", f2.daily_ledger == "overwritten")

# ---------------------------------------------------------------- RE-ENTERING A DAY AS A DIFFERENT STATUS
# Exploratory: the Guide doesn't define expected behaviour here. Printing the
# actual outcome for manual review rather than asserting pass/fail.
println("\nRe-entering a day as a different status (no defined expected behaviour — inspect manually)")
try
    swapped = process_day(closed_day(Date(2024,3,1), 1270.0); echo=false, force=true)
    println("  trading -> closed on re-entry: daily_ledger=$(swapped.daily_ledger)")
catch e
    println("  trading -> closed on re-entry: THREW — $(sprint(showerror, e))")
end
try
    swapped2 = process_day(day(Date(2025,12,31); o=1270.0, c=1270.0, dep=98400.0, e=0.0); echo=false, force=true)
    println("  closed -> trading on re-entry: daily_ledger=$(swapped2.daily_ledger)")
catch e
    println("  closed -> trading on re-entry: THREW — $(sprint(showerror, e))")
end

println("\n", repeat("=", 70))
println("  PASSED $(PASS[])   FAILED $(FAIL[])")
println(repeat("=", 70))
exit(FAIL[] == 0 ? 0 : 1)
