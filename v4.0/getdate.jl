module getdate

# =============================================================================
# GETDATE — interactive month/year prompt.
#
# FIXED FROM v2.1.1:
#   * `module` was declared with no name at all, so `using .get_date` in the
#     driver could never resolve. The module is now named `getdate` and the
#     function it exports is `get_date` — the two no longer collide.
#   * get_date() returned Strings, which forced build_daily_records to do
#     `parse(Int, m)` downstream before it could construct a Date. It now
#     parses at the point of entry and returns Ints, so nothing downstream has
#     to guess what type it is holding.
#
# STILL USED? Only on the interactive path (no input file supplied). When the
# HTML form supplies a file, the year and month come out of that file and this
# function is never called. It is kept because running the program by hand is
# still the fastest way to test it.
# =============================================================================

export get_date

function get_date()
    println("Please enter the year corresponding to the current balance sheet.")
    year = parse(Int, strip(readline()))

    println("\nPlease enter the number (1-12) of the month corresponding to the current balance sheet.")
    month = parse(Int, strip(readline()))

    return month, year   # order preserved from v2.1.1: (month, year)
end

end # module getdate
