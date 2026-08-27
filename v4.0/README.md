# ldgr v4.0

Daily bookkeeping entry for the urgent care clinic. Produces a Daily Journal and
QuickBooks-importable ledgers, and checks every day's cash before it writes
anything.

v3.0 recorded what it was given. v4.0 subjects each day to a graded battery of
checks first, records unexplained differences instead of hiding them, and will
not produce a ledger for a day whose predecessor is missing.

---

## Requirements

- Julia 1.10 or later
- Packages: `DataFrames`, `CSV`, `HTTP`, `JSON3`

Install the packages once:

```
julia -e 'using Pkg; Pkg.add(["DataFrames","CSV","HTTP","JSON3"])'
```

---

## Running it

### The form (normal use)

```
julia server.jl
```

then open <http://127.0.0.1:8000>. Use `julia server.jl 9000` for a different
port. Ctrl+C in that window stops it.

The server listens on 127.0.0.1 only — reachable from that machine and nowhere
else. **Do not change the bind address to 0.0.0.0**; it has no authentication
because it does not need any.

### Command line

```
julia main.jl day.csv                 # one day from a CSV
julia main.jl day.csv --force         # confirm a ledger may be regenerated
julia main.jl day.csv --first-day     # accept the very first opening balance
julia main.jl                         # interactive prompts
```

### Where the files go

`Records/` beside the source, or wherever `LEDGER_ROOT` points:

```
Records/
├── audit_log.txt
├── Reports/
│   └── Daily Report 2026-06-14.txt
├── Staging/Pending Entries.csv
└── 2026/06/
    ├── Daily Journal 06-2026.csv        ← source of truth, never delete
    ├── Monthly Ledger 06-2026.csv       ← rebuilt every run
    └── Daily Ledgers 06-2026/
        └── Daily Ledger 2026-06-14.csv
```

---

## Testing

**Always point `LEDGER_ROOT` at a scratch folder first.** Every test writes to
disk.

```
LEDGER_ROOT=/tmp/ldgr_test julia test_endtoend.jl    # 36 checks, the Warnings Guide §9 list
julia test_checks_basic.jl                           # each warning, in isolation
julia test_checks_hints.jl                           # the diagnostic hints
```

`test_endtoend.jl` prints PASS/FAIL per case and exits non-zero on any failure.

---

## The identity

    Opening + Cash sales − Expenses − Deposit − Mr. Boyle = Closing

Two checks come from it:

- **Day check** — does the counted drawer match what the figures predict?
- **Overnight check** — does this morning's opening match the last working day's
  closing?

Both differences are recorded as journal columns *and* posted to the Cash
Over/Short account, so QuickBooks' petty cash balance keeps matching the drawer.

The three POS figures appear in neither check. Card money settles bank-side and
never enters the drawer, so nothing in this program can verify a POS figure —
only the bank statement can.

---

## Files

| File | |
|---|---|
| `Config.jl` | Chart of accounts, the cash book, the identity. **Never change a category `key`.** |
| `Layout.jl` | Every path in the system. Nothing else builds one. |
| `Checks.jl` | **New.** All four warning tiers. Codes match the Warnings Guide. |
| `Chain.jl` | **New.** Previous-day lookup across month/year, and the ledger gate. |
| `Report.jl` | **New.** The daily report text file. |
| `DayInput.jl` | Input → one `DayRecord`. Blank-vs-zero lives here. |
| `Journal.jl` | The Daily Journal. Read, write, upsert, totals. |
| `Ledger.jl` | Double-entry rows, including the over/short posting. |
| `Staging.jl` | Days entered but not committed. |
| `AuditLog.jl` | Who ran what, when, and what it touched. |
| `main.jl` | `process_day` — the pipeline both front doors call. |
| `server.jl` | The only place browser and bookkeeping code meet. |
| `public/` | The form. Holds no category names of its own. |

---

## Rules that must not be broken

1. **Never change a category `key` in Config.jl.** Keys are the column headings
   in every journal ever written. Labels and account strings are safe to change
   at any time.
2. **Never build a path outside Layout.jl.**
3. **Never calculate the closing balance for the user.** It is the only figure
   that comes from counting the drawer. Fill it in automatically and every day
   balances by construction and the check detects nothing, permanently.
4. **Never pre-fill the opening balance either** — the overnight check would
   compare a number against itself.
5. **Never let a Level 2 be dismissed with one click.** The typed reason is the
   entire value of the warning.
6. **Never edit a Daily Journal in Excel.** It reformats the date column on save
   and the file becomes unreadable. Correct figures by re-entering that date.
7. **Never change the server bind address from 127.0.0.1.**
8. Do not run two servers against the same Records folder. Concurrent writes can
   still lose a day; the informal rule is one person entering at a time.

---

## Before this goes live

- [ ] **Confirm the Cash Over/Short account.** `Config.jl` currently uses
      `"Unidentified Income"`. Check it is not already used for unidentified
      *receipts* — if it is, a shortage and a receipt would net against each
      other and the balance-sheet review would show nothing.
- [ ] **Verify every account string** against a CSV export of the chart of
      accounts, opened in a text editor rather than Excel. Two of the handful
      checked so far were wrong.
- [ ] Decide whether a month can be locked once exported to QuickBooks.
- [ ] Decide whether refunds, bank withdrawals to the till, or money in from
      Mr. Boyle need their own fields. Today they would be rejected as negatives.
