using Dates
include("Config.jl"); using .Config
include("getdate.jl"); using .getdate
include("DayInput.jl"); using .DayInput
include("Checks.jl"); using .Checks
function mk(; o=1270.0,s=98400.0,e=22400.0,taxi=0.0,dep=75000.0,c=2270.0)
    a=blank_amounts(); a[:opening_balance]=o; a[:closing_balance]=c
    a[:cash_sales]=s; a[:doctor_fees]=e; a[:taxi_fare]=taxi; a[:deposits]=dep
    DayRecord(Date(2026,8,20), a)
end
show1(t,fs)=(println("\n--- $t"); for f in fs; println("  [$(f.code)] $(f.message)"); end)
# taxi fare 400 present, doctor fees short by 400 -> difference should point at taxi fare
show1("diff equals an entered figure", check_day(mk(e=22000.0,taxi=400.0,c=1870.0); prior_closing=1270.0))
# decimal slip: deposit 7500 instead of 75000
show1("decimal slip on deposit", check_day(mk(dep=7500.0,c=2270.0); prior_closing=1270.0))
show1("formatting", check_day(mk(dep=200000.0)))
