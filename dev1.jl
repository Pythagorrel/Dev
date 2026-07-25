g = 0; h = 0; i = 0; j = 0; k = 0 #initialising indices for while loops 

println("Please enter the number of work days in the current month.")

n = parse(Int,readline())

function csv1()
    while g < n 
 day_no = g+1

 println("Please enter the Cash Sales (Received) for day $(day_no).")
 CS_daily = parse(Float64,readline())
 CS_monthly += CS_daily #rolling total for total monthly cash sales

 println("Please enter the Total Expenses for day $(day_no).")
 TE_daily = parse(Float64,readline())
 TE_monthly += TE_daily #rolling total for total monthly expenses

println("If these expenses belong to different accounts, enter 1.\nIf not, enter 2.")

c1 = parse(float64, readline()) #MENU SECTION; REWRITE WITH STRUCT >: ABSTRACT_TYPE & HELPER FUNCTIONS FOR MULTIPLE DEPLOY
    if d1 == 1 
        println("Please select the type of expense from the menu by entering its corresponding number:
        \n 1. Doctor Fees 
        \n 2. Pharmacy Supplies")

        c2 = parse(Float64, readline())
        #write an error catch here 

        if c2 ==1
            println("Please enter the Total Doctor Fees for day $(day_no).")
            DF_daily = parse(Float64,readline())
            DF_monthly += DF_daily
            println("Please enter the Total Pharmacy Supply Cost for day $(day_no).")
            PSC_daily = parse(Float64,readline())
            PSC_monthly += PSC_daily
        end

        if c2==2
            println("Please enter the Total Pharmacy Supply Cost for day $(day_no).")
            PSC_daily = parse(Float64,readline())
            PSC_monthly += PSC_daily
            println("Please enter the Total Doctor Fees for day $(day_no).")
            DF_daily = parse(Float64,readline())
            DF_monthly += DF_daily
        end

    else 
        println("Please select the type of expense from the menu by entering its corresponding number:
        \n 1. Doctor Fees 
        \n 2. Pharmacy Supplies")

        c2 = parse(Float64, readline())
        #write an error catch here 

        if c2 ==1
            DF_daily = parse(Float64,readline())
            DF_monthly += DF_daily
        end

        if c2==2
            PSC_daily = parse(Float64,readline())
            PSC_monthly += PSC_daily
        end
    end

    println("Please enter the Total Deposits for day $(day_no).")

    DEP_daily = parse(Float64,readline())
    DEP_monthly += DEP_daily
    g+=1
end
return CS_monthly, TE_monthly, DF_monthly, PSC_monthly, DEP_monthly
end

csv1()

