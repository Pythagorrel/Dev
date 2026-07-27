using DataFrames, CSV, Dates

abstract type ledger_fields end

mutable struct totals <: ledger_fields
    cash_sales::Float64
    expenses::Float64
    deposits::Float64
    function totals()
        new(0.0,0.0,0.0)
    end
end

mutable struct costs <: ledger_fields  #keep in mind adding new costs would require redefining function; use helper functions wisely
    doctor_fees::Float64
    pharmacy_supply_costs::Float64
    function costs()
        new(0.0,0.0)
    end
end

function get_date()
    year = ""; month ="";
     println("Please enter the year corresponding to the current balance sheet.")
     year = readline()
     println("Please enter the number (1-12) of the month corresponding to the current balance sheet.")
     month = readline()
     return month, year
end
    m,y = get_date()

    println("Please enter the number of work days for $(m)/$(y).")
    n_work_days = parse(Float64, readline())

#--------------------------------------------Monthly total calculation section--------------------------------------------

function csv1(n)
    daily_values = Dict{String,Vector{Float64}}(
        "Doctor's Fees" => Float64[],
        "Pharmacy Supplies" => Float64[],
        "Cash Received" => Float64[],
        "Deposits" => Float64[]
    )
    monthly_total = totals()
    monthly_costs = costs() #sum of each individual type of cost per month
    g=0

    date = Int[]  # FIXED: was untyped `[]` — indexed assignment below (date[day_no] = ...) would BoundsError on day 1 since an empty array has no index 1 to assign into

    while g < n

        day_no = g+1

         push!(daily_values["Cash Received"],0.0)
         push!(daily_values["Doctor's Fees"],0.0)
         push!(daily_values["Pharmacy Supplies"],0.0)
         push!(daily_values["Deposits"],0.0)
         push!(date, 0)  # FIXED: added placeholder push so date[day_no] below has an index to overwrite, matching the pattern used for the other daily fields
         # NOTE: kept as a single push! per category per day (one 0.0 placeholder), as intended for
         # keeping all four vectors the same length for Tables.jl. The bug was downstream, where the
         # real value used to get push!'d again on top instead of overwriting this placeholder.

        println("Please enter the date [number from 1-31] of this balance sheet.")
        date[day_no] = parse(Int,readline())

        println("Please enter the Cash Sales (Received) for day $(day_no).")

        daily_values["Cash Received"][day_no] = parse(Float64,readline())
        monthly_total.cash_sales += daily_values["Cash Received"][day_no] #rolling total for total monthly cash sales

        pending = true

        while pending

        println("Are there any expenses for day $(day_no)?
        \nEnter 1 for yes and 2 for no")

        c1 = readline() #choice 1 on whether expenses were present or not

        if c1=="1" #if there are expenses for the day, the program assigns the value to its corresponding purpose

            pending_1 = true

            while pending_1

            println("Please enter the corresponding number to classify the type of expense.\n1. Doctor's Fees\n2. Pharmacy Supplies")

            c2 = readline() #choice 2 on what type of expense it was

            if c2 == "1" #Doctor's Fees

                println("You selected Doctor's Fees.
                \nPlease enter the total for the day.")
                daily_values["Doctor's Fees"][day_no] = parse(Float64,readline())
                monthly_costs.doctor_fees += daily_values["Doctor's Fees"][day_no]

                println("Is this the only type of expense for this day? Enter 1 or 2:
                \n1. Yes, proceed to next section.
                \n2. No, there are other expenses.")

                c3 = readline() #choice 3 on whether there was 1 or multiple expenses for the day
                if c3 == "1"
                    println("Proceeding to next section. Please Press Enter...")
                    readline()
                    pending_1 = false
                    pending = false
                elseif c3 == "2"
                    println("Returning to menu...\n")
                else
                    println("Invalid input, returning to menu.")
                end  # FIXED: missing end for this inner if c3==... block

            elseif c2 == "2" #Pharmacy Supplies

                println("You selected Pharmacy Supplies.
                \nPlease enter the total for the day.")
                daily_values["Pharmacy Supplies"][day_no] = parse(Float64,readline())
                monthly_costs.pharmacy_supply_costs += daily_values["Pharmacy Supplies"][day_no]

                println("Is this the only type of expense for this day? Enter 1 or 2:
                \n1. Yes, proceed to next section.
                \n2. No, there are other expenses.")

                c3 = readline() #choice 3 on whether there was 1 or multiple expenses for the day
                if c3 == "1"
                    println("Proceeding to next section. Please Press Enter...")
                    readline()
                    pending_1 = false
                    pending = false
                elseif c3 == "2"
                    println("Returning to menu...\n")
                else
                    println("Invalid input, returning to menu.")
                end  # FIXED: missing end for this inner if c3==... block

            else #invalid input
                println("Invalid choice, please try again.")
            end  # closes if c2 == "1" / elseif "2" / else
        end  # closes while pending_1
        else
           println("You are about to proceed to the next section.\nPress 1 to confirm or any other key to return to the previous section.")
           c4 = readline() #confirmation on choice
           if c4=="1"
            pending = false
           end
        end
        end  # closes while pending

        # GENERATED: moved here from the old c4 branch — this now fires exactly once per day,
        # after the expense-entry loop exits, regardless of whether the day had expenses (c1=="1")
        # or not (c1=="2"). Previously this line only lived inside the c1=="2" branch, so days
        # WITH real expenses never added anything to monthly_total.expenses at all.
        monthly_total.expenses += daily_values["Doctor's Fees"][day_no] + daily_values["Pharmacy Supplies"][day_no]

        println("Please enter the total deposits for the day.")
        daily_values["Deposits"][day_no] = parse(Float64,readline())
        monthly_total.deposits += daily_values["Deposits"][day_no]

        g += 1
end
return monthly_costs, monthly_total, daily_values, date
end

#------------------------Quickbooks Balance Sheet Generation Section--------------------------------------------------

#= Maps each field of the `costs` struct to its corresponding QuickBooks account name.
# When a new cost category is added to the `costs` struct later, add its mapping here too; that's the only edit required.
Only Account, Debit, and Credit are produced by this code; Description, Name, Tax, and Location are not handled here.=#

const COST_ACCOUNT_INFO = Dict(
    :doctor_fees           => "Cost of sales:Sub-contractor - COS",
    :pharmacy_supply_costs => "Cost of sales:Purchases-COS"  # FIXED: was "Medical & Lab Tests" — corrected per updated account mapping
)

const CASH_ACCOUNT        = "Cash & Cash Equivalent:Petty Cash:Petty Cash Urgent Care"
const SALES_ACCOUNT       = "Medical & Lab Tests"
const UNDEPOSITED_ACCOUNT = "Undeposited Funds"

#= Builds the ledger rows, in order, from the monthly_costs and monthly_total structs
   output by csv1(). Only Account, Debit, and Credit columns are produced, per scope.=#

function build_ledger_rows(monthly_costs::costs, monthly_total::totals)
    rows = NamedTuple[]

    # 1. Cash sales entry (skipped if there were no cash sales this month)
    if monthly_total.cash_sales > 0.0
        push!(rows, (Account=CASH_ACCOUNT, Debit=monthly_total.cash_sales, Credit=missing))
        push!(rows, (Account=SALES_ACCOUNT, Debit=missing, Credit=monthly_total.cash_sales))
    end

    # 2. One debit/credit pair per cost category — iterates over every field of the
    #    `costs` struct generically, so adding new categories later needs no changes
    #    here, only a new entry in COST_ACCOUNT_INFO above.
    for field in fieldnames(costs)
        amount = getfield(monthly_costs, field)
        if amount > 0.0   # entry omitted entirely if this category's monthly total is 0
            account = get(COST_ACCOUNT_INFO, field, nothing)
            if account === nothing
                error("No account mapping defined for cost field :$field [add cost account to COST_ACCOUNT_INFO]")
            end
            push!(rows, (Account=account, Debit=amount, Credit=missing))
            push!(rows, (Account=CASH_ACCOUNT, Debit=missing, Credit=amount))
        end
    end

    # 3. Deposits entry (skipped if there were no deposits this month)
    if monthly_total.deposits > 0.0
        push!(rows, (Account=UNDEPOSITED_ACCOUNT, Debit=monthly_total.deposits, Credit=missing))
        push!(rows, (Account=CASH_ACCOUNT, Debit=missing, Credit=monthly_total.deposits))
    end

    return rows
end

# Converts the ledger rows into a DataFrame (preserving row order) and writes the CSV.
function write_ledger_csv(monthly_costs::costs, monthly_total::totals, filepath::String)
    rows = build_ledger_rows(monthly_costs, monthly_total)
    df = DataFrame(rows)
    CSV.write(filepath, df)
    return df
end

#---------------------------------------Daily Records CSV Generation--------------------------------------------------
#= Builds one row per day from the daily_values dict and date vector output by csv1().
   Total Daily Expenses is a derived column (Doctor's Fees + Pharmacy Supply Costs for
   that day) — not stored in daily_values itself, just computed here.=#
function build_daily_records(daily_values::Dict{String,Vector{Float64}}, date::Vector{Int})
    n = length(date)

    doctor_fees   = daily_values["Doctor's Fees"]
    pharmacy      = daily_values["Pharmacy Supplies"]
    cash_received = daily_values["Cash Received"]
    deposits      = daily_values["Deposits"]

    total_daily_expenses = [doctor_fees[i] + pharmacy[i] for i in 1:n]

    df = DataFrame(
        Symbol("Date")                     => date,
        Symbol("Cash Sales (Received)")    => cash_received,
        Symbol("Doctor's Fees")            => doctor_fees,
        Symbol("Pharmacy Supply Costs")    => pharmacy,
        Symbol("Total Daily Expenses")     => total_daily_expenses,
        Symbol("Deposits")                 => deposits
    )

    return df
end

function write_daily_records_csv(daily_values::Dict{String,Vector{Float64}}, date::Vector{Int}, filepath::String)
    df = build_daily_records(daily_values, date)
    CSV.write(filepath, df)
    return df
end

#---------------------------------------Audit Log--------------------------------------------------
#= Appends one line per run: who ran the program (OS username) and when.
   Grabs the username from the environment rather than asking the user to type
   it in, so it can't be misreported. Appends (doesn't overwrite) so history
   accumulates across every run. =#
function log_entry(filepath::String="audit_log.txt")
    username = get(ENV, "USERNAME", get(ENV, "USER", "unknown"))  # USERNAME first (Windows), falls back to USER (Mac/Linux), then "unknown" if neither is set
    timestamp = Dates.format(now(), "yyyy-mm-dd HH:MM:SS")

    open(filepath, "a") do io  # "a" = append mode — adds to the end of the file rather than overwriting it
        println(io, "$(timestamp) — $(username)")
    end
end

#---------------------------------------Driver Code--------------------------------------------------
#= GENERATED SECTION: calls the functions above in order, capturing every output, then
   writes both CSVs. Filenames are relative paths — they'll be written into whatever
   directory `pwd()` reports when this script is run. Change to full paths (e.g.
   "C:/Users/YourName/Documents/ledger.csv") if you want them written somewhere specific. =#

monthly_costs, monthly_total, daily_values, date = csv1(n_work_days)

df_ledger = write_ledger_csv(monthly_costs, monthly_total, "ledger_$(m)_$(y).csv")
df_daily  = write_daily_records_csv(daily_values, date, "daily_records_$(m)_$(y).csv")
log_entry()  # GENERATED: records who ran this script and when, appended to audit_log.txt in pwd()

println("Done. Files written to: $(pwd())")
