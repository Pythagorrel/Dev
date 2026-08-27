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

function build_ledger_rows(total_cash_eq, total_expense, total_deposit, total_rp;
                           day_variance::Float64=0.0, overnight_variance::Float64=0.0)
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

    # ---- Undeposited funds -------------------------------------------------
    #
    # ⚠ CHANGED IN v4.0 — THE ONE PLACE LEDGER OUTPUT DIFFERS FROM v3.0.
    #
    # v2.1.1 and v3.0 computed:
    #       undeposited = deposits − POS − related_party
    # That was correct for the FORM THOSE VERSIONS TOOK. Their `deposits` field
    # meant "everything that landed in the bank that day", a gross bank-side
    # figure that already included the card settlements and the related-party
    # transfer. Subtracting them was how the physical-cash component was
    # recovered. (Handover §6 records this as an open question, on the reading
    # that the related-party term might be double-counting. It was not — the
    # ambiguity was in what `deposits` meant, not in the subtraction.)
    #
    # The v4.0 sheet asks a different question. "Cash to be deposited" is the
    # physical cash component ON ITS OWN, with the three POS figures and the
    # transfer to Mr. Boyle each carrying their own separate field. So the
    # quantity the old formula worked to recover is now simply typed in, and
    # subtracting POS from it would remove money that was never in it.
    #
    # The formula is therefore not corrected but RETIRED. Both the POS term and
    # the related-party term are gone because the input they compensated for is
    # gone. The negative-result warning goes with them: a negative here is now
    # impossible by construction, because L1-A rejects a negative deposit before
    # a ledger is ever built.
    #
    # CONSEQUENCE FOR TESTING: a day with non-zero POS figures produces a
    # LARGER undeposited-funds entry under v4.0 than under v3.0. That is the
    # intended change, not a regression — but it means the Scenario G totals in
    # Handover §11 no longer apply as a like-for-like comparison.
    undeposited_amt = sum(values(total_deposit); init=0.0)

    if undeposited_amt > 0.0
        push!(rows, (Account=deposit[1].account, Debit=undeposited_amt, Credit=missing))
        push!(rows, (Account=CASH_ACCOUNT, Debit=missing, Credit=undeposited_amt))
    end

    # ---- Cash over/short ---------------------------------------------------
    #
    # NEW IN v4.0. This is what keeps QuickBooks' petty cash balance equal to
    # the counted drawer.
    #
    # WHY POSTING IS NOT OPTIONAL. The program emits movements; QuickBooks holds
    # the running balance. If a variance is recorded in the journal but never
    # posted, QuickBooks keeps reporting a petty cash figure that no longer
    # matches the drawer, silently, forever — and nothing in QuickBooks shows a
    # gap, because nothing put one there. The daily report would be the only
    # trace, and a report is a notification rather than a record: it cannot be
    # totalled, aged, or audited against.
    #
    # WHY IT DOES NOT "ABSORB" THE PROBLEM. That depends entirely on the account
    # type. Posted to an EXPENSE account the difference would clear to the P&L
    # each period and genuinely disappear. CASH_OVER_SHORT_ACCOUNT is a current
    # asset (see Config.jl), so the balance stays open and accumulates until
    # somebody writes it off deliberately. Three months of ignored differences
    # show up as a suspense balance on the balance sheet, which is far harder to
    # ignore than three months of emails.
    #
    # SIGN CONVENTION, fixed here and matching Checks.jl:
    #     variance = counted − predicted
    #   variance > 0  surplus  — real cash exceeds the books, so petty cash must
    #                            rise: DEBIT petty cash, CREDIT over/short.
    #   variance < 0  shortage — the books claim cash that is not there, so
    #                            petty cash must fall: CREDIT petty cash,
    #                            DEBIT over/short.
    #
    # The day and overnight variances post as SEPARATE rows even though they hit
    # the same account. They have different causes — one arose while trading,
    # one while the clinic was shut — and one combined figure throws away the
    # attribution that makes the number worth having.
    #
    # No double counting: day_variance + overnight_variance telescopes to
    # (counted movement − recorded movement) for the period, which is exactly
    # the correction petty cash needs. Proof is in Checks.jl above day_residual.
    for (amt, what) in ((day_variance, "day"), (overnight_variance, "overnight"))
        if abs(amt) >= 0.005
            if amt > 0
                push!(rows, (Account=CASH_ACCOUNT, Debit=amt, Credit=missing))
                push!(rows, (Account=CASH_OVER_SHORT_ACCOUNT, Debit=missing, Credit=amt))
            else
                push!(rows, (Account=CASH_OVER_SHORT_ACCOUNT, Debit=-amt, Credit=missing))
                push!(rows, (Account=CASH_ACCOUNT, Debit=missing, Credit=-amt))
            end
        end
    end


    return rows
end

"""
    write_ledger_csv(total_cash_eq, total_expense, total_deposit, total_rp, filepath)

Unchanged from v2.1.1 apart from the docstring. Called twice per run now — once
with a single day's amounts, once with the journal's column sums.
"""
function write_ledger_csv(total_cash_eq, total_expense, total_deposit, total_rp, filepath::String;
                          day_variance::Float64=0.0, overnight_variance::Float64=0.0)
    rows = build_ledger_rows(total_cash_eq, total_expense, total_deposit, total_rp;
                             day_variance=day_variance, overnight_variance=overnight_variance)

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
