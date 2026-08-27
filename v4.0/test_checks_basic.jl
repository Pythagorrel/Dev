using Dates
include("Config.jl");   using .Config
include("getdate.jl");  using .getdate
include("DayInput.jl"); using .DayInput
include("Checks.jl");   using .Checks

function mk(; d=Date(2026,8,20), o=1270.0, s=98400.0, e=22400.0, dep=75000.0, b=0.0, c=2270.0, st=STATUS_TRADING)
    a = blank_amounts()
    a[:opening_balance]=o; a[:closing_balance]=c
    a[:cash_sales]=s; a[:doctor_fees]=e; a[:deposits]=dep; a[:Mr_Boyle]=b
    DayRecord(d, a, st, "")
end

show1(t, fs) = (println("\n--- $t"); for f in fs; println("  [$(f.code)] $(level_name(f.level)): $(f.message)"); end; isempty(fs) && println("  (clean)"))

show1("correct day", check_day(mk(); prior_closing=1270.0))
show1("negative field", check_day(mk(e=-5.0)))
show1("overspend", check_day(mk(dep=200000.0)))
show1("blank closing", check_day(begin r=mk(); a=copy(r.amounts); a[:closing_balance]=NOT_COUNTED; DayRecord(r.date,a) end))
show1("expense 22000 not 22400 (short 400)", check_day(mk(e=22000.0); prior_closing=1270.0))
show1("closing 2720 not 2270 (surplus 450, /9)", check_day(mk(c=2720.0); prior_closing=1270.0))
show1("overnight gap 450", check_day(mk(o=1720.0,c=2720.0); prior_closing=1270.0))
show1("expense omitted (0 not 22400)", check_day(mk(e=0.0); prior_closing=1270.0))
show1("no prior day", check_day(mk()))
show1("genesis", check_day(mk(); is_genesis=true))
show1("closed day", check_day(mk(st=STATUS_CLOSED); prior_closing=1270.0))
