import Foundation

/// A repeating income or expense, such as rent, a subscription or a salary. A bill keeps only its rule and the
/// date of its next occurrence; the pending list shows that occurrence as a preview computed from the rule, the
/// way Actual Budget treats schedules. Nothing is stored until an occurrence is confirmed, so editing a bill only
/// edits the rule and can never leave a stale copy behind. A confirmed occurrence's entry ID derives from the bill
/// and the scheduled moment, so two devices confirming the same occurrence produce one entry after sync.
struct MoneyRecurring: Identifiable, Equatable {
    var id = UUID()
    var kind: MoneyKind = .expense
    var title: String
    var amount: Decimal
    var currency: String
    var accountID: UUID?
    /// The planned amount in the account's currency, when it differs from the bill's currency.
    var accountAmount: Decimal = 0
    /// The planned conversion, used only when neither the bill nor its account uses the base currency.
    var baseAmount: Decimal?
    var bookID: UUID?
    var categoryID: UUID?
    var notes = ""
    var tags = ""
    /// A `RepeatRule` text, the same rules tasks use.
    var rule: String
    /// Day of month kept by monthly and yearly rules when a month is shorter (31 → 28/29/30).
    var anchorDay: Int
    /// The next occurrence not yet confirmed or skipped; its time of day is kept by later ones.
    var nextDate: Date
    var until: Date?
    /// Nil means an older rule whose original time zone has not been confirmed.
    var repeatTimeZoneID: String? = nil
    /// Only on a bill read from an earlier format, until `FinanceData.migrateLegacyRecurring` settles it. Never written.
    var legacy: Legacy? = nil

    /// What an earlier build stored: the first occurrence and the first day it still generated entries for.
    struct Legacy: Equatable {
        var start: Date
        var activeFrom: Date
    }

    static let maximumCount = 200

    /// The stable identity of the entry confirming the occurrence scheduled at `date`. It uses the moment, not the
    /// calendar day, so devices in different time zones agree on it.
    func entryID(for date: Date) -> UUID {
        TaskItem.syncIdentity("money-recurring:" + id.uuidString + "@" + String(Int64(MoneyEntry.timestamp(date).timeIntervalSince1970)))
    }
    /// The identity earlier builds gave a stored occurrence, by calendar day. Only used to recognize them when migrating.
    func legacyEntryID(on date: Date, calendar: Calendar = Dates.calendar) -> UUID {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        let text = String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
        return TaskItem.syncIdentity("money-recurring:" + id.uuidString + ":" + text)
    }

    var recurrenceCalendar: Calendar? {
        repeatTimeZoneID == nil ? Dates.calendar : Dates.recurrenceCalendar(timeZoneID: repeatTimeZoneID)
    }

    /// The occurrence after the next one, or nil once the bill has ended.
    var followingDate: Date? {
        guard let calendar = recurrenceCalendar else { return nil }
        return Dates.nextRepeat(nextDate, rule: rule, anchorDay: anchorDay, after: nextDate, until: until, calendar: calendar)
    }

    /// Whether the next occurrence falls after the end date. Only a sync merge can produce this (one device moved
    /// the end earlier while another confirmed or skipped past it); such a bill has ended and is removed.
    var hasEnded: Bool {
        guard let calendar = recurrenceCalendar else { return false }
        return until.map { calendar.startOfDay(for: $0) < calendar.startOfDay(for: nextDate) } ?? false
    }

    /// Moves the next occurrence; monthly and yearly rules then keep its day of month (a 31st stays at month end).
    mutating func reschedule(to date: Date) {
        guard let calendar = recurrenceCalendar else { return }
        nextDate = MoneyEntry.timestamp(date)
        anchorDay = calendar.component(.day, from: date)
    }

    /// "每月 9 日", "每年 10月9日", "每周四", "每 2 周的周四", or the rule's own label for other patterns.
    var scheduleLabel: String {
        guard let calendar = recurrenceCalendar else { return Dates.repeatLabel(rule) }
        return Self.scheduleLabel(rule: rule, anchorDay: anchorDay, date: nextDate, calendar: calendar)
    }
    static func scheduleLabel(rule: String, anchorDay: Int, date: Date, calendar: Calendar = Dates.calendar) -> String {
        guard let parsed = RepeatRule(rule) else { return L("不重复", "Never") }
        let weekday = RepeatRule.weekdayName(calendar.component(.weekday, from: date))
        switch parsed.unit {
        case .month where parsed.interval == 1: return L("每月 \(anchorDay) 日", "Monthly on day \(anchorDay)")
        case .year where parsed.interval == 1: return L("每年 ", "Yearly on ") + Dates.label(date, pattern: "M月d日", calendar: calendar)
        case .week where parsed.weekdays.isEmpty:
            return parsed.interval == 1 ? L("每周", "Weekly on ") + weekday : parsed.label + L("的周", " on ") + weekday
        default: return parsed.label
        }
    }

    /// The simplest rule matching how far apart a series' dates are; monthly when there is too little to tell.
    static func inferredRule(from dates: [Date], calendar: Calendar = Dates.calendar) -> String {
        let days = dates.map { calendar.startOfDay(for: $0) }.sorted()
        let gaps = zip(days, days.dropFirst()).compactMap { calendar.dateComponents([.day], from: $0, to: $1).day }.filter { $0 > 0 }
        guard let gap = gaps.sorted().dropFirst(gaps.count / 2).first else { return "monthly" }
        switch gap {
        case 1: return "daily"
        case 7: return "weekly"
        case 14: return RepeatRule(interval: 2, unit: .week).text
        case 28...31: return "monthly"
        case 365...366: return "yearly"
        default: return "monthly"
        }
    }

    func validate(in ledger: FinanceData) throws {
        func check(_ valid: Bool, _ zh: String, _ en: String) throws { if !valid { throw TaskBackup.invalid(L(zh, en)) } }
        let account = accountID.flatMap { id in ledger.accounts.first { $0.id == id } }
        try check(kind == .expense || kind == .income, "周期账单只能是收入或支出。", "Recurring bills must be income or expenses.")
        try check(!title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.count <= 80 && notes.count <= 10000 && tags.count <= 500,
                  "周期账单名称或备注无效。", "Invalid recurring bill name or notes.")
        try check(Money.currencies.contains(currency) && Money.valid(amount, currency: currency) && amount > 0, "周期账单金额必须大于 0。", "A recurring bill needs an amount above 0.")
        try check(accountID == nil || account != nil, "周期账单的账户不存在。", "The recurring bill's account is missing.")
        if let account, account.currency != currency {
            try check(Money.valid(accountAmount, currency: account.currency) && accountAmount > 0, "请输入账户的计划金额。", "Enter the planned account amount.")
        } else {
            try check(accountAmount == 0 || accountAmount == amount, "同币种的计划金额必须一致。", "Same-currency planned amounts must match.")
        }
        try check(baseAmount.map { Money.valid($0, currency: ledger.baseCurrency) } ?? true, "计划折算金额无效。", "Invalid planned conversion.")
        try check(bookID.map { id in ledger.books.contains { $0.id == id } } ?? false, "请为周期账单选择账本。", "Choose a book for the recurring bill.")
        try check(categoryID.map { id in ledger.categories.contains { $0.id == id } } ?? true, "周期账单的分类不存在。", "The recurring bill's category is missing.")
        try check(RepeatRule(rule) != nil && (1...31).contains(anchorDay), "重复规则无效。", "Invalid repeat rule.")
        guard let calendar = recurrenceCalendar else {
            throw TaskBackup.invalid(L("周期账单的重复时区无效。", "The recurring bill has an invalid repeat time zone."))
        }
        let dates = [nextDate] + (until.map { [$0] } ?? [])
        try check(dates.allSatisfy { $0.timeIntervalSince1970.isFinite && (-62135596800...253402300799).contains($0.timeIntervalSince1970) },
                  "周期账单日期无效。", "Invalid recurring bill dates.")
        try check(until.map { calendar.startOfDay(for: $0) >= calendar.startOfDay(for: nextDate) } ?? true,
                  "结束日期不能早于下一期。", "The end date cannot be before the next occurrence.")
    }
}

// MARK: - Coding

extension MoneyRecurring: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, kind, title, amount, currency, accountID, accountAmount, baseAmount, bookID, categoryID, notes, tags, rule, anchorDay, nextDate, until, repeatTimeZoneID
    }
    /// Keys written by earlier builds, which stored every occurrence as an entry and could pause a bill.
    private enum LegacyKeys: String, CodingKey { case start, activeFrom }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); kind = try c.decode(MoneyKind.self, forKey: .kind)
        title = try c.decode(String.self, forKey: .title); amount = try c.decode(Decimal.self, forKey: .amount)
        currency = try c.decode(String.self, forKey: .currency); accountID = try c.decodeIfPresent(UUID.self, forKey: .accountID)
        accountAmount = try c.decode(Decimal.self, forKey: .accountAmount); baseAmount = try c.decodeIfPresent(Decimal.self, forKey: .baseAmount)
        bookID = try c.decodeIfPresent(UUID.self, forKey: .bookID); categoryID = try c.decodeIfPresent(UUID.self, forKey: .categoryID)
        notes = try c.decode(String.self, forKey: .notes); tags = try c.decode(String.self, forKey: .tags)
        rule = try c.decode(String.self, forKey: .rule); anchorDay = try c.decode(Int.self, forKey: .anchorDay)
        until = try c.decodeIfPresent(Date.self, forKey: .until)
        repeatTimeZoneID = try c.decodeIfPresent(String.self, forKey: .repeatTimeZoneID)
        if let next = try c.decodeIfPresent(Date.self, forKey: .nextDate) {
            nextDate = next
        } else {
            let old = try decoder.container(keyedBy: LegacyKeys.self)
            let start = try old.decode(Date.self, forKey: .start)
            nextDate = start
            legacy = Legacy(start: start, activeFrom: try old.decode(Date.self, forKey: .activeFrom))
        }
        if !(1...31).contains(anchorDay), let calendar = recurrenceCalendar { anchorDay = calendar.component(.day, from: nextDate) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(kind, forKey: .kind); try c.encode(title, forKey: .title)
        try c.encode(amount, forKey: .amount); try c.encode(currency, forKey: .currency)
        try c.encodeIfPresent(accountID, forKey: .accountID); try c.encode(accountAmount, forKey: .accountAmount)
        try c.encodeIfPresent(baseAmount, forKey: .baseAmount); try c.encodeIfPresent(bookID, forKey: .bookID)
        try c.encodeIfPresent(categoryID, forKey: .categoryID); try c.encode(notes, forKey: .notes); try c.encode(tags, forKey: .tags)
        try c.encode(rule, forKey: .rule); try c.encode(anchorDay, forKey: .anchorDay); try c.encode(nextDate, forKey: .nextDate)
        try c.encodeIfPresent(until, forKey: .until)
        try c.encodeIfPresent(repeatTimeZoneID, forKey: .repeatTimeZoneID)
    }
}

extension MoneyRecurring {
    /// A bill that repeats `entry` with the entry's date as its first occurrence. Planned amounts are kept only
    /// where the entry needed them.
    init(repeating entry: MoneyEntry, rule: String, until: Date?, in ledger: FinanceData,
         repeatTimeZoneID: String? = Dates.calendar.timeZone.identifier) {
        let account = entry.accountID.flatMap { id in ledger.accounts.first { $0.id == id } }
        let calendar = repeatTimeZoneID == nil ? Dates.calendar : Dates.recurrenceCalendar(timeZoneID: repeatTimeZoneID)
        self.init(kind: entry.kind, title: entry.title, amount: entry.amount, currency: entry.currency, accountID: account?.id,
                  accountAmount: account.map { $0.currency == entry.currency ? 0 : entry.accountAmount } ?? 0,
                  baseAmount: entry.currency != ledger.baseCurrency && account?.currency != ledger.baseCurrency ? entry.baseAmount : nil,
                  bookID: entry.bookID, categoryID: entry.categoryID, notes: entry.notes, tags: entry.tags,
                  rule: rule, anchorDay: calendar?.component(.day, from: entry.date) ?? 0,
                  nextDate: MoneyEntry.timestamp(entry.date), until: until, repeatTimeZoneID: repeatTimeZoneID)
    }
}

// MARK: - Ledger operations

extension FinanceData {
    var recurringBills: [MoneyRecurring] { recurring ?? [] }
    func recurringBill(_ id: UUID?) -> MoneyRecurring? { id.flatMap { id in recurring?.first { $0.id == id } } }

    private mutating func replaceBill(_ bill: MoneyRecurring) {
        guard let index = recurring?.firstIndex(where: { $0.id == bill.id }) else { return }
        recurring?[index] = bill
    }
    private mutating func removeBill(_ id: UUID) {
        recurring?.removeAll { $0.id == id }
        if recurring?.isEmpty == true { recurring = nil }
    }

    mutating func addRecurring(_ bill: MoneyRecurring) throws {
        guard recurringBills.count < MoneyRecurring.maximumCount else {
            throw TaskBackup.invalid(L("周期账单已达上限（\(MoneyRecurring.maximumCount) 个）。", "You have reached the limit of \(MoneyRecurring.maximumCount) recurring bills."))
        }
        try bill.validate(in: self)
        if let issue = recurringCategoryTypeIssue(bill) { throw TaskBackup.invalid(issue) }
        recurring = recurringBills + [bill]
        if bill.repeatTimeZoneID != nil { version = max(version, 3) }
    }

    /// Editing a bill edits its rule only: the pending list follows immediately and confirmed entries never change.
    mutating func updateRecurring(_ bill: MoneyRecurring, expected: MoneyRecurring) throws {
        guard recurringBill(bill.id) == expected else {
            throw TaskBackup.invalid(L("周期账单已在其他窗口修改，请重新打开。", "This recurring bill changed in another window. Reopen it."))
        }
        try bill.validate(in: self)
        if bill.kind != expected.kind || bill.categoryID != expected.categoryID,
           let issue = recurringCategoryTypeIssue(bill) { throw TaskBackup.invalid(issue) }
        replaceBill(bill)
        if bill.repeatTimeZoneID != nil { version = max(version, 3) }
    }

    /// Turns an existing income or expense into the first, already recorded occurrence of a new bill.
    mutating func makeRecurring(_ bill: MoneyRecurring, from entryID: UUID) throws {
        guard let index = entries.firstIndex(where: { $0.id == entryID }), entries[index].deletedAt == nil,
              entries[index].kind == .expense || entries[index].kind == .income, entries[index].refundOf == nil,
              recurringBill(entries[index].recurringID) == nil else {
            throw TaskBackup.invalid(L("这笔账单已改变或已属于周期账单，请刷新后重试。", "This entry changed or already belongs to a recurring bill. Refresh and try again."))
        }
        try addRecurring(bill)
        entries[index].recurringID = bill.id
    }

    /// A bill prefilled from `entry`, due one period after it. An earlier stopped series keeps its inferred rule.
    func recurringDraft(from entry: MoneyEntry) -> MoneyRecurring {
        let series = entry.recurringID.map { id in entries.filter { $0.recurringID == id && $0.deletedAt == nil }.map(\.date) } ?? []
        var bill = MoneyRecurring(repeating: entry, rule: MoneyRecurring.inferredRule(from: series.isEmpty ? [entry.date] : series), until: nil, in: self)
        let latest = max(series.max() ?? entry.date, entry.date)
        if let calendar = bill.recurrenceCalendar,
           let next = Dates.nextRepeat(bill.nextDate, rule: bill.rule, anchorDay: bill.anchorDay, after: latest, calendar: calendar) {
            bill.nextDate = MoneyEntry.timestamp(next)
        }
        return bill
    }

    /// Stops a bill. Every entry it recorded stays.
    mutating func stopRecurring(_ id: UUID) { removeBill(id) }

    private func recurringCategoryTypeIssue(_ bill: MoneyRecurring) -> String? {
        guard let category = category(bill.categoryID), category.isIncome != (bill.kind == .income) else { return nil }
        return L("分类的收支类型与周期账单不一致，请修改周期账单的分类。", "The category's income or expense type does not match. Edit the recurring bill's category.")
    }
    /// Show broken or archived links on the pending card before confirmation.
    func recurringIssue(_ bill: MoneyRecurring) -> String? {
        guard bill.recurrenceCalendar != nil else {
            return L("周期账单的重复时区无效，请从备份恢复。", "This recurring bill has an invalid repeat time zone. Restore a backup.")
        }
        guard let book = books.first(where: { $0.id == bill.bookID }) else {
            return L("账本已不存在，请修改周期账单。", "Its book no longer exists. Edit the recurring bill.")
        }
        if book.archived { return L("账本“\(book.name)”已归档，请修改周期账单。", "The book “\(book.name)” is archived. Edit the recurring bill.") }
        if let id = bill.accountID {
            guard let account = accounts.first(where: { $0.id == id }) else {
                return L("账户已不存在，请修改周期账单。", "Its account no longer exists. Edit the recurring bill.")
            }
            if account.archived { return L("账户“\(account.name)”已归档，请修改周期账单。", "The account “\(account.name)” is archived. Edit the recurring bill.") }
        }
        if let id = bill.categoryID {
            guard let category = categories.first(where: { $0.id == id }) else {
                return L("分类已不存在，请修改周期账单。", "Its category no longer exists. Edit the recurring bill.")
            }
            if let issue = recurringCategoryTypeIssue(bill) { return issue }
            let parentArchived = category.parentID.map { parent in categories.first { $0.id == parent }?.archived != false } ?? false
            if category.archived || parentArchived {
                return L("分类“\(categoryPath(id))”已归档，请修改周期账单。", "The category “\(categoryPath(id))” is archived. Edit the recurring bill.")
            }
        }
        return nil
    }

    /// The entry an occurrence would record, or nil if the bill no longer fits the ledger (e.g. a deleted book).
    func occurrenceEntry(_ bill: MoneyRecurring, on date: Date) -> MoneyEntry? {
        guard bill.bookID.map({ id in books.contains { $0.id == id } }) == true else { return nil }
        let account = bill.accountID.flatMap { id in accounts.first { $0.id == id } }
        if bill.accountID != nil && account == nil { return nil }
        var entry = MoneyEntry()
        entry.id = bill.entryID(for: date); entry.recurringID = bill.id
        entry.kind = bill.kind; entry.title = bill.title; entry.date = MoneyEntry.timestamp(date)
        entry.currency = bill.currency; entry.amount = bill.amount
        entry.accountID = account?.id
        entry.accountAmount = account.map { $0.currency == bill.currency ? bill.amount : bill.accountAmount } ?? 0
        entry.bookID = bill.bookID
        entry.categoryID = bill.categoryID.flatMap { id in categories.contains { $0.id == id } ? id : nil }
        entry.notes = bill.notes; entry.tags = bill.tags
        if bill.currency == baseCurrency { entry.baseAmount = bill.amount }
        else if account?.currency == baseCurrency { entry.baseAmount = entry.accountAmount }
        else { entry.baseAmount = bill.baseAmount }
        return entry
    }

    /// Each bill's next occurrence as a pending preview. Not stored; confirming one records it. A deleted entry
    /// does not hide it: moving the bill back to a deleted occurrence shows that occurrence again.
    var recurringPreviews: [MoneyEntry] {
        let recorded = Set(entries.lazy.filter { $0.deletedAt == nil }.map(\.id))
        return recurringBills.compactMap { bill in
            guard var preview = occurrenceEntry(bill, on: bill.nextDate), !recorded.contains(preview.id) else { return nil }
            preview.pending = true
            return preview
        }
    }

    /// Records the occurrence scheduled on `scheduled` and moves the bill to its next date. `entry` carries the
    /// user's changes when confirmed through the editor; `postedOn` records it on another day (e.g. today).
    mutating func postOccurrence(of billID: UUID, scheduled: Date, entry: MoneyEntry? = nil, postedOn: Date? = nil) throws {
        guard var bill = recurringBill(billID), MoneyEntry.timestamp(bill.nextDate) == MoneyEntry.timestamp(scheduled) else {
            throw TaskBackup.invalid(L("周期账单已改变，请刷新后重试。", "This recurring bill changed. Refresh and try again."))
        }
        try requireRecurrenceCalendar(bill)
        // Without the user's changes the bill's own book, account and category must still be usable.
        if entry == nil, let issue = recurringIssue(bill) { throw TaskBackup.invalid(issue) }
        guard var posted = entry ?? occurrenceEntry(bill, on: bill.nextDate) else {
            throw TaskBackup.invalid(L("周期账单已改变，请刷新后重试。", "This recurring bill changed. Refresh and try again."))
        }
        // Same rule as confirming any pending entry.
        guard books.contains(where: { $0.id == posted.bookID && !$0.archived }) else {
            throw TaskBackup.invalid(L("请选择可用账本后再确认入账。", "Choose an available book before confirming this entry."))
        }
        posted.id = bill.entryID(for: bill.nextDate); posted.recurringID = bill.id; posted.pending = nil
        if let postedOn { posted.date = MoneyEntry.timestamp(postedOn) }
        // Another device may have confirmed it already; a deleted earlier confirmation is replaced.
        let existing = entries.first { $0.id == posted.id }
        if existing == nil || existing?.deletedAt != nil {
            try updateEntry(posted, expected: existing, baseCurrency: baseCurrency)
        }
        if let next = bill.followingDate { bill.nextDate = MoneyEntry.timestamp(next); replaceBill(bill) } else { removeBill(billID) }
    }

    /// Skips the occurrence scheduled on `scheduled` without recording anything.
    mutating func skipOccurrence(of billID: UUID, scheduled: Date) throws {
        guard var bill = recurringBill(billID), MoneyEntry.timestamp(bill.nextDate) == MoneyEntry.timestamp(scheduled) else {
            throw TaskBackup.invalid(L("周期账单已改变，请刷新后重试。", "This recurring bill changed. Refresh and try again."))
        }
        try requireRecurrenceCalendar(bill)
        if let next = bill.followingDate { bill.nextDate = MoneyEntry.timestamp(next); replaceBill(bill) } else { removeBill(billID) }
    }

    private func requireRecurrenceCalendar(_ bill: MoneyRecurring) throws {
        guard bill.recurrenceCalendar != nil else {
            throw TaskBackup.invalid(L("周期账单的重复时区无效。", "The recurring bill has an invalid repeat time zone."))
        }
    }

    /// Converts bills from builds that stored every occurrence as a pending entry. Untouched stored occurrences are
    /// removed and the earliest of them becomes the next date; entries the user confirmed or changed stay. Pure
    /// and deterministic, so every device migrates a synced ledger the same way.
    mutating func migrateLegacyRecurring(calendar: Calendar = Dates.calendar) {
        guard let bills = recurring, bills.contains(where: { $0.legacy != nil }) else { return }
        for var bill in bills {
            guard let legacy = bill.legacy else { continue }
            bill.legacy = nil
            let generated = entries.filter { entry in
                guard entry.recurringID == bill.id, entry.isPending, entry.deletedAt == nil, entry.id == bill.legacyEntryID(on: entry.date, calendar: calendar),
                      var expected = occurrenceEntry(bill, on: entry.date) else { return false }
                expected.id = entry.id; expected.pending = true
                return expected == entry
            }
            let removed = Set(generated.map(\.id))
            entries.removeAll { removed.contains($0.id) }
            if let earliest = generated.map(\.date).min() {
                bill.nextDate = earliest
            } else {
                // Nothing left to show: continue after the latest entry of the series, never before it was active.
                let latest = entries.filter { $0.recurringID == bill.id }.map(\.date).max()
                let lower = max(legacy.activeFrom, latest.flatMap { calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0)) } ?? legacy.start)
                let next = legacy.start >= lower ? legacy.start
                    : Dates.nextRepeat(legacy.start, rule: bill.rule, anchorDay: bill.anchorDay, after: lower.addingTimeInterval(-0.001), until: bill.until, calendar: calendar)
                guard let next else { removeBill(bill.id); continue }
                bill.nextDate = MoneyEntry.timestamp(next)
            }
            replaceBill(bill)
        }
    }
}
