module Ledger

using DataFrames, CSV
using ..Config

# =============================================================================
# LEDGER — QuickBooks-importable double-entry rows.
#
# ALMOST ENTIRELY UNCHANGED FROM v2.1.1. build_ledger_rows and write_ledger_csv
# are lifted out of the old file with their logic, comments and row ordering
# intact. They were already written against four `Dict{Symbol,Float64}` totals,
# and that is exactly the shape of both a single day and a whole month — so
# this file serves BOTH the new daily ledger and the monthly ledger with no
# duplication and no branching on which one it is producing.
#
# The only substantive edits are marked FIXED / NEW below.
# =============================================================================

export build_ledger_rows, write_ledger_csv

function build_ledger_rows(total_cash_eq, total_expense, total_deposit, total_rp)
    rows = NamedTuple[]

    # Merges categories within a group that share the same debit account, since
    # only unique account names get their own ledger row. Scoped per-group (not
    # across groups), so the shared counter-accounts (SALES_ACCOUNT,
    # CASH_ACCOUNT) still get one row per group/section rather than one giant
    # merged row across the whole ledger.
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

    # ---- Sales-crediting entries: debit each unique cash/POS account, credit
    # medical sales revenue. Sorted largest-to-smallest.
    cash_combined = merged_totals(cash_eq_in, total_cash_eq)
    cash_entries = sort(collect(cash_combined), by = x -> x[2], rev = true)
    for (account, amount) in cash_entries
        push!(rows, (Account=account, Debit=amount, Credit=missing))
        push!(rows, (Account=SALES_ACCOUNT, Debit=missing, Credit=amount))
    end

    # ---- Expense entries: debit each unique cost account (merged), credit petty cash.
    expense_combined = merged_totals(expense, total_expense)
    for c in expense
        if haskey(expense_combined, c.account)  # skip if already emitted by an earlier category sharing it
            amount = expense_combined[c.account]
            push!(rows, (Account=c.account, Debit=amount, Credit=missing))
            push!(rows, (Account=CASH_ACCOUNT, Debit=missing, Credit=amount))
            delete!(expense_combined, c.account)  # prevents re-emitting for the next category on the same account
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

    # ---- Undeposited funds: always last, its own distinct pair — deliberately
    # NOT merged into the CASH_ACCOUNT credits above, so it can stay the final
    # entry as required.
    total_deposits_amt = sum(values(total_deposit); init=0.0)
    # FIXED: the generator below is empty if cash_eq_in ever contains only
    # :cash_sales, and sum() of an empty generator throws. `init=0.0` makes the
    # empty case return zero instead.
    total_pos_amt = sum((total_cash_eq[c.key] for c in cash_eq_in if c.key != :cash_sales); init=0.0)
    total_rp_amt  = sum(values(total_rp); init=0.0)
    undeposited_amt = total_deposits_amt - total_pos_amt - total_rp_amt

    if undeposited_amt > 0.0
        push!(rows, (Account=deposit[1].account, Debit=undeposited_amt, Credit=missing))
        push!(rows, (Account=CASH_ACCOUNT, Debit=missing, Credit=undeposited_amt))
    elseif undeposited_amt < 0.0
        # NEW. v2.1.1 silently dropped a negative plug via `if ... > 0.0`. You
        # have confirmed this figure is never negative in practice, so a
        # negative one means the day's inputs are wrong (typically deposits
        # entered lower than the POS takings they cover). Surfacing it as a
        # warning is the point: the day still writes, but nobody discovers the
        # discrepancy a month later while reconciling.
        @warn "Undeposited funds computed negative (\$$(round(undeposited_amt, digits=2))): " *
              "deposits are less than POS + related-party outflows. Ledger written without an " *
              "undeposited-funds entry — check the day's figures."
    end
    # (undeposited_amt == 0.0 emits nothing, exactly as in v2.1.1.)

    return rows
end

"""
    write_ledger_csv(total_cash_eq, total_expense, total_deposit, total_rp, filepath)

Unchanged from v2.1.1 apart from the docstring. Called twice per run now — once
with a single day's amounts, once with the journal's column sums.
"""
function write_ledger_csv(total_cash_eq, total_expense, total_deposit, total_rp, filepath::String)
    rows = build_ledger_rows(total_cash_eq, total_expense, total_deposit, total_rp)

    # NEW. A day on which nothing happened produces zero rows, and
    # DataFrame(NamedTuple[]) is a 0x0 frame — which would write a completely
    # empty file with no header at all. Emit the header row instead, so the
    # file is still a valid (if empty) ledger.
    df = isempty(rows) ?
        DataFrame(Account=String[], Debit=Union{Missing,Float64}[], Credit=Union{Missing,Float64}[]) :
        DataFrame(rows)

    CSV.write(filepath, df)
    return df
end

end # module Ledger
