import Foundation

/// Earlier names offered while typing: newest use wins, matching ignores case and width,
/// deleted entries are left out, and entries saved under their category's name are found by it.
@MainActor enum FinanceSuggestionChecks {
    static func run(require: (Bool, String) throws -> Void) throws {
        var ledger = FinanceData.initial
        let cardAccount = MoneyAccount(name: "Card"), cashAccount = MoneyAccount(name: "Cash")
        ledger.accounts = [cardAccount, cashAccount]
        let card = cardAccount.id, cash = cashAccount.id
        let food = ledger.defaultCategory(income: false)!
        let salary = ledger.categories.first { $0.isIncome }!.id
        func entry(_ title: String, _ kind: MoneyKind = .expense, category: UUID?, account: UUID?, day: Int, deleted: Bool = false) -> MoneyEntry {
            var e = MoneyEntry(); e.title = title; e.kind = kind; e.categoryID = category; e.accountID = account
            e.date = Dates.calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: 12))!
            if deleted { e.deletedAt = e.date }
            return e
        }
        let foodLabel = ledger.category(food)!.label
        ledger.entries = [
            entry("星巴克", category: food, account: card, day: 1),
            entry("星巴克", category: food, account: cash, day: 5),
            entry("星巴克", category: food, account: cash, day: 3),
            entry("星巴克咖啡豆", category: food, account: card, day: 2),
            entry("买星巴克", category: food, account: card, day: 4),
            entry("Starbucks", category: food, account: card, day: 6),
            entry("星巴克甜品", category: food, account: card, day: 7, deleted: true),
            entry(foodLabel, category: food, account: card, day: 8),
            entry("星巴克", .income, category: salary, account: card, day: 9),
        ]
        let index = MoneyTitleIndex(ledger)
        try require(index.exact(" 星巴克 ", kind: .expense) == MoneyEntrySuggestion(title: "星巴克", categoryID: food, accountID: cash),
                    "an exact name takes the category and account of its newest use")
        try require(index.exact("ＳＴＡＲＢＵＣＫＳ", kind: .expense)?.title == "Starbucks", "matching ignores case and full-width letters")
        try require(index.exact("星巴克", kind: .income)?.categoryID == salary, "income and expenses keep separate names")
        let matches = index.matches("星巴克", kind: .expense)
        try require(matches.map(\.title) == ["星巴克", "星巴克", "星巴克咖啡豆", "买星巴克"],
                    "the exact name comes first, then names starting with it, then names containing it; deleted ones are left out")
        try require(matches.prefix(2).map(\.accountID) == [cash, card], "each account a name was used with is offered, most used first")
        try require(MoneyTitleIndex.isExact(matches[0], "  星巴克") && !MoneyTitleIndex.isExact(matches[2], "星巴克"), "exact names can be highlighted")
        try require(index.matches("星", kind: .expense).map(\.title).prefix(3) == ["星巴克", "星巴克咖啡豆", "星巴克"],
                    "among names starting with the text, more uses rank first, then the most recent")
        try require(index.exact(foodLabel, kind: .expense)?.categoryID == food, "an entry saved under its category's name is offered by that name")
        try require(index.matches("  ", kind: .expense).isEmpty && index.exact("", kind: .expense) == nil, "blank text offers nothing")
        try require(index.matches("星", kind: .expense, limit: 1).count == 1, "suggestions respect the limit")
        try require(MoneyTitleIndex().matches("星", kind: .expense).isEmpty, "an empty ledger offers nothing")
    }
}
