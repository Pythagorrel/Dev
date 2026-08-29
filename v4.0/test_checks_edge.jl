using Dates
include("Config.jl");   using .Config
include("getdate.jl");  using .getdate
include("DayInput.jl"); using .DayInput
include("Checks.jl");   using .Checks

function mk(; d=Date(2026,8,20), o=1270.0, s=98400.0, e=22400.0, taxi=0.0, dep=75000.0, b=0.0, c=2270.0, st=STATUS_TRADING)
    a = blank_amounts()
    a[:opening_balance]=o; a[:closing_balance]=c
    a[:cash_sales]=s; a[:doctor_fees]=e; a[:taxi_fare]=taxi; a[:deposits]=dep; a[:Mr_Boyle]=b
    DayRecord(d, a, st, "")
end

show1(t, fs) = (println("\n--- $t"); for f in fs; println("  [$(f.code)] $(level_name(f.level)): $(f.message)"); end; isempty(fs) && println("  (clean)"))

# --- L1-D: not yet covered anywhere in the existing suite -------------------
show1("bad format: journal key 3dp",       check_day(mk(e=22400.505); prior_closing=1270.0))
show1("bad format: cash-book key 3dp",     check_day(mk(c=2270.505); prior_closing=1270.0))
show1("bad format: NaN in journal key",    check_day(begin r=mk(); a=copy(r.amounts); a[:taxi_fare]=NaN; DayRecord(r.date,a) end; prior_closing=1270.0))

# --- L1 Stop co-occurring with L3-A / L3-D (regression case) ---------------
# Current behaviour: L3-A/L3-D fire even when a Stop already blocks the day,
# producing "the day itself is saved" text next to a STOP that prevents saving.
show1("Stop + no-prior-day notice",        check_day(mk(e=-5.0)))              # expect: L1-A only, once fixed
show1("Stop + genesis notice",             check_day(mk(e=-5.0); is_genesis=true))  # expect: L1-A only, once fixed

# --- Two Stops firing at once ------------------------------------------------
show1("two stops: negative + future date", check_day(mk(e=-5.0, d=Date(2027,1,1))))

# --- Two hints matching the same difference ---------------------------------
# taxi=450 makes the surplus both divisible by 9 AND equal to an entered figure.
show1("two hints on one difference",       check_day(mk(taxi=450.0, c=2270.0); prior_closing=1270.0))

# --- MONEY_TOL rounding boundary (tol = 0.005) -------------------------------
show1("just under tolerance (clean)",      check_day(mk(c=2270.0049); prior_closing=1270.0))
show1("right at tolerance (flags)",        check_day(mk(c=2270.005); prior_closing=1270.0))

# --- All-zero day -------------------------------------------------------------
show1("all-zero day",                      check_day(mk(o=0.0, s=0.0, e=0.0, dep=0.0, c=0.0); prior_closing=0.0))

# --- Very large figures --------------------------------------------------------
show1("very large figures",                check_day(mk(o=1_000_000.0, s=5_000_000.0, e=100_000.0, dep=4_500_000.0, c=1_400_000.0); prior_closing=1_000_000.0))

# --- Closed day immediately after genesis -------------------------------------
show1("closed day right after genesis",    check_day(mk(st=STATUS_CLOSED); is_genesis=true))
