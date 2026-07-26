using DataFrames, CSV

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
     month = readline()  # FIXED: was `readline` (missing parens) — assigned the function itself instead of calling it
     return month, year
end
    m,y = get_date()

    println("Please enter the number of work days for $(m)/$(y).")  # FIXED: was $(month)/$(year), but those names don't exist at this scope — m,y are what get_date() returned
    n_work_days = parse(Float64, readline())  # FIXED: was `readline` (missing parens)

#--------------------------------------------Monthly total calculation section--------------------------------------------

function csv1(n)
    daily_values = Dict{String,Vector{Float64}}(
        "Doctor's Fees" => Float64[],
        "Pharmacy Supplies" => Float64[],   # FIXED: original closed the Dict(...) here with `)`, orphaning the next two pairs — syntax error
        "Cash Received" => Float64[],
        "Deposits" => Float64[]
    )
    monthly_total = totals()
    monthly_costs = costs() #sum of each individual type of cost per month
    g=0
    
    date =[]

    while g < n

        day_no = g+1

         push!(daily_values["Cash Received"],0.0)
         push!(daily_values["Doctor's Fees"],0.0)
         push!(daily_values["Pharmacy Supplies"],0.0)
         push!(daily_values["Deposits"],0.0)
         # NOTE: kept as a single push! per category per day (one 0.0 placeholder), as intended for
         # keeping all four vectors the same length for Tables.jl. The bug was downstream, where the
         # real value used to get push!'d again on top instead of overwriting this placeholder.

        println("Please enter the date [number from 1-31] of this balance sheet.")
        date[day_no] = parse(Int,readline())

        println("Please enter the Cash Sales (Received) for day $(day_no).")

        daily_values["Cash Received"][day_no] = parse(Float64,readline())  # FIXED: was push!(...) — this added a second entry instead of overwriting the day's placeholder, shifting every later index out of alignment
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
                daily_values["Doctor's Fees"][day_no] = parse(Float64,readline())  # FIXED: was push!(...) — same overwrite-not-append fix as Cash Received above
                monthly_costs.doctor_fees += daily_values["Doctor's Fees"][day_no]

            elseif c2 == "2" #Pharmacy Supplies

                println("You selected Pharmacy Supplies.
                \nPlease enter the total for the day.")
                daily_values["Pharmacy Supplies"][day_no] = parse(Float64,readline())  # FIXED: was push!(...) — same overwrite-not-append fix
                monthly_costs.pharmacy_supply_costs += daily_values["Pharmacy Supplies"][day_no]

            else #invalid input
                println("Invalid choice, please try again.")  
            end

        println("Is this the only type of expense for this day? Enter 1 or 2:
        \n1. Yes, proceed to next section.
        \n2. No, there are other expenses.")

        c3 = readline() #choice 3 on whether there was 1 or multiple expenses for the day
        if c3 == "1"
        println("Proceeding to next section. Please Press Enter...")
        readline()
        pending_1 = false
        elseif c3 == "2"
        println("Returning to menu...\n")
        else
        println("Invalid input, returning to menu.")

        end
    end
        else
            println("You are about to proceed to the next section.\nPress 1 to confirm or any other key to return to the previous section.")
           c4 = readline() #confirmation on choice
           if c4=="1"
            # FIXED: removed `monthly_total.expenses += sum(sum(v) for v in values(daily_values))` —
            # this summed ALL four categories including Cash Received and Deposits, which aren't expenses.
            # FIXED: removed `monthly_costs.doctor_fees += sum(daily_values["Doctor's Fees"])` and the
            # matching pharmacy_supply_costs line — these re-added the running totals a second time on
            # top of the incremental `+=` already done inside the c2=="1"/"2" branches above, double-counting.
            monthly_total.expenses += daily_values["Doctor's Fees"][day_no] + daily_values["Pharmacy Supplies"][day_no]  # GENERATED: replacement line — sums only this day's two expense categories into the day's total expenses
            pending = false
           end
        end
        end
        println("Please enter the total deposits for the day.")
        daily_values["Deposits"][day_no] = parse(Float64,readline())  # FIXED: was push!(...) — same overwrite-not-append fix
        monthly_total.deposits += daily_values["Deposits"][day_no]

        g += 1  # OMISSION FIXED: original loop never incremented g, so `while g < n` would never terminate (infinite loop, and day_no would stay stuck at 1 forever)
end
return monthly_costs, monthly_total, daily_values, date
end

#------------------------Quickbooks Balance Sheet Generation Section--------------------------------------------------

#= Maps each field of the `costs` struct to its corresponding QuickBooks account name.
# When a new cost category is added to the `costs` struct later, add its mapping here too; that's the only edit required. 
Only Account, Debit, and Credit are produced by this code; Description, Name, Tax, and Location are not handled here.=#

const COST_ACCOUNT_INFO = Dict(
    :doctor_fees           => "Cost of sales:Sub-contractor - COS",
    :pharmacy_supply_costs => "Medical & Lab Tests"
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
