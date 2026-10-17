import Foundation
import SwiftData

/// Recurring bills as rules with a next date: previews, confirming, recording today, skipping, editing the rule
/// and the next date, ending, converting an entry, migrating bills from earlier builds, validation and sync.
@MainActor enum FinanceRecurringChecks {
    static func run(require: (Bool, String) throws -> Void, rejects: (String, () throws -> Void) throws -> Void) throws {
        let calendar = Dates.calendar
        func day(_ month: Int, _ day: Int, hour: Int = 10, year: Int = 2026) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
        }
        var ledger = FinanceData.initial
        let card = MoneyAccount(name: "Card")
        ledger.accounts = [card]
        let book = ledger.books[0].id
        var rent = MoneyEntry(); rent.title = "Rent"; rent.date = day(1, 31); rent.amount = 3200; rent.accountAmount = 3200
        rent.baseAmount = 3200; rent.accountID = card.id; rent.bookID = book; rent.categoryID = ledger.defaultCategory(income: false)
        let bill = MoneyRecurring(repeating: rent, rule: "monthly", until: nil, in: ledger)
        try require(bill.anchorDay == 31 && bill.nextDate == rent.date && bill.accountAmount == 0 && bill.baseAmount == nil,
                    "a bill keeps the day of month and needs no planned amounts in the base currency")
        try ledger.addRecurring(bill)

        // An editor opened before another window changes the rule must not silently post its old amount.
        let staleRequest = PendingEntryConfirmation(entry: ledger.recurringPreviews[0], data: ledger).request
        var changedRuleLedger = ledger
        var changedRule = bill; changedRule.amount = 6400
        try changedRuleLedger.updateRecurring(changedRule, expected: bill)
        try rejects("stale recurring confirmation must reject a changed amount at the same scheduled time") {
            try staleRequest.apply(staleRequest.entry, to: &changedRuleLedger, baseCurrency: ledger.baseCurrency)
        }

        for _ in 0..<3 {
            let preview = ledger.recurringPreviews[0]
            let occurrence = RecurringOccurrence(bill: bill, scheduled: bill.nextDate)
            let confirmation = PendingEntryConfirmation(entry: preview, data: ledger)
            let request = confirmation.request
            let changes: [(String, (inout MoneyRecurring) -> Void)] = [
                ("amount", { $0.amount += 1 }), ("account", { $0.accountID = nil }),
                ("category", { $0.categoryID = nil }), ("book", { $0.bookID = nil }),
                ("notes", { $0.notes = "Another window" }), ("rule", { $0.rule = "weekly" }),
                ("date", { $0.nextDate = $0.nextDate.addingTimeInterval(60) }),
                ("timezone", { $0.repeatTimeZoneID = "Europe/London" })
            ]
            for (label, change) in changes {
                var live = ledger; var updated = bill; change(&updated)
                live.recurring = [updated]
                let before = live
                try require(confirmation.occurrence?.bill == bill && confirmation.entry == preview,
                            "open confirmation retains its displayed amount and original rule through list refresh")
                try rejects("stale editor rejects changed \(label)") {
                    try request.apply(preview, to: &live, baseCurrency: ledger.baseCurrency)
                }
                try require(live == before, "rejected editor preserves the entire ledger and next date: \(label)")
                try rejects("quick confirm rejects changed \(label)") {
                    try live.postOccurrence(of: bill.id, scheduled: bill.nextDate, expected: bill)
                }
                try rejects("record today rejects changed \(label)") {
                    try live.postOccurrence(of: bill.id, scheduled: bill.nextDate, postedOn: day(2, 1), expected: bill)
                }
                try rejects("skip rejects changed \(label)") {
                    try live.skipOccurrence(of: bill.id, scheduled: bill.nextDate, expected: bill)
                }
                try require(live == before, "rejected quick actions leave balances, entries and rules unchanged: \(label)")
            }
            var stopped = ledger; stopped.stopRecurring(bill.id)
            let afterStop = stopped
            try rejects("stale confirmation cannot recreate a stopped rule") {
                try request.apply(preview, to: &stopped, baseCurrency: ledger.baseCurrency)
            }
            try require(stopped == afterStop, "stopped rule and entries remain untouched")

            var edited = preview; edited.amount += 10; edited.accountAmount = edited.amount; edited.baseAmount = edited.amount
            let draft = FinanceDraft(ledger: ledger, entry: edited, expected: nil, amount: Money.text(edited.amount),
                actual: Money.text(edited.accountAmount), received: "", fee: "", converted: Money.text(edited.amount),
                convertedFee: "", balance: 0, confirmingPending: true, occurrence: occurrence)
            var live = ledger; var newer = bill; newer.amount += 20
            try live.updateRecurring(newer, expected: bill)
            let before = live
            try rejects("recovered draft retains its original rule rather than adopting a newer baseline") {
                try draft.request.apply(draft.entry, to: &live, baseCurrency: ledger.baseCurrency)
            }
            try require(live == before && draft.entry.amount == edited.amount && draft.occurrence?.bill == bill,
                        "rejected recovery keeps both user input and newer data")

            var allowed = ledger
            allowed.books.append(MoneyBook(name: "Unrelated book"))
            try draft.request.apply(draft.entry, to: &allowed, baseCurrency: ledger.baseCurrency)
            try require(allowed.entries.count == 1 && allowed.entries[0].amount == edited.amount
                        && allowed.recurringBill(bill.id)?.amount == bill.amount
                        && allowed.recurringBill(bill.id)?.nextDate == bill.followingDate,
                        "unrelated edits and an intentional one-off amount remain allowed; advance exactly once")
            let once = allowed
            try rejects("retry after success cannot double post or advance twice") {
                try draft.request.apply(draft.entry, to: &allowed, baseCurrency: ledger.baseCurrency)
            }
            try require(allowed == once, "duplicate confirmation changes nothing")
            try confirmationPersistence(ledger: ledger, bill: bill, request: draft.request, require: require, rejects: rejects)
        }

        // A rule can reference a category before it has recorded its first entry.
        for _ in 0..<3 {
            for income in [false, true] {
                var values = FinanceData.initial
                let category = MoneyCategory(name: "Scheduled only", income: income)
                try values.updateCategory(category, expected: nil)
                var entry = rent; entry.accountID = nil; entry.accountAmount = 0
                entry.categoryID = category.id; entry.kind = income ? .income : .expense
                let rule = MoneyRecurring(repeating: entry, rule: "monthly", until: nil, in: values)
                try values.addRecurring(rule)
                let original = values
                try require(values.categoryTypeIsLocked(category.id), "the editor and data layer lock recurring-only category types")
                var flipped = category; flipped.income = !income
                try rejects("a recurring-only category cannot change income/expense type") {
                    try values.updateCategory(flipped, expected: category)
                }
                try require(values == original, "rejected category change leaves the entire ledger unchanged")
                var renamed = category; renamed.name = "Renamed"
                try values.updateCategory(renamed, expected: category)
                try require(values.recurringIssue(rule) == nil, "renaming a recurring category still works")
                var archived = renamed; archived.archived = true
                try values.updateCategory(archived, expected: renamed)
                try require(values.recurringIssue(rule) != nil, "archiving still surfaces a repairable issue")

                // Already mismatched data stays readable; the user can repair the rule.
                var mismatched = original
                mismatched.categories[mismatched.categories.firstIndex { $0.id == category.id }!] = flipped
                try mismatched.validate()
                try require(mismatched.recurringIssue(rule) != nil, "older mismatched rules show an issue before confirming")
                let before = mismatched
                try rejects("mismatched recurring preview cannot be quick-confirmed") {
                    try mismatched.postOccurrence(of: rule.id, scheduled: rule.nextDate)
                }
                try require(mismatched == before, "failed confirmation neither posts nor advances the rule")
                var repaired = rule; repaired.categoryID = nil
                try mismatched.updateRecurring(repaired, expected: rule)
                try mismatched.postOccurrence(of: rule.id, scheduled: rule.nextDate)
                try require(mismatched.entries.count == 1 && mismatched.entries[0].kind == entry.kind,
                            "repairing the category permits a single posting of the original kind")

                var stopped = original; stopped.stopRecurring(rule.id)
                try stopped.updateCategory(flipped, expected: category)
                let beforeStaleDraft = stopped
                try rejects("a category changed before a recurring draft saves cannot create a mismatched rule") {
                    try stopped.addRecurring(rule)
                }
                try require(stopped == beforeStaleDraft, "stale recurring creation leaves all data unchanged")
                var newRule = rule; newRule.kind = income ? .expense : .income
                try stopped.addRecurring(newRule)
                try rejects("editing a recurring rule cannot select a category of the opposite type") {
                    try stopped.updateRecurring(rule, expected: newRule)
                }
                try require(stopped.category(category.id)?.isIncome == !income,
                            "unused categories can still change type after their rule stops")
            }
        }

        for _ in 0..<3 {
            var preview = ledger.recurringPreviews[0]
            preview.amount = 3210; preview.accountAmount = 3210; preview.baseAmount = 3210
            preview.notes = "Kept after recovery"
            let occurrence = RecurringOccurrence(bill: bill, scheduled: bill.nextDate)
            let draft = FinanceDraft(ledger: ledger, entry: preview, expected: nil, amount: "3210", actual: "3210",
                received: "", fee: "", converted: "3210", convertedFee: "", balance: 0,
                confirmingPending: true, occurrence: occurrence)
            let request = draft.request
            try require(request.occurrence?.billID == bill.id && request.occurrence?.scheduled == bill.nextDate
                        && request.confirmingPending && request.expected == nil,
                        "restoring a recurring editor preserves its occurrence and confirmation intent")
            var restored = ledger
            try request.apply(request.entry, to: &restored, baseCurrency: ledger.baseCurrency)
            try require(restored.entries.count == 1 && restored.entries[0].amount == 3210
                        && restored.entries[0].notes == preview.notes && !restored.entries[0].isPending
                        && restored.recurringBill(bill.id)?.nextDate == day(2, 28),
                        "a recovered recurring draft posts once with edits and advances exactly one period")
            let once = restored
            try rejects("repeating a recovered confirmation does not advance a second period") {
                try request.apply(request.entry, to: &restored, baseCurrency: ledger.baseCurrency)
            }
            try require(restored == once, "duplicate confirmation leaves ledger unchanged")
            for stopped in [false, true] {
                var changed = ledger
                if stopped { changed.stopRecurring(bill.id) }
                else {
                    var moved = bill; moved.reschedule(to: day(2, 10))
                    try changed.updateRecurring(moved, expected: bill)
                }
                let before = changed
                try rejects("a recovered draft refuses a removed or rescheduled rule") {
                    try request.apply(request.entry, to: &changed, baseCurrency: ledger.baseCurrency)
                }
                try require(changed == before, "stale recurring drafts cannot create stray one-off entries")
            }
            // Occurrence IDs include time, so a same-day reschedule invalidates old confirmations and skips.
            for seconds in [1.0, 3600.0, -3600.0] {
                var changed = ledger
                var moved = bill; moved.reschedule(to: bill.nextDate.addingTimeInterval(seconds))
                try changed.updateRecurring(moved, expected: bill)
                let before = changed
                try rejects("same-day rescheduling invalidates a recovered confirmation") {
                    try request.apply(request.entry, to: &changed, baseCurrency: ledger.baseCurrency)
                }
                try rejects("same-day rescheduling invalidates an old skip") {
                    try changed.skipOccurrence(of: bill.id, scheduled: bill.nextDate)
                }
                try require(changed == before, "stale confirmation and skip preserve the new period and all entries")
                try changed.postOccurrence(of: bill.id, scheduled: moved.nextDate)
                try require(changed.entries.count == 1 && changed.entries[0].id == moved.entryID(for: moved.nextDate)
                    && changed.entries[0].date == moved.nextDate, "fresh confirmation keeps occurrence identity and date consistent")
            }
            var fractional = ledger
            try fractional.postOccurrence(of: bill.id, scheduled: bill.nextDate.addingTimeInterval(0.4))
            try require(fractional.entries.count == 1, "subsecond rounding agrees with existing occurrence identity")
            let baseline = TaskBackup(finance: ledger, lists: [], tasks: [])
            var local = ledger, remote = ledger
            try request.apply(request.entry, to: &local, baseCurrency: ledger.baseCurrency)
            try request.apply(request.entry, to: &remote, baseCurrency: ledger.baseCurrency)
            let left = TaskBackup(finance: local, lists: [], tasks: [])
            var right = TaskBackup(finance: remote, lists: [], tasks: [])
            let merged = try CloudMerge.merge(local: left, cloud: right, base: baseline)
            try require(merged.finance?.entries.count == 1 && merged.finance?.balance(card.id) == -3210
                && merged.finance?.recurringBill(bill.id)?.nextDate == bill.followingDate,
                "two devices confirming a recovered occurrence merge into one debit and one period advance")
            remote = ledger
            var otherAmount = request.entry; otherAmount.amount = 3300; otherAmount.accountAmount = 3300; otherAmount.baseAmount = 3300
            try request.apply(otherAmount, to: &remote, baseCurrency: ledger.baseCurrency)
            right = TaskBackup(finance: remote, lists: [], tasks: [])
            try rejects("different simultaneous occurrence amounts require review") {
                _ = try CloudMerge.merge(local: left, cloud: right, base: baseline)
            }
            for choice in [CloudMerge.Choice.local, .cloud] {
                let selected = try CloudMerge.merge(local: left, cloud: right, base: baseline, choice: choice)
                try require(selected.finance?.entries.count == 1 && selected.finance?.balance(card.id) == (choice == .local ? -3210 : -3300),
                    "either conflict choice retains exactly one posting")
            }
            var future = ledger
            var futureBill = bill; futureBill.reschedule(to: day(1, 31, year: 2035))
            try future.updateRecurring(futureBill, expected: bill)
            var futureDraft = draft
            futureDraft.entry = future.recurringPreviews[0]
            futureDraft.occurrence = .init(bill: futureBill, scheduled: futureBill.nextDate)
            try futureDraft.request.apply(futureDraft.entry, to: &future, baseCurrency: ledger.baseCurrency)
            try require(future.entries.count == 1 && future.recurringBill(bill.id)?.nextDate == day(2, 28, year: 2035),
                        "recovering an early confirmation keeps the explicitly chosen future occurrence")

            var ordinary = ledger
            var oneOff = rent; oneOff.pending = true
            let create = EntryRequest(entry: oneOff, expected: nil)
            try create.apply(oneOff, to: &ordinary, baseCurrency: ledger.baseCurrency)
            let stored = ordinary.entries[0]
            var ordinaryDraft = draft
            ordinaryDraft.entry = stored; ordinaryDraft.expected = stored; ordinaryDraft.occurrence = nil
            try ordinaryDraft.request.apply(stored, to: &ordinary, baseCurrency: ledger.baseCurrency)
            try require(ordinary.entries.count == 1 && !ordinary.entries[0].isPending && ordinary.recurringBill(bill.id) == bill,
                        "a recovered ordinary pending entry confirms without advancing an unrelated recurring bill")
            var changedEntry = ordinary.entries[0]; changedEntry.title = "Edited receipt"
            let edit = EntryRequest(entry: changedEntry, expected: ordinary.entries[0])
            try edit.apply(changedEntry, to: &ordinary, baseCurrency: ledger.baseCurrency)
            try require(ordinary.entries[0].title == "Edited receipt" && ordinary.entries.count == 1,
                        "the shared request keeps normal existing-entry edits unchanged")
        }

        // Only the rule is stored; the next occurrence is a preview.
        try require(ledger.entries.isEmpty, "creating a bill stores no entry")
        let preview = ledger.recurringPreviews.first
        try require(ledger.recurringPreviews.count == 1 && preview?.isPending == true && preview?.id == bill.entryID(for: day(1, 31))
                    && preview?.amount == 3200 && Dates.sameDay(preview!.date, day(1, 31)), "the next occurrence is shown as a pending preview")

        // Confirming records the occurrence and moves to the next one; a 31st stays at month end.
        var posted = ledger
        try posted.postOccurrence(of: bill.id, scheduled: day(1, 31))
        let recorded = posted.entries.first
        try require(posted.entries.count == 1 && recorded?.id == bill.entryID(for: day(1, 31)) && recorded?.isPending == false
                    && recorded?.recurringID == bill.id, "confirming records one posted entry")
        try require(posted.recurringBill(bill.id)?.nextDate == day(2, 28), "the next date follows the rule to the end of a short month")
        try posted.postOccurrence(of: bill.id, scheduled: day(2, 28))
        try require(posted.recurringBill(bill.id)?.nextDate == day(3, 31), "a month-end bill returns to the 31st")
        try rejects("an occurrence cannot be confirmed twice") { var again = posted; try again.postOccurrence(of: bill.id, scheduled: day(2, 28)) }

        // Two devices confirming the same occurrence agree, and an already recorded occurrence is not previewed.
        var mac = ledger, phone = ledger
        try mac.postOccurrence(of: bill.id, scheduled: day(1, 31)); try phone.postOccurrence(of: bill.id, scheduled: day(1, 31))
        try require(mac == phone, "two devices confirming one occurrence produce the same entry and next date")
        var synced = ledger; synced.entries = mac.entries
        try require(synced.recurringPreviews.isEmpty, "an occurrence recorded on another device is not shown again")

        // Recording today keeps the occurrence's identity; skipping records nothing.
        var today = ledger
        try today.postOccurrence(of: bill.id, scheduled: day(1, 31), postedOn: day(2, 3))
        try require(today.entries.first?.id == bill.entryID(for: day(1, 31)) && Dates.sameDay(today.entries.first!.date, day(2, 3)),
                    "recording today dates the entry today but keeps the occurrence it settles")
        var skipped = ledger
        try skipped.skipOccurrence(of: bill.id, scheduled: day(1, 31))
        try require(skipped.entries.isEmpty && skipped.recurringBill(bill.id)?.nextDate == day(2, 28), "skipping moves on without recording")
        try require(bill.entryID(for: day(1, 31)) == bill.entryID(for: day(1, 31).addingTimeInterval(0.4))
                    && bill.entryID(for: day(1, 31)) != bill.entryID(for: day(1, 31, hour: 11)),
                    "an occurrence is identified by its moment, so devices in other time zones agree")

        // A deleted confirmation does not hold its occurrence: moving back to it shows it again, and confirming replaces it.
        var redo = ledger
        try redo.postOccurrence(of: bill.id, scheduled: day(1, 31))
        try redo.trash(redo.entries[0])
        var back = redo.recurringBill(bill.id)!; back.reschedule(to: day(1, 31))
        try redo.updateRecurring(back, expected: redo.recurringBill(bill.id)!)
        try require(redo.recurringPreviews.count == 1, "moving back to a deleted occurrence shows it again")
        try redo.postOccurrence(of: bill.id, scheduled: day(1, 31))
        try require(redo.entries.count == 1 && redo.entries[0].deletedAt == nil && redo.recurringBill(bill.id)?.nextDate == day(2, 28),
                    "confirming it again replaces the deleted entry")

        // An archived category or book is reported on the bill; confirming as it stands is refused, skipping still works.
        var archived = ledger
        var category = archived.categories.first { $0.id == bill.categoryID }!; category.archived = true
        try archived.updateCategory(category, expected: archived.categories.first { $0.id == bill.categoryID })
        try require(archived.recurringIssue(archived.recurringBill(bill.id)!) != nil && ledger.recurringIssue(bill) == nil,
                    "an archived category is reported on the bill")
        try rejects("an archived category blocks confirming as it stands") { var copy = archived; try copy.postOccurrence(of: bill.id, scheduled: day(1, 31)) }
        var skipArchived = archived
        try skipArchived.skipOccurrence(of: bill.id, scheduled: day(1, 31))
        try require(skipArchived.recurringBill(bill.id)?.nextDate == day(2, 28), "an occurrence can still be skipped")
        var recategorized = archived.recurringBill(bill.id)!; recategorized.categoryID = nil
        try archived.updateRecurring(recategorized, expected: archived.recurringBill(bill.id)!)
        try archived.postOccurrence(of: bill.id, scheduled: day(1, 31))
        try require(archived.entries.count == 1, "after editing the bill it can be confirmed")
        var shelved = ledger
        try shelved.updateBook(MoneyBook(name: "Trip"), expected: nil, baseCurrency: shelved.baseCurrency)
        var oldBook = shelved.books.first { $0.id == book }!; oldBook.archived = true
        try shelved.updateBook(oldBook, expected: shelved.books.first { $0.id == book }, baseCurrency: shelved.baseCurrency)
        try require(shelved.recurringIssue(bill) != nil, "an archived book is reported on the bill")
        try rejects("an archived book blocks confirming, as for any pending entry") {
            var copy = shelved; try copy.postOccurrence(of: bill.id, scheduled: day(1, 31), entry: shelved.occurrenceEntry(bill, on: day(1, 31)))
        }

        // Editing changes only the rule; recorded entries stay; the next date sets the day of month.
        var edited = posted
        var weekly = edited.recurringBill(bill.id)!; weekly.rule = "weekly"
        try edited.updateRecurring(weekly, expected: posted.recurringBill(bill.id)!)
        try require(edited.entries == posted.entries && edited.recurringPreviews.count == 1, "editing a rule never adds or changes entries")
        var moved = edited.recurringBill(bill.id)!; moved.rule = "monthly"; moved.reschedule(to: day(4, 15))
        try edited.updateRecurring(moved, expected: edited.recurringBill(bill.id)!)
        try require(edited.recurringBill(bill.id)?.anchorDay == 15 && edited.recurringBill(bill.id)?.scheduleLabel == L("每月 15 日", "Monthly on day 15"),
                    "the next date decides the day of month")
        try edited.postOccurrence(of: bill.id, scheduled: day(4, 15))
        try require(edited.recurringBill(bill.id)?.nextDate == day(5, 15), "a moved bill continues from its new day")

        // An end date finishes the bill after its last occurrence; stopping keeps recorded entries.
        var ending = ledger
        var limited = bill; limited.until = day(2, 28, hour: 0)
        try ending.updateRecurring(limited, expected: bill)
        try ending.postOccurrence(of: bill.id, scheduled: day(1, 31)); try ending.postOccurrence(of: bill.id, scheduled: day(2, 28))
        try require(ending.recurring == nil && ending.entries.count == 2 && (try? ending.validate()) != nil, "the last occurrence ends the bill")
        var stopped = posted
        stopped.stopRecurring(bill.id)
        try require(stopped.recurring == nil && stopped.entries == posted.entries && stopped.recurringPreviews.isEmpty, "stopping keeps every recorded entry")

        // An existing entry becomes the first occurrence of a new bill without being copied.
        var converted = FinanceData.initial
        converted.accounts = [card]
        var lunch = rent; lunch.id = UUID(); lunch.title = "Lunch"; lunch.date = day(3, 9)
        converted.entries = [lunch]
        let draft = converted.recurringDraft(from: lunch)
        try require(draft.rule == "monthly" && draft.nextDate == day(4, 9), "a draft starts one period after the entry")
        try converted.makeRecurring(draft, from: lunch.id)
        try require(converted.entries.count == 1 && converted.entries[0].recurringID == draft.id
                    && converted.recurringPreviews.first.map { Dates.sameDay($0.date, day(4, 9)) } == true, "the entry is linked, not copied")
        try rejects("an entry already in a bill cannot start another") { try converted.makeRecurring(converted.recurringDraft(from: converted.entries[0]), from: lunch.id) }
        try require(MoneyRecurring.inferredRule(from: [day(1, 31), day(2, 28), day(3, 31)]) == "monthly"
                    && MoneyRecurring.inferredRule(from: [day(3, 1), day(3, 8), day(3, 15)]) == "weekly"
                    && MoneyRecurring.inferredRule(from: [day(3, 1), day(3, 15), day(3, 29)]) == RepeatRule(interval: 2, unit: .week).text
                    && MoneyRecurring.inferredRule(from: [day(3, 1)]) == "monthly", "a stopped series' rule is inferred from its dates")

        // A foreign bill on a base-currency card keeps the planned charge as its conversion.
        var travel = FinanceData.initial
        let cny = MoneyAccount(name: "CNY card"); travel.accounts = [cny]
        var gym = MoneyEntry(); gym.title = "Gym"; gym.date = day(3, 1); gym.currency = "AUD"; gym.amount = 50
        gym.accountID = cny.id; gym.accountAmount = 235; gym.baseAmount = 235; gym.bookID = travel.books[0].id
        let gymBill = MoneyRecurring(repeating: gym, rule: "monthly", until: nil, in: travel)
        try travel.addRecurring(gymBill)
        try travel.postOccurrence(of: gymBill.id, scheduled: day(3, 1))
        try require(travel.entries.first?.accountAmount == 235 && travel.entries.first?.baseAmount == 235 && (try? travel.validate()) != nil,
                    "a foreign occurrence records its planned charge")

        // Invalid bills are refused; referenced items cannot be deleted.
        try rejects("transfers cannot repeat") { var bad = bill; bad.kind = .transfer; try bad.validate(in: ledger) }
        try rejects("a bill needs an amount") { var bad = bill; bad.amount = 0; try bad.validate(in: ledger) }
        try rejects("a bill needs an existing book") { var bad = bill; bad.bookID = UUID(); try bad.validate(in: ledger) }
        try rejects("a foreign account needs a planned amount") { var bad = gymBill; bad.accountAmount = 0; try bad.validate(in: travel) }
        try rejects("an end before the next date is refused") { var bad = bill; bad.until = day(1, 1); try bad.validate(in: ledger) }
        try rejects("an unknown rule is refused") { var bad = bill; bad.rule = "sometimes"; try bad.validate(in: ledger) }
        try require(ledger.removalBlock(.account, id: card.id) != nil && !ledger.canChangeBaseCurrency, "a bill holds its account and the base currency")
        try require(posted.copyEntry(recorded!).recurringID == nil, "a copied entry is a one-off")

        // Bills from earlier builds: untouched stored occurrences become the next date; confirmed and edited entries stay.
        func legacyLedger(_ entries: [MoneyEntry], start: Date, activeFrom: Date) throws -> FinanceData {
            var old = FinanceData.initial; old.accounts = [card]; old.entries = entries
            old.recurring = [bill]
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
            var bills = json["recurring"] as! [[String: Any]]
            bills[0]["nextDate"] = nil; bills[0]["paused"] = false
            bills[0]["start"] = start.timeIntervalSinceReferenceDate; bills[0]["activeFrom"] = activeFrom.timeIntervalSinceReferenceDate
            json["recurring"] = bills
            return try JSONDecoder().decode(FinanceData.self, from: JSONSerialization.data(withJSONObject: json))
        }
        func stored(_ date: Date) -> MoneyEntry {
            var entry = ledger.occurrenceEntry(bill, on: date)!; entry.id = bill.legacyEntryID(on: date); entry.pending = true; return entry
        }
        var confirmedOld = stored(day(1, 31)); confirmedOld.pending = nil
        var editedOld = stored(day(2, 28)); editedOld.notes = "Agreed with landlord"
        var migrated = try legacyLedger([confirmedOld, editedOld, stored(day(3, 31)), stored(day(4, 30))], start: day(1, 31), activeFrom: day(1, 31, hour: 0))
        migrated.migrateLegacyRecurring()
        try require(migrated.recurringBill(bill.id)?.nextDate == day(3, 31) && migrated.recurringBill(bill.id)?.legacy == nil
                    && migrated.entries.map(\.id) == [confirmedOld.id, editedOld.id], "untouched stored occurrences become previews; others stay")
        var caughtUp = try legacyLedger([confirmedOld], start: day(1, 31), activeFrom: day(1, 31, hour: 0))
        caughtUp.migrateLegacyRecurring()
        try require(caughtUp.recurringBill(bill.id)?.nextDate == day(2, 28), "with nothing stored, the bill continues after its latest entry")
        try require(try JSONDecoder().decode(FinanceData.self, from: JSONEncoder().encode(caughtUp)) == caughtUp, "a migrated bill round-trips")

        // Storage and sync.
        try require(!String(decoding: try JSONEncoder().encode(FinanceData.initial), as: UTF8.self).contains("recurring"), "a ledger without bills stores no bill field")
        let base = TaskBackup(finance: ledger, lists: [], tasks: [])
        var cloudOnly = base; cloudOnly.finance!.stopRecurring(bill.id)
        try require(try CloudMerge.merge(local: base, cloud: base, base: cloudOnly).finance?.recurringBill(bill.id) == bill, "a new bill merges into the other device")
        var left = base, right = base
        var higher = bill; higher.amount = 3300; var lower = bill; lower.amount = 3100
        try left.finance!.updateRecurring(higher, expected: bill); try right.finance!.updateRecurring(lower, expected: bill)
        try rejects("different amounts for one bill need review") { _ = try CloudMerge.merge(local: left, cloud: right, base: base) }
        var confirmedRemote = base
        try confirmedRemote.finance!.postOccurrence(of: bill.id, scheduled: day(1, 31))
        let combined = try CloudMerge.merge(local: left, cloud: confirmedRemote, base: base)
        try require(combined.finance?.recurringBill(bill.id)?.amount == 3300 && combined.finance?.recurringBill(bill.id)?.nextDate == day(2, 28)
                    && combined.finance?.entries.count == 1, "confirming on one device and editing on another merge without review")
        var shortened = base, advanced = base
        var endsEarlier = bill; endsEarlier.until = day(2, 10)
        try shortened.finance!.updateRecurring(endsEarlier, expected: bill)
        try advanced.finance!.postOccurrence(of: bill.id, scheduled: day(1, 31))
        try rejects("changing the end and advancing concurrently requires a whole-schedule review") {
            _ = try CloudMerge.merge(local: shortened, cloud: advanced, base: base)
        }
        for choice in [CloudMerge.Choice.local, .cloud] {
            let selected = try CloudMerge.merge(local: shortened, cloud: advanced, base: base, choice: choice)
            // The chosen cutoff has no unpaid occurrence after the separately confirmed January entry.
            let expected = choice == .local ? nil : advanced.finance!.recurringBill(bill.id)
            try require(selected.finance?.recurringBill(bill.id) == expected && selected.finance?.entries.count == 1,
                        "review keeps the posting and ends a chosen schedule with no unpaid occurrences before its cutoff")
        }
        try scheduleConcurrency(ledger: ledger, bill: bill, require: require)
        for _ in 0..<3 { try ruleDraftRecovery(ledger: ledger, bill: bill, require: require, rejects: rejects) }
        let items = try CloudRecordCodec.items(left)
        try require(items[SyncChanges.key("recurring", bill.id)] != nil
                    && (try CloudMerge.bytes(CloudRecordCodec.snapshot(items))) == CloudMerge.bytes(left), "bills sync as their own records")
    }
    private static func scheduleConcurrency(ledger: FinanceData, bill: MoneyRecurring,
                                            require: (Bool, String) throws -> Void) throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let a = UUID(), b = UUID()
        let key = SyncChanges.key("recurring", bill.id)
        func tracked(_ ledger: FinanceData, from previous: TaskBackup?, actor: UUID?) throws -> TaskBackup {
            var value = TaskBackup(finance: ledger, lists: [], tasks: [])
            var revisions = previous?.syncChanges ?? [:]
            let before = try previous.map(SyncChanges.fingerprints) ?? [:], after = try SyncChanges.fingerprints(value)
            var changes: [String: String?] = [:]
            for key in Set(before.keys).union(after.keys) where before[key] != after[key] { changes[key] = .some(after[key]) }
            SyncChanges.record(changes, in: &revisions, now: now, fieldFingerprints: try SyncFields.snapshot(value),
                previousFieldFingerprints: try previous.map(SyncFields.snapshot) ?? [:],
                createdKeys: Set(after.keys).subtracting(before.keys), actor: actor, previousFingerprints: before)
            value.syncChanges = revisions
            return value
        }
        func needsReview(_ local: TaskBackup, _ cloud: TaskBackup, _ base: TaskBackup?) throws {
            let outcome = Result { try CloudMerge.merge(local: local, cloud: cloud, base: base, now: now) }
            switch outcome {
            case .success:
                try require(false, "different concurrent schedules must not merge without review")
            case .failure(let error):
                guard let conflict = error as? CloudMerge.Conflict else { throw error }
                try require(conflict.items.count == 1 && conflict.items.first?.id == key,
                            "different concurrent schedules require one review item")
                try require(conflict.items.first?.detail.contains(L("下一期", "Next")) == true,
                            "review shows both next dates")
            }
        }
        for _ in 0..<3 {
            // Cover old snapshots, timestamp-only history and genuine two-device revision clocks.
            for mode in 0..<3 {
                func snapshot(_ data: FinanceData, previous: TaskBackup?, actor: UUID) throws -> TaskBackup {
                    mode == 0 ? TaskBackup(finance: data, lists: [], tasks: [])
                        : try tracked(data, from: previous, actor: mode == 2 ? actor : nil)
                }
                let base = try snapshot(ledger, previous: nil, actor: a)
                var confirmed = ledger
                try confirmed.postOccurrence(of: bill.id, scheduled: bill.nextDate, expected: bill)
                let right = try snapshot(confirmed, previous: base, actor: b)
                var weeklyLedger = ledger, weekly = bill
                weekly.rule = "weekly"
                try weeklyLedger.updateRecurring(weekly, expected: bill)
                let weeklySnapshot = try snapshot(weeklyLedger, previous: base, actor: a)
                for (local, cloud, choice) in [(weeklySnapshot, right, CloudMerge.Choice.local),
                                               (right, weeklySnapshot, CloudMerge.Choice.cloud)] {
                    try needsReview(local, cloud, base)
                    let resolved = try CloudMerge.merge(local: local, cloud: cloud, base: base,
                                                       choices: [key: choice], now: now)
                    try require(resolved.finance?.recurringBill(bill.id)?.nextDate == weekly.followingDate
                                && resolved.finance?.recurringBill(bill.id)?.rule == "weekly"
                                && resolved.finance?.recurringPreviews.count == 1
                                && resolved.finance?.entries == confirmed.entries,
                                "chosen weekly schedule passes the confirmed occurrence without losing or reposting it")
                    for stale in [local, cloud] {
                        try require(try CloudMerge.merge(local: resolved, cloud: stale, base: base, now: now).finance == resolved.finance,
                                    "adjusted schedule survives either stale device and lost-response retries")
                    }
                }
                var edited = ledger, moved = bill
                let calendar = bill.recurrenceCalendar!
                let february15 = calendar.date(bySetting: .day, value: 15, of: bill.followingDate!)!
                moved.reschedule(to: february15)
                try edited.updateRecurring(moved, expected: bill)
                let left = try snapshot(edited, previous: base, actor: a)
                for (local, cloud) in [(left, right), (right, left)] {
                    try needsReview(local, cloud, base)
                    try needsReview(local, cloud, nil)
                    for choice in [CloudMerge.Choice.local, .cloud] {
                        let expected = (choice == .local ? local : cloud).finance!.recurringBill(bill.id)!
                        let result = try CloudMerge.merge(local: local, cloud: cloud, base: base,
                                                         choices: [key: choice], now: now)
                        try require(result.finance?.recurringBill(bill.id) == expected,
                                    "manual choice includes next date, anchor, frequency, end and timezone")
                        try require(result.finance?.entries == confirmed.entries
                                    && result.finance?.balance(ledger.accounts[0].id) == confirmed.balance(ledger.accounts[0].id),
                                    "schedule review neither removes nor duplicates the confirmed posting")
                        try require(result.finance?.recurringPreviews.count == 1,
                                    "review leaves exactly one future preview")
                        // A lost response/repeated fetch must not undo a confirmed choice or double post.
                        for stale in [local, cloud] {
                            let replay = try CloudMerge.merge(local: result, cloud: stale, base: base, now: now)
                            try require(replay.finance == result.finance, "resolved schedule survives replay of either stale device")
                        }
                        let repeated = try CloudMerge.merge(local: local, cloud: cloud, base: base,
                                                           choices: [key: choice], now: now)
                        try require(repeated.finance == result.finance, "retrying the same review produces the same ledger")
                    }
                }
                let alsoConfirmed = try snapshot(confirmed, previous: base, actor: a)
                let same = try CloudMerge.merge(local: alsoConfirmed, cloud: right, base: base, now: now)
                try require(same.finance == confirmed, "two devices confirming the same occurrence post once and advance once")
                var skipped = ledger
                try skipped.skipOccurrence(of: bill.id, scheduled: bill.nextDate, expected: bill)
                let skip = try snapshot(skipped, previous: base, actor: a)
                let skipConfirm = try CloudMerge.merge(local: skip, cloud: right, base: base, now: now)
                try require(skipConfirm.finance == confirmed, "skip never deletes a confirmed posting and advances only once")
                let unchanged = try CloudMerge.merge(local: left, cloud: base, base: base, now: now)
                try require(unchanged.finance == edited, "one-device rescheduling remains automatic")
                let sameMove = try snapshot(edited, previous: base, actor: b)
                try require(try CloudMerge.merge(local: left, cloud: sameMove, base: base, now: now).finance == edited,
                            "identical rescheduling remains automatic")
                if mode == 2 {
                    var observed = confirmed
                    var laterRule = observed.recurringBill(bill.id)!
                    laterRule.reschedule(to: february15)
                    try observed.updateRecurring(laterRule, expected: observed.recurringBill(bill.id)!)
                    let later = try snapshot(observed, previous: right, actor: a)
                    try require(try CloudMerge.merge(local: later, cloud: right, base: base, now: now).finance == observed,
                                "an edit made after observing confirmation remains automatic")
                }
            }
        }
        var recorded = ledger
        for _ in 0..<3 {
            let next = recorded.recurringBill(bill.id)!
            try recorded.postOccurrence(of: bill.id, scheduled: next.nextDate, expected: next)
        }
        let postings = recorded.entries, expectedNext = recorded.recurringBill(bill.id)!.nextDate
        recorded.recurring = [bill]
        try recorded.advanceRecordedRecurringOccurrences()
        try require(recorded.entries == postings && recorded.recurringBill(bill.id)?.nextDate == expectedNext,
                    "three consecutive posted occurrences are bypassed without changing money")
        let once = recorded
        try recorded.advanceRecordedRecurringOccurrences()
        try require(recorded == once, "reconciling a schedule twice is idempotent")
        var ended = bill; ended.until = bill.nextDate
        recorded.recurring = [ended]
        try recorded.advanceRecordedRecurringOccurrences()
        try require(recorded.recurringBills.isEmpty && recorded.entries == postings,
                    "an already confirmed final occurrence ends the rule and keeps all postings")
        recorded.recurring = [bill]
        let first = recorded.entries.first { $0.id == bill.entryID(for: bill.nextDate) }!
        try recorded.trash(first)
        let trashed = recorded
        try recorded.advanceRecordedRecurringOccurrences()
        try require(recorded == trashed && recorded.recurringPreviews.count == 1,
                    "a deleted confirmation is not silently treated as a paid occurrence")
        var pending = ledger
        var pendingEntry = ledger.occurrenceEntry(bill, on: bill.nextDate)!
        pendingEntry.pending = true; pending.entries = [pendingEntry]
        let pendingBefore = pending
        try pending.advanceRecordedRecurringOccurrences()
        try require(pending == pendingBefore, "a stored pending entry does not advance the rule")
    }

    private static func ruleDraftRecovery(ledger: FinanceData, bill: MoneyRecurring,
                                          require: (Bool, String) throws -> Void,
                                          rejects: (String, () throws -> Void) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Tally-RuleDraft-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.store")
        let initial = try Store.make(url: url)
        try FinanceStore.update(initial.mainContext) { $0 = ledger }
        let drafts = EditorDrafts()
        let originalDraft = FinanceRecurringDraft(original: bill, source: nil, bill: bill,
                                                 amount: Money.text(bill.amount), accountAmount: "")
        try require(!originalDraft.dirty, "opening a rule does not count as an edit")
        var draft = originalDraft
        draft.amount = "004321.00"; draft.bill.notes = "Unsaved rule note"
        drafts.financeRecurring = draft
        let oldGeneration = Store.recovery.generation
        let schema = Schema([TaskItem.self, TaskList.self, FinanceLedger.self, CloudSyncState.self, CalendarWeekTitle.self])
        for _ in 0..<2 {
            let readOnly = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url,
                allowsSave: false, cloudKitDatabase: .none)])
            readOnly.mainContext.autosaveEnabled = false
            try rejects("rule save failure keeps original durable data") {
                try FinanceStore.update(readOnly.mainContext) { try draft.apply(to: &$0) }
            }
            drafts.clearRecurringDraft(id: bill.id, generation: Store.recovery.generation)
            try require(drafts.financeRecurring == draft && Store.recovery.failure != nil,
                        "disappearing while save failed retains exact input and baseline")
            try require(Store.recovery.reload(), "rule failure reloads the isolated store")
            drafts.clearRecurringDraft(id: bill.id, generation: oldGeneration)
            try require(drafts.financeRecurring == draft && drafts.financeRecurring?.request.bill == bill,
                        "retired editor cannot erase or refresh the recovery draft")
            try require(try FinanceStore.read(Store.recovery.container!.mainContext) == ledger,
                        "failed rule edit leaves no partial data")
        }
        let fresh = Store.recovery.container!.mainContext
        try FinanceStore.update(fresh) { try drafts.financeRecurring!.apply(to: &$0) }
        let reopened = try Store.make(url: url)
        let saved = try FinanceStore.read(reopened.mainContext)!
        try require(saved.recurringBill(bill.id)?.amount == 4321 && saved.recurringBill(bill.id)?.notes == draft.bill.notes
                    && saved.entries == ledger.entries && saved.recurringBill(bill.id)?.nextDate == bill.nextDate,
                    "recovered rule saves only edited fields without recording or advancing an occurrence")
        try rejects("repeating a successful rule save cannot overwrite the new revision") {
            try FinanceStore.update(reopened.mainContext) { try draft.apply(to: &$0) }
        }
        var changed = ledger, other = bill; other.reschedule(to: bill.followingDate!)
        try changed.updateRecurring(other, expected: bill)
        let before = changed
        try rejects("draft cannot overwrite another device's reschedule") { try draft.apply(to: &changed) }
        try require(changed == before && drafts.financeRecurring == draft, "stale rejection preserves both drafts and saved edits")
        changed.stopRecurring(bill.id)
        let stopped = changed
        try rejects("recovered draft cannot recreate a stopped rule") { try draft.apply(to: &changed) }
        try require(changed == stopped, "stopped rule remains stopped")
        drafts.clearRecurringDraft(id: UUID(), generation: Store.recovery.generation)
        try require(drafts.financeRecurring != nil, "another editor cannot clear this draft")
        drafts.clearRecurringDraft(id: bill.id, generation: Store.recovery.generation)
        try require(drafts.financeRecurring == nil, "save or explicit discard clears the current draft")
        var invalid = originalDraft; invalid.amount = "invalid"
        var untouched = ledger
        try rejects("invalid recovered amount is not silently normalized") { try invalid.apply(to: &untouched) }
        try require(untouched == ledger, "invalid input does not mutate the ledger")
        var sourceLedger = ledger
        try sourceLedger.postOccurrence(of: bill.id, scheduled: bill.nextDate, expected: bill)
        sourceLedger.stopRecurring(bill.id)
        let source = sourceLedger.entries[0], newRule = sourceLedger.recurringDraft(from: sourceLedger.entries[0])
        let creating = FinanceRecurringDraft(original: newRule, source: source, bill: newRule,
                                            amount: Money.text(newRule.amount), accountAmount: "")
        sourceLedger.entries[0].notes = "Changed elsewhere"
        let changedSource = sourceLedger
        try rejects("recovered Make recurring checks the original entry version") { try creating.apply(to: &sourceLedger) }
        try require(sourceLedger == changedSource, "a changed source entry is never relinked by an old draft")
        sourceLedger.entries[0] = source
        try creating.apply(to: &sourceLedger)
        let once = sourceLedger
        try rejects("Make recurring retry after success cannot create a second rule") { try creating.apply(to: &sourceLedger) }
        try require(sourceLedger == once && sourceLedger.entries.count == 1, "creating a rule retains its original posting once")
    }

    private static func confirmationPersistence(ledger: FinanceData, bill: MoneyRecurring, request: EntryRequest,
                                                require: (Bool, String) throws -> Void,
                                                rejects: (String, () throws -> Void) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Tally-RecurringConfirm-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.store")
        let db = try Store.make(url: url)
        try FinanceStore.update(db.mainContext) { $0 = ledger }
        let original = try FinanceStore.read(db.mainContext)!
        try rejects("interruption after staging does not commit an occurrence") {
            try Store.discardingOnFailure(db.mainContext) {
                var value = original
                try request.apply(request.entry, to: &value, baseCurrency: original.baseCurrency)
                try FinanceStore.stage(value, in: db.mainContext)
                throw TaskBackup.invalid("Injected interruption before commit")
            }
        }
        try require(try !db.mainContext.hasChanges && FinanceStore.read(db.mainContext) == original,
                    "staging interruption restores the full ledger")
        let schema = Schema([TaskItem.self, TaskList.self, FinanceLedger.self, CloudSyncState.self, CalendarWeekTitle.self])
        let readOnly = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url,
            allowsSave: false, cloudKitDatabase: .none)])
        readOnly.mainContext.autosaveEnabled = false
        try rejects("real SQLite save rejection does not post or advance") {
            try FinanceStore.update(readOnly.mainContext) {
                try request.apply(request.entry, to: &$0, baseCurrency: original.baseCurrency)
            }
        }
        try require(Store.recovery.failure != nil && Store.recovery.reload(), "failed save reloads committed data for retry")
        let reopened = try Store.make(url: url)
        try require(try FinanceStore.read(reopened.mainContext) == original, "reopening after failure sees no partial posting")
        try FinanceStore.update(reopened.mainContext) {
            try request.apply(request.entry, to: &$0, baseCurrency: original.baseCurrency)
        }
        let verified = try Store.make(url: url)
        let result = try FinanceStore.read(verified.mainContext)!
        try require(result.entries.count == 1 && result.entries[0].amount == request.entry.amount
                    && result.recurringBill(bill.id)?.nextDate == bill.followingDate,
                    "same restored request retries successfully once after a write failure")
        try rejects("second window cannot confirm the already committed occurrence") {
            try FinanceStore.update(verified.mainContext) {
                try request.apply(request.entry, to: &$0, baseCurrency: original.baseCurrency)
            }
        }
        try require(try FinanceStore.read(verified.mainContext) == result, "second-window rejection preserves committed data")
    }

}
