"""Run: python3 Checks/check_finance_account_switch.py [Sources/Finance/FinanceEntryEditor.swift]
Exercises the actual account-change handler without opening a user's database.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

source = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / 'Sources/Finance/FinanceEntryEditor.swift'
text = source.read_text()
start = text.index('.onChange(of: draft.accountID)')
end = text.index('.onChange(of: draft.kind)', start)
handler = text[start:end]
body = handler[handler.index(' in\n') + 4:handler.rindex('}')]
program = '''import Foundation
struct Account { var id = UUID(); var currency = "AUD" }
struct Ledger { var accounts: [Account] }
enum Kind { case expense, income, refund, transfer }
struct Draft { var kind = Kind.expense; var currency = "AUD"; var rateNote = "Recorded"; var accountID: UUID? }
struct Probe {
    var ledger: Ledger; var draft: Draft
    var expected: Draft? = Draft(), expression = "100"
    var actual = "100", converted = "500", received = "", convertedFee = "", rates = [5]
    var filledValues = ["actual": "100"], scaledValues = ["actual": "100"]
    var account: Account? { ledger.accounts.first { $0.id == draft.accountID } }
    mutating func changed(from old: UUID?) {
''' + body + '''
    }
}
let first = Account(), second = Account(), yuan = Account(currency: "CNY")
let ledger = Ledger(accounts: [first, second, yuan])
for kind in [Kind.expense, .income, .refund] {
    var probe = Probe(ledger: ledger, draft: Draft(kind: kind, accountID: second.id))
    probe.changed(from: first.id)
    precondition(probe.converted == "500", "Historical reporting amount must survive account reassignment")
    precondition(probe.actual == "100", "Same-currency settlement amount must survive reassignment")
    precondition(probe.rates == [5], "Existing quotes remain available for later amount edits")
    probe.converted = "0"; probe.changed(from: first.id)
    precondition(probe.converted == "0", "Zero reporting amount must not become missing")
}
var foreignSwitch = Probe(ledger: ledger, draft: Draft(accountID: second.id))
foreignSwitch.changed(from: yuan.id)
precondition(foreignSwitch.actual.isEmpty && foreignSwitch.filledValues["actual"] == nil && foreignSwitch.scaledValues["actual"] == nil, "A different settlement currency must discard old account amount")
precondition(foreignSwitch.converted == "500", "Account change alone does not reprice historical reporting amount")
var fresh = Probe(ledger: ledger, draft: Draft(currency: "CNY", accountID: second.id))
fresh.expected = nil; fresh.expression = ""
fresh.changed(from: yuan.id)
precondition(fresh.draft.currency == "AUD", "A blank new entry follows the selected account currency")
var typed = Probe(ledger: ledger, draft: Draft(currency: "CNY", accountID: second.id))
typed.expected = nil
typed.changed(from: yuan.id)
precondition(typed.draft.currency == "CNY", "Changing accounts must not relabel an amount already typed")
var historical = Probe(ledger: ledger, draft: Draft(currency: "CNY", accountID: second.id))
historical.expression = ""
historical.changed(from: yuan.id)
precondition(historical.draft.currency == "CNY", "Historical entry currency is never replaced by its new account currency")
print("PASS: account currency defaults, typed amounts and historical conversion preservation")
'''
with tempfile.TemporaryDirectory(prefix='jianshi-account-switch-') as directory:
    path = Path(directory) / 'check.swift'
    path.write_text(program)
    subprocess.run(['swift', '-module-cache-path', directory + '/modulecache', str(path)], check=True)
