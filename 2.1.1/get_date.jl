module 
export get_date


function get_date()
    year = "";
    month = "";
    println("Please enter the year corresponding to the current balance sheet.")
    year = readline()
    println("\nPlease enter the number (1-12) of the month corresponding to the current balance sheet.")
    month = readline()
    return month, year
end
end #module