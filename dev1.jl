# g = 0; h = 0; i = 0; j = 0; k = 0 #initialising indices for while loops 
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
     month = readline
     return month, year
end
    m,y = get_date()

    println("Please enter the number of work days for $(month)/$(year).")
    n_work_days = parse(Float64, readline)

function csv1(n)
    daily_values = Dict{String,Vector{Float64}}(
        "Doctor's Fees" => Float64[], 
        "Pharmacy Supplies" => Float64[])
        "Cash Received" => Float64[], 
        "Deposits" => Float64[]
    monthly_total = totals()
    monthly_costs = costs() #sum of each individual type of cost per month
    g=0; 

    while g < n

        day_no = g+1

         push!(daily_values["Cash Received"],0.0)
         push!(daily_values["Doctor's Fees"],0.0)
         push!(daily_values["Pharmacy Supplies"],0.0)
         push!(daily_values["Deposits"],0.0)

        println("Please enter the Cash Sales (Received) for day $(day_no).")

        push!(daily_values["Cash Received"],parse(Float64,readline())) 
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
                push!(daily_values["Doctor's Fees"],parse(Float64,readline())) 
                monthly_costs.doctor_fees += daily_values["Doctor's Fees"][day_no]

            elseif c2 == "2" #Pharmacy Supplies

                println("You selected Pharmacy Supplies.
                \nPlease enter the total for the day.")
                push!(daily_values["Pharmacy Supplies"],parse(Float64,readline())) 
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
            monthly_total.expenses += sum(sum(v) for v in values(daily_values))
            monthly_costs.doctor_fees += sum(daily_values["Doctor's Fees"])
            monthly_costs.pharmacy_supply_costs += sum(daily_values["Pharmacy Supplies"])
            pending = false
           end
        end
        end
        println("Please enter the total deposits for the day.")
        push!(daily_values["Deposits"],parse(Float64,readline()))
        monthly_total.deposits += daily_values["Deposits"][day_no]
end
return monthly_costs, monthly_total, daily_values
end

