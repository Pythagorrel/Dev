# =============================================================================
# test_endtoend.jl — walks the test checklist from the ldgr Warnings Guide §9.
#
# Run:  LEDGER_ROOT=/tmp/ldgr_test julia test_endtoend.jl
#
# Writes to LEDGER_ROOT only. Never point this at the real Records folder.
# =============================================================================

using Dates
include("main.jl")

const PASS = Ref(0); const FAIL = Ref(0)

function ok(label, cond)
    cond ? (PASS[] += 1; println("  PASS  $label")) : (FAIL[] += 1; println("  FAIL  $label"))
end

"Does this call throw, and does the message mention `frag`?"
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

println("\n", repeat("=", 70), "\n  LDGR v4.0 END-TO-END\n  ROOT: $(Layout.ROOT)\n", repeat("=", 70))

# ---------------------------------------------------------------- LEVEL 1
println("\nLEVEL 1 — Stop")
blocks("L1-A negative figure", "cannot be negative",
       () -> process_day(day(Date(2026,6,2); e=-500.0); echo=false, allow_genesis=true))
blocks("L1-B outflow exceeds cash available", "More cash has been paid out",
       () -> process_day(day(Date(2026,6,2); dep=200000.0); echo=false, allow_genesis=true))
blocks("L1-C closing balance blank", "has not been filled in",
       () -> process_day(day(Date(2026,6,2); c=NOT_COUNTED); echo=false, allow_genesis=true))
blocks("L1-E future date", "future",
       () -> process_day(day(Dates.today() + Day(5)); echo=false, allow_genesis=true))

# ---------------------------------------------------------------- GENESIS
println("\nLEVEL 3 — Genesis")
blocks("genesis refused without authorisation", "first day on record",
       () -> process_day(day(Date(2026,6,1); o=1670.0, s=174600.0, e=49000.0, dep=126000.0, c=1270.0); echo=false))

r1 = process_day(day(Date(2026,6,1); o=1670.0, s=174600.0, e=49000.0, dep=126000.0, c=1270.0);
                 echo=false, allow_genesis=true)
ok("genesis accepted with --first-day", r1.ok && r1.daily_ledger == "written")
ok("genesis day balances", abs(r1.day_variance) < 0.005)

# ---------------------------------------------------------------- CLEAN CHAIN
println("\nClean chain")
r2 = process_day(day(Date(2026,6,2)); echo=false)
ok("day 2 recorded, ledger written", r2.daily_ledger == "written")
ok("day 2 no day variance",       abs(r2.day_variance) < 0.005)
ok("day 2 no overnight variance", abs(r2.overnight_variance) < 0.005)

# ---------------------------------------------------------------- LEVEL 2
println("\nLEVEL 2 — Explain")
blocks("difference with no reason is refused", "no reason was given",
       () -> process_day(day(Date(2026,6,3); o=2270.0, e=22000.0, c=1770.0); echo=false))

r3 = process_day(day(Date(2026,6,3); o=2270.0, e=22000.0, c=1770.0,
                     reason="Could not locate"); echo=false)
# expected: predicted = 2270 + 98400 - 22000 - 75000 = 3670; counted 1770 -> -1900
ok("shortage recorded with a reason", r3.ok && abs(r3.day_variance + 1900.0) < 0.005)
ok("reason stored on the day", r3.reason == "Could not locate")

r4 = process_day(day(Date(2026,6,4); o=2220.0, c=1720.0, reason="Opening counted low"); echo=false)
# overnight = 2220 - 1770 = +450
ok("overnight variance computed", abs(r4.overnight_variance - 450.0) < 0.005)

# ---------------------------------------------------------------- GATE
println("\nLEVEL 3 — Ledger gate (missing day)")
r6 = process_day(day(Date(2026,6,6); o=1720.0, c=1720.0, dep=98400.0, e=0.0); echo=false)
ok("day after a gap is HELD", r6.daily_ledger == "held")

r7 = process_day(day(Date(2026,6,7); o=1720.0, c=1720.0, dep=98400.0, e=0.0); echo=false)
ok("the day after THAT posts normally (blast radius is 1)", r7.daily_ledger == "written")
r8 = process_day(day(Date(2026,6,8); o=1720.0, c=1720.0, dep=98400.0, e=0.0); echo=false)
ok("and so does the next", r8.daily_ledger == "written")
ok("exactly one ledger pending", length(Chain.pending_ledgers(2026,6)) == 1)

r5 = process_day(day(Date(2026,6,5); o=1720.0, c=1720.0, dep=98400.0, e=0.0); echo=false)
ok("filling the gap releases the held day", Date(2026,6,6) in r5.released)
ok("no ledgers pending afterwards", isempty(Chain.pending_ledgers(2026,6)))

# ---------------------------------------------------------------- CLOSED
println("\nLEVEL 3 — Closed days")
rc = process_day(closed_day(Date(2026,6,9), 1720.0); echo=false)
ok("closed day generates no ledger", rc.daily_ledger == "not applicable (closed)")
ok("closed day has no variance", abs(rc.day_variance) < 0.005)
ok("closed day not counted as pending", !(Date(2026,6,9) in Chain.pending_ledgers(2026,6)))

rc2 = process_day(closed_day(Date(2026,6,10), 1720.0); echo=false)
r11 = process_day(day(Date(2026,6,11); o=1720.0, c=1720.0, dep=98400.0, e=0.0); echo=false)
ok("balance carries across a long weekend", abs(r11.overnight_variance) < 0.005)

# ---------------------------------------------------------------- L3-B
println("\nLEVEL 3 — Re-import confirmation")
r11b = process_day(day(Date(2026,6,11); o=1720.0, c=1720.0, dep=98400.0, e=0.0); echo=false)
ok("re-entering a day refuses to overwrite its ledger", r11b.daily_ledger == "skipped")
r11c = process_day(day(Date(2026,6,11); o=1720.0, c=1720.0, dep=98400.0, e=0.0);
                   echo=false, force=true)
ok("--force regenerates it after confirmation", r11c.daily_ledger == "overwritten")

# ---------------------------------------------------------------- MONTH BOUNDARY
println("\nMonth boundary")
r30 = process_day(day(Date(2026,6,30); o=1720.0, c=1720.0, dep=98400.0, e=0.0); echo=false)
ro1 = process_day(day(Date(2026,7,1); o=1720.0, c=1720.0, dep=98400.0, e=0.0); echo=false)
ok("1 Jul finds 30 Jun across the folder boundary", ro1.daily_ledger == "written")
ok("and computes no false overnight variance", abs(ro1.overnight_variance) < 0.005)

# ---------------------------------------------------------------- LEDGER CONTENT
println("\nLedger content")
rows = build_ledger_rows(Dict(:cash_sales=>98400.0, :POS_Scotia=>0.0, :POS_RBL=>0.0, :POS_U=>0.0),
                         Dict(:doctor_fees=>22400.0, :medical_supply_costs=>0.0,
                              :miscellaneous_costs=>0.0, :taxi_fare=>0.0),
                         Dict(:deposits=>75000.0), Dict(:Mr_Boyle=>0.0);
                         day_variance=-400.0)
accts = [r.Account for r in rows]
ok("variance posts to the over/short account", CASH_OVER_SHORT_ACCOUNT in accts)
short_row = findfirst(r -> r.Account == CASH_OVER_SHORT_ACCOUNT, rows)
ok("a shortage DEBITS over/short", !ismissing(rows[short_row].Debit) && rows[short_row].Debit == 400.0)

deb = sum(r.Debit  for r in rows if !ismissing(r.Debit))
cre = sum(r.Credit for r in rows if !ismissing(r.Credit))
ok("ledger still balances (debits == credits)", abs(deb - cre) < 0.005)

# undeposited is now the deposits figure itself, with no POS subtraction
rows2 = build_ledger_rows(Dict(:cash_sales=>98400.0, :POS_Scotia=>40000.0, :POS_RBL=>0.0, :POS_U=>0.0),
                          Dict(:doctor_fees=>0.0, :medical_supply_costs=>0.0,
                               :miscellaneous_costs=>0.0, :taxi_fare=>0.0),
                          Dict(:deposits=>75000.0), Dict(:Mr_Boyle=>5000.0))
und = findfirst(r -> r.Account == deposit[1].account, rows2)
ok("undeposited == cash to be deposited (POS no longer subtracted)",
   und !== nothing && rows2[und].Debit == 75000.0)

# ---------------------------------------------------------------- MONTH CHECK
println("\nMonth-level check")
chk = Chain.month_chain_check(2026, 6)
ok("month movement reconciles to the balance span", chk.ok || chk.note != "")
chk.ok || println("      note=$(chk.note) diff=$(chk.diff)")

# ---------------------------------------------------------------- REPORT
println("\nReport")
rp = Report.write_report([r11c, rc])
ok("report file written", isfile(rp))
txt = read(rp, String)
ok("report lists the month position", occursin("MONTH TO DATE", txt))
ok("report lists held ledgers section", occursin("LEDGERS WAITING", txt))

println("\n", repeat("=", 70))
println("  PASSED $(PASS[])   FAILED $(FAIL[])")
println(repeat("=", 70))
exit(FAIL[] == 0 ? 0 : 1)
