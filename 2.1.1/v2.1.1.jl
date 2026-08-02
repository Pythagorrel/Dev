include("AuditLog.jl")
incldue("get_date.jl")
using .AuditLog
using .get_date
using DataFrames, CSV, Dates

cash_eq_in = [(key=:cash_sales, label="Cash Sales", account="Cash & Cash Equivalent:Petty Cash:Petty Cash Urgent Care"),
    (key=:POS_Scotia, label="POS Deposits To Scotiabank", account="Cash & Cash Equivalent:Scotia Bank"),
    (key=:POS_RBL, label="POS Deposits to Republic Bank", account="Cash & Cash Equivalent:RBL - CHQ-13739"),
    (key=:POS_U, label="POS Deposits To Unspecified Bank", account="Cash & Cash Equivalent:POS Unidentified Urgent Care")]


expense = [(key=:doctor_fees, label="Doctor's Fees", account="Cost of sales:Sub-contractor - COS"),
    (key=:medical_supply_costs, label="Medical Supplies", account="Cost of sales:Purchases-COS"),
    (key=:miscellaneous_costs, label="Miscellaneous Items", account="Cost of sales:Purchases-COS"),
    (key=:taxi_fare, label="Taxi Fare", account="Local Transportation")]

deposit = [(key=:deposits, label="Deposits", account="Undeposited Funds Urgent Care")]

related_party = [(key=:Mr_Boyle, label="Transfers Out to Mr. Boyle", account="Related Party:Related Party-Mr.Boyle")]

# NEW: the two "counter accounts" that don't live in any config array —
# every cash_eq_in category credits this on sale, every expense/related_party credits this when paid out.
const SALES_ACCOUNT = "Medical & Lab Tests"
const CASH_ACCOUNT  = "Cash & Cash Equivalent:Petty Cash:Petty Cash Urgent Care"
# NOTE: no separate UNDEPOSITED_ACCOUNT const needed — deposit[1].account already holds it.

function csv1()

    daily_cash_eq = Dict{Symbol,Vector{Float64}}(category.key=>Float64[] for category in cash_eq_in) #for every category (each element) in cash_eq_in in the cash_eq_in array, the 'key' field is mapped onto an empty vector of type Float64
    daily_expense = Dict{Symbol,Vector{Float64}}(category.key=>Float64[] for category in expense)
    daily_deposit = Dict{Symbol,Vector{Float64}}(category.key=>Float64[] for category in deposit)
    daily_rp = Dict{Symbol,Vector{Float64}}(category.key=>Float64[] for category in related_party)
    m = 0;
    y=0;
    dates = Int[]

    m, y = get_date()

    function csv1a()  

        day_no = 1+length(dates) #ENSURES THAT INDEX MOVES FORWARD BY 1 EVERY TIME THE RECURSIVE LOOP TRIGGERS

        println("\nPlease enter the date [number from 1-31] of this balance sheet.")

        push!(dates, parse(Int, readline()))  # FIXED: was a length(dates)<1 branch that only handled day 1 correctly; push! always appends, so it works identically on every day and dates[day_no] is always valid immediately after

        for category in cash_eq_in
            push!(daily_cash_eq[category.key], 0.0) #adds a 0.0 as the value of the current key index for each 'key' field in the cash_eq_in array; updates per day  # FIXED: push!(dict[key], value) — was push!(dict[key, value]), which tried to index the dict with two keys instead of pushing a value into the vector
        end

        for category in expense
            push!(daily_expense[category.key], 0.0) #does the same for the expenses array  # FIXED: same push! syntax fix as above
        end

        for category in deposit  
            push!(daily_deposit[category.key], 0.0)
        end

        for category in related_party  
            push!(daily_rp[category.key], 0.0)
        end

        #----------------Cash and Cash Equivalent Entry Loop---------------------------------------------------------------------------------------------
        pending = true
        while pending

            println("\nPlease select the cash or cash equivalent sales category
            \nyou would like to update for the current day from the menu below:")

            for (i, category) in enumerate(cash_eq_in)
                println("\n$i. $(category.label)")
            end

            println("\nEnter 0 if there were no sales on this day. This will take you to the next section.")

            c1 = parse(Int, readline())  

            if c1==0
                pending = false
            else

                println("\nOkay you have selected $(cash_eq_in[c1].label).
                \nPlease enter the total amount for the current day:")

                daily_cash_eq[cash_eq_in[c1].key][day_no] = parse(Float64, readline())  # FIXED: dict is keyed by Symbol, but this was indexing with "$(cash_eq_in[c1].key)" (a String) — removed the string interpolation so the Symbol itself is used as the key

                println("\nAmount: \$$(daily_cash_eq[cash_eq_in[c1].key][day_no]) stored. Enter 1 to return to the Cash Or Cash Equivalent Sales Category Menu.
                \nOtherwise, enter any other key to proceed to the next section.")

                c2 = parse(Int, readline())

                if c2!=1
                    pending = false
                end

            end

        end #end of while pending loop


        #----------------Expense Entry Loop---------------------------------------------------------------------------------------------
        pending1 = true
        while pending1

            println("\nPlease select the expense category
            \nyou would like to update for the current day from the menu below:")

            for (i, category) in enumerate(expense)
                println("\n$i. $(category.label)")
            end

            println("\nEnter 0 if there were no expenses on this day. This will take you to the next section.")

            c3 = parse(Int, readline())  
            if c3==0
                pending1 = false
            else

               
                println("\nOkay you have selected $(expense[c3].label).
                \nPlease enter the total amount for the current day:")

                daily_expense[expense[c3].key][day_no] = parse(Float64, readline()) 

                println("\nAmount: \$$(daily_expense[expense[c3].key][day_no]) stored. Enter 1 to return to the Expense Category Menu.
                \nOtherwise, enter any other key to proceed to the next section.")

                c4 = parse(Int, readline())

                if c4!=1
                    pending1 = false
                end 

            end

        end #end of while pending1 loop

        println("Please enter the total deposits for the day: ")
        daily_deposit[deposit[1].key][day_no] = parse(Float64, readline())  # FIXED: deposit has exactly one entry and no menu, so reference deposit[1] directly rather than deposit[c1] (c1 belongs to an unrelated menu)

        println("If any money was taken out on behalf of a related party, please indicate the sum
        \nOtherwise, enter 0: ")
        daily_rp[related_party[1].key][day_no] = parse(Float64, readline())  # FIXED: same fix as deposit above — related_party[1], not related_party[c1]

        println("If you have another day's balance sheet to record, enter 1.
        \nEnter 2 to generate the current spreadsheet.")

        c5 = readline()

        if c5 == "1"
            csv1a()  
        else
            println("Generating...")
        end

    end #csv1a() end

    csv1a() 

    total_cash_eq = Dict(k => sum(v) for (k, v) in daily_cash_eq)

    total_expense = Dict(k => sum(v) for (k, v) in daily_expense)

    total_deposit = Dict(k => sum(v) for (k, v) in daily_deposit)

    total_rp = Dict(k=>sum(v) for (k, v) in daily_rp)

    return dates, daily_cash_eq, total_cash_eq, daily_expense, total_expense, daily_deposit, total_deposit, daily_rp, total_rp, m, y

end #csv1() end


#------------------------QuickBooks Ledger Generation Section--------------------------------------------------
# NEW: generic across all three category groups — each group's "counter account" differs,
# so each gets its own loop rather than one shared pattern.

function build_ledger_rows(total_cash_eq, total_expense, total_deposit, total_rp)
    rows = NamedTuple[]

    # NEW: merges categories within a group that share the same debit account, since only
    # unique account names get their own ledger row. Scoped per-group (not across groups),
    # so the shared counter-accounts (SALES_ACCOUNT, CASH_ACCOUNT) still get one row per
    # group/section rather than one giant merged row across the whole ledger.
    function merged_totals(categories, totals_dict)
        combined = Dict{String,Float64}()
        for c in categories
            amt = totals_dict[c.key]
            if amt > 0.0
                combined[c.account] = get(combined, c.account, 0.0) + amt
            end
        end
        return combined
    end

    # ---- Sales-crediting entries: debit each unique cash/POS account, credit medical sales revenue.
    # Sorted largest-to-smallest.
    cash_combined = merged_totals(cash_eq_in, total_cash_eq)
    cash_entries = sort(collect(cash_combined), by = x -> x[2], rev = true)
    for (account, amount) in cash_entries
        push!(rows, (Account=account, Debit=amount, Credit=missing))
        push!(rows, (Account=SALES_ACCOUNT, Debit=missing, Credit=amount))
    end

    # ---- Expense entries: debit each unique cost account (merged), credit petty cash.
    expense_combined = merged_totals(expense, total_expense)
    for c in expense
        if haskey(expense_combined, c.account)  # NEW: skip if this account was already emitted by an earlier category sharing it
            amount = expense_combined[c.account]
            push!(rows, (Account=c.account, Debit=amount, Credit=missing))
            push!(rows, (Account=CASH_ACCOUNT, Debit=missing, Credit=amount))
            delete!(expense_combined, c.account)  # NEW: prevents re-emitting for the next category on the same account
        end
    end

    # ---- Related party entries: debit each unique account (merged), credit petty cash.
    rp_combined = merged_totals(related_party, total_rp)
    for c in related_party
        if haskey(rp_combined, c.account)
            amount = rp_combined[c.account]
            push!(rows, (Account=c.account, Debit=amount, Credit=missing))
            push!(rows, (Account=CASH_ACCOUNT, Debit=missing, Credit=amount))
            delete!(rp_combined, c.account)
        end
    end

    # ---- Undeposited funds: always last, its own distinct pair — deliberately NOT merged
    # into the CASH_ACCOUNT credits above, so it can stay the final entry as required.
    total_deposits_amt = sum(values(total_deposit))
    total_pos_amt = sum(total_cash_eq[c.key] for c in cash_eq_in if c.key != :cash_sales)
    total_rp_amt = sum(values(total_rp))
    undeposited_amt = total_deposits_amt - total_pos_amt - total_rp_amt

    if undeposited_amt > 0.0
        push!(rows, (Account=deposit[1].account, Debit=undeposited_amt, Credit=missing))
        push!(rows, (Account=CASH_ACCOUNT, Debit=missing, Credit=undeposited_amt))
    end

    return rows
end

function write_ledger_csv(total_cash_eq, total_expense, total_deposit, total_rp, filepath::String)
    rows = build_ledger_rows(total_cash_eq, total_expense, total_deposit, total_rp)
    df = DataFrame(rows)
    CSV.write(filepath, df)
    return df
end


#---------------------------------------Daily Records CSV Generation--------------------------------------------------
# NEW: one column per config-array category (was hardcoded to 2 categories before), plus a full
# d-m-y Date column instead of just a day number, per client request.
function build_daily_records(dates::Vector{Int}, m, y, daily_cash_eq, daily_expense, daily_deposit, daily_rp)
    month_int = parse(Int, m)  # m/y come in as Strings from get_date(); Date() needs Ints
    year_int  = parse(Int, y)
    full_dates = [Date(year_int, month_int, d) for d in dates]  # NEW: full date, not just day number

    cols = Any[Symbol("Date") => full_dates]
    for category in cash_eq_in
        push!(cols, Symbol(category.label) => daily_cash_eq[category.key])
    end
    for category in expense
        push!(cols, Symbol(category.label) => daily_expense[category.key])
    end
    push!(cols, Symbol(deposit[1].label) => daily_deposit[deposit[1].key])
    push!(cols, Symbol(related_party[1].label) => daily_rp[related_party[1].key])

    return DataFrame(cols)
end

function write_daily_records_csv(dates, m, y, daily_cash_eq, daily_expense, daily_deposit, daily_rp, filepath::String)
    df = build_daily_records(dates, m, y, daily_cash_eq, daily_expense, daily_deposit, daily_rp)
    CSV.write(filepath, df)
    return df
end

#---------------------------------------Driver Code--------------------------------------------------
dates, daily_cash_eq, total_cash_eq, daily_expense, total_expense, daily_deposit, total_deposit, daily_rp, total_rp, m, y = csv1()

ledger_dir = "$(y)_ledgers"
daily_dir  = "$(y)_daily_records"
mkpath(ledger_dir)
mkpath(daily_dir)

df_ledger = write_ledger_csv(total_cash_eq, total_expense, total_deposit, total_rp, joinpath(ledger_dir, "ledger_$(m)_$(y).csv"))
df_daily  = write_daily_records_csv(dates, m, y, daily_cash_eq, daily_expense, daily_deposit, daily_rp, joinpath(daily_dir, "daily_records_$(m)_$(y).csv"))
log_entry()

println("Done. Files written to: $(pwd())")