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

function get_date()
    year = "";
    month = "";
    println("Please enter the year corresponding to the current balance sheet.")
    year = readline()
    println("\nPlease enter the number (1-12) of the month corresponding to the current balance sheet.")
    month = readline()
    return month, year
end

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

    return dates, daily_cash_eq, total_cash_eq, daily_expense, total_expense, daily_deposit, total_deposit, daily_rp, total_rp

end #csv1() end