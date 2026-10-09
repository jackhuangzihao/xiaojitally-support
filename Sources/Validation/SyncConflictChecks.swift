import Foundation

extension CloudMerge {
    @MainActor static func checkConflictChoices() throws -> Int {
        var count = 0
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw TaskBackup.invalid("CONFLICT CHOICE CHECK: " + label) }; count += 1
        }
        func conflicts(_ local: TaskBackup, _ cloud: TaskBackup, _ base: TaskBackup, choices: [String: Choice] = [:]) throws -> Conflict {
            do { _ = try merge(local: local, cloud: cloud, base: base, choices: choices) }
            catch let error as Conflict { return error }
            throw TaskBackup.invalid("Expected unresolved review groups")
        }
        let first = TaskBackup.TaskRecord(TaskItem(title: "Same title"))
        let second = TaskBackup.TaskRecord(TaskItem(title: "Same title"))
        let original = TaskBackup(lists: [], tasks: [first, second])
        var left = original, right = original
        left.tasks[0].notes = "Mac note A"; right.tasks[0].notes = "Phone note A"
        left.tasks[1].notes = "Mac note B"; right.tasks[1].notes = "Phone note B"
        let step = Subtask(title: "Original step")
        left.tasks[0].subtasks = [step]; right.tasks[0].subtasks = [step]
        left.tasks[0].subtasks[0].title = "Local checklist value"
        right.tasks[0].subtasks[0].title = "Cloud checklist value"
        let firstKey = SyncChanges.key("task", first.id), secondKey = SyncChanges.key("task", second.id)
        let review = try conflicts(left, right, original)
        try check(review.items.count == 2 && Set(review.items.map(\.id)) == [firstKey, secondKey],
                  "identical task titles remain distinct groups; multiple fields in one task share a choice")
        let detail = review.items.first { $0.id == firstKey }!.detail
        try check(detail.contains("Mac note A") && detail.contains("Phone note A")
                  && detail.contains("Local checklist value") && detail.contains("Cloud checklist value"),
                  "review shows actual note and checklist values from both sides")
        let mixed = try merge(local: left, cloud: right, base: original, choices: [firstKey: .local, secondKey: .cloud])
        try check(mixed.tasks.first { $0.id == first.id }?.notes == "Mac note A"
                  && mixed.tasks.first { $0.id == second.id }?.notes == "Phone note B", "each group can keep a different device")
        try check(try bytes(merge(local: mixed, cloud: mixed, base: original)) == bytes(mixed), "mixed resolution converges on retry")
        let incomplete = try conflicts(left, right, original, choices: [firstKey: .local])
        try check(Set(incomplete.items.map(\.id)) == [firstKey, secondKey], "incomplete selection retains every group for another complete review")
        let unknown = try conflicts(left, right, original, choices: ["unknown": .cloud])
        try check(unknown.items.count == 2, "unknown choices cannot resolve a real record")
        let previousLanguage = UserDefaults.standard.object(forKey: "appLanguage")
        defer {
            if let previousLanguage { UserDefaults.standard.set(previousLanguage, forKey: "appLanguage") }
            else { UserDefaults.standard.removeObject(forKey: "appLanguage") }
        }
        for language in ["en", "zh-Hans"] {
            UserDefaults.standard.set(language, forKey: "appLanguage")
            let translated = try conflicts(left, right, original)
            try check(Set(translated.items.map(\.id)) == Set(review.items.map(\.id)), "group identity survives a language change")
            try check(translated.items.contains { $0.detail.contains("Mac note A") && $0.detail.contains("Phone note A") },
                      "both languages keep untruncated user content")
        }
        var ledger = FinanceData.initial
        var expense = MoneyEntry(title: "Purchase", amount: 200, bookID: ledger.books[0].id, baseAmount: 200)
        var refund = MoneyEntry(kind: .refund, title: "Return", amount: 20, bookID: ledger.books[0].id, baseAmount: 20, refundOf: expense.id)
        expense.date = Date(timeIntervalSince1970: 1000); refund.date = Date(timeIntervalSince1970: 2000)
        ledger.entries = [expense, refund]
        let financeBase = TaskBackup(finance: ledger, lists: [], tasks: [])
        var financeLeft = financeBase, financeRight = financeBase
        financeLeft.finance!.entries[0].amount = 50; financeLeft.finance!.entries[0].baseAmount = 50
        financeLeft.finance!.entries[1].amount = 10; financeLeft.finance!.entries[1].baseAmount = 10
        financeRight.finance!.entries[0].amount = 150; financeRight.finance!.entries[0].baseAmount = 150
        financeRight.finance!.entries[1].amount = 100; financeRight.finance!.entries[1].baseAmount = 100
        financeLeft.finance!.entries[0].notes = "Receipt from Mac"
        financeRight.finance!.entries[0].notes = "Receipt from phone"
        let expenseKey = SyncChanges.key("entry", expense.id), refundKey = SyncChanges.key("entry", refund.id)
        let financeReview = try conflicts(financeLeft, financeRight, financeBase)
        try check(financeReview.items.count == 2 && financeReview.items.contains {
            $0.detail.contains("Receipt from Mac") && $0.detail.contains("Receipt from phone")
        }, "financial review includes actual competing notes and values")
        let rejected = try conflicts(financeLeft, financeRight, financeBase, choices: [expenseKey: .local, refundKey: .cloud])
        try check(rejected.warning != nil && rejected.items.count == 2, "refund exceeding selected expense returns to review with every group intact")
        let valid = try merge(local: financeLeft, cloud: financeRight, base: financeBase, choices: [expenseKey: .cloud, refundKey: .local])
        try check(valid.finance?.entries.first { $0.id == expense.id }?.amount == 150
                  && valid.finance?.entries.first { $0.id == refund.id }?.amount == 10,
                  "valid mixed expense/refund choices retain consistent financial data")
        try check(financeLeft.finance?.entries.first?.amount == 50 && financeRight.finance?.entries.last?.amount == 100,
                  "rejected and accepted previews do not mutate source snapshots")
        do {
            var repeating = first; repeating.repeatRule = "daily"
            repeating.scheduledAt = Date(timeIntervalSince1970: 1_800_000_000)
            let repeatBase = TaskBackup(lists: [], tasks: [repeating, second])
            var local = repeatBase, cloud = repeatBase
            var nextLocal = repeating; nextLocal.id = UUID(); nextLocal.scheduledAt = repeating.scheduledAt!.addingTimeInterval(86400)
            var nextCloud = nextLocal; nextCloud.id = UUID()
            local.tasks[0].isDone = true; local.tasks[0].completedAt = repeating.scheduledAt
            cloud.tasks[0].isDone = true; cloud.tasks[0].completedAt = repeating.scheduledAt
            local.tasks[0].nextOccurrenceID = nextLocal.id; cloud.tasks[0].nextOccurrenceID = nextCloud.id
            local.tasks.append(nextLocal); cloud.tasks.append(nextCloud)
            local.tasks[1].notes = "Separate local note"; cloud.tasks[1].notes = "Separate cloud note"
            let chainKey = "task-chain:" + [repeating.id, nextLocal.id, nextCloud.id].map(\.uuidString).sorted().joined(separator: ",")
            let review = try conflicts(local, cloud, repeatBase)
            try check(Set(review.items.map(\.id)) == [chainKey, secondKey],
                      "competing repeat successors form one stable branch group separate from unrelated notes")
            for side in [Choice.local, .cloud] {
                let opposite: Choice = side == .local ? .cloud : .local
                let selectedNext = side == .local ? nextLocal.id : nextCloud.id
                let resolved = try merge(local: local, cloud: cloud, base: repeatBase,
                    choices: [chainKey: side, secondKey: opposite, SyncChanges.key("task", repeating.id): opposite])
                try check(Set(resolved.tasks.map(\.id)) == [repeating.id, selectedNext, second.id]
                          && resolved.tasks.first { $0.id == repeating.id }?.nextOccurrenceID == selectedNext,
                          "dictionary selection keeps one entire repeat branch; per-row choices cannot split it")
                try check(resolved.tasks.first { $0.id == second.id }?.notes == (opposite == .local ? "Separate local note" : "Separate cloud note"),
                          "a repeat branch choice does not override an unrelated record choice")
                let reversed = try merge(local: cloud, cloud: local, base: repeatBase, choices: [chainKey: opposite, secondKey: side])
                try check(try bytes(reversed) == bytes(resolved), "atomic repeat dictionary choices converge in reverse device order")
            }
            var linkedBase = repeatBase
            linkedBase.tasks[0].nextOccurrenceID = nextLocal.id; linkedBase.tasks.append(nextLocal)
            local = linkedBase; cloud = linkedBase
            local.tasks[0].scheduledAt = repeating.scheduledAt!.addingTimeInterval(60)
            cloud.tasks[0].scheduledAt = repeating.scheduledAt!.addingTimeInterval(120)
            local.tasks[2].notes = "Local occurrence note"; cloud.tasks[2].notes = "Cloud occurrence note"
            let lifecycleKey = "task-lifecycle:" + [repeating.id, nextLocal.id].map(\.uuidString).sorted().joined(separator: ",")
            let occurrenceKey = SyncChanges.key("task", nextLocal.id)
            try check(Set(try conflicts(local, cloud, linkedBase).items.map(\.id)) == [lifecycleKey, occurrenceKey],
                      "repeat lifecycle and independent occurrence text expose distinct stable review groups")
            let scheduled = try merge(local: local, cloud: cloud, base: linkedBase, choices: [lifecycleKey: .cloud, occurrenceKey: .local])
            try check(scheduled.tasks.first { $0.id == repeating.id }?.scheduledAt == cloud.tasks[0].scheduledAt
                      && scheduled.tasks.first { $0.id == nextLocal.id }?.notes == "Local occurrence note"
                      && scheduled.tasks.first { $0.id == repeating.id }?.nextOccurrenceID == nextLocal.id,
                      "per-group review can retain a whole cloud schedule and independent local occurrence text")
        }
        do {
            var money = FinanceData.initial
            let wallet = MoneyAccount(name: "Travel wallet", currency: "USD", opening: 100)
            let sender = MoneyAccount(name: "Sender", currency: "CNY", opening: 1000)
            let spare = MoneyAccount(name: "Spare", currency: "GBP", opening: 50)
            money.accounts = [wallet, sender, spare]
            let accountBase = TaskBackup(finance: money, lists: [], tasks: [first])
            var local = accountBase, cloud = accountBase
            var changedWallet = wallet; changedWallet.currency = "EUR"
            var changedSender = sender; changedSender.currency = "AUD"
            try local.finance!.updateAccount(changedWallet, expected: wallet)
            try local.finance!.updateAccount(changedSender, expected: sender)
            let book = money.books[0].id
            let debit = MoneyEntry(title: "USD purchase", currency: "USD", amount: 10, accountID: wallet.id, accountAmount: 10, bookID: book, baseAmount: 70)
            let refund = MoneyEntry(kind: .refund, title: "Refund to spare", currency: "USD", amount: 5, accountID: spare.id, accountAmount: 4, bookID: book, baseAmount: 35, refundOf: debit.id)
            let transfer = MoneyEntry(kind: .transfer, title: "Incoming transfer", amount: 70, accountID: sender.id, accountAmount: 70,
                                      destinationID: wallet.id, destinationAmount: 10, fee: 2, bookID: book, baseFee: 2)
            let independent = MoneyEntry(title: "Independent GBP posting", currency: "GBP", amount: 10, accountID: spare.id, accountAmount: 10, bookID: book, baseAmount: 90)
            cloud.finance!.entries = [debit, refund, transfer, independent]
            local.tasks[0].notes = "Local independent task"; cloud.tasks[0].notes = "Cloud independent task"
            let groupKey = "account-postings:" + [wallet.id, sender.id].map(\.uuidString).sorted().joined(separator: ",")
            let review = try conflicts(local, cloud, accountBase)
            try check(Set(review.items.map(\.id)) == [groupKey, firstKey],
                      "connected account currencies, transfer fees and cross-account refunds expose one atomic group")
            for side in [Choice.local, .cloud] {
                let opposite: Choice = side == .local ? .cloud : .local
                let resolved = try merge(local: local, cloud: cloud, base: accountBase,
                    choices: [groupKey: side, firstKey: opposite, SyncChanges.key("entry", debit.id): opposite])
                try check(resolved.finance?.accounts.first { $0.id == wallet.id }?.currency == (side == .local ? "EUR" : "USD")
                          && resolved.finance?.accounts.first { $0.id == sender.id }?.currency == (side == .local ? "AUD" : "CNY"),
                          "dictionary choice keeps both connected account denominations together")
                try check(Set(resolved.finance!.entries.map(\.id)) == (side == .local ? Set([independent.id]) : Set([debit.id, refund.id, transfer.id, independent.id]))
                          && resolved.finance?.entries.first { $0.id == transfer.id }?.baseFee == (side == .local ? nil : 2),
                          "atomic account choice retains or removes linked postings and fees together while preserving independent entries")
                try check(resolved.tasks[0].notes == (opposite == .local ? "Local independent task" : "Cloud independent task"),
                          "an atomic finance choice does not override an unrelated task choice")
                let reversed = try merge(local: cloud, cloud: local, base: accountBase, choices: [groupKey: opposite, firstKey: side])
                try check(try bytes(reversed) == bytes(resolved), "atomic account dictionary choices converge in reverse device order")
            }
        }
        return count
    }
}
