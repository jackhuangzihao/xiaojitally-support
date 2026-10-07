import Foundation

extension FinanceData {
    static func isSample(_ name: String) -> Bool { ["示例 ·", "示例·", "Sample ·"].contains { name.hasPrefix($0) } }
    struct SampleCleanup: Equatable { var entries = 0, ownEntries = 0, accounts = 0, books = 0, moved = 0, categories = 0 }

    /// A small, explicitly labelled book. Existing balances, defaults and exchange rates are untouched.
    @discardableResult mutating func addSamples(now: Date = Date()) throws -> UUID {
        if let book = books.first(where: { Self.isSample($0.name) }) { return book.id }
        let cny = MoneyAccount(name: L("示例 · 人民币卡", "Sample · CNY card"), opening: 1000, type: "debit", bankName: "招商银行")
        let usd = MoneyAccount(name: L("示例 · 美元卡", "Sample · USD card"), currency: "USD", opening: 100, type: "debit", bankName: "HSBC")
        let book = MoneyBook(name: L("示例 · 日常体验", "Sample · Try Finance"), defaultAccountID: usd.id)
        let food = MoneyCategory(name: L("示例 · 餐饮", "Sample · Food"), symbol: "fork.knife")
        let coffee = MoneyCategory(name: L("咖啡", "Coffee"), symbol: "cup.and.saucer", parentID: food.id)
        var lunch = MoneyEntry(); lunch.title = L("示例 · 午餐", "Sample · Lunch")
        lunch.date = MoneyEntry.timestamp(now); lunch.amount = 38; lunch.accountAmount = 38
        lunch.baseAmount = baseCurrency == "CNY" ? 38 : nil
        lunch.currency = "CNY"; lunch.accountID = cny.id; lunch.bookID = book.id; lunch.categoryID = food.id
        var drink = lunch; drink.id = UUID(); drink.title = L("示例 · 咖啡", "Sample · Coffee")
        drink.amount = 8; drink.accountAmount = 8; drink.baseAmount = baseCurrency == "USD" ? 8 : nil
        drink.currency = "USD"; drink.accountID = usd.id; drink.categoryID = coffee.id
        var income = drink; income.id = UUID(); income.title = L("示例 · 收入", "Sample · Income")
        income.kind = .income; income.amount = 120; income.accountAmount = 120
        income.baseAmount = baseCurrency == "USD" ? 120 : nil; income.categoryID = nil
        accounts += [cny, usd]; books.append(book); categories += [food, coffee]; entries += [lunch, drink, income]
        try validate()
        return book.id
    }
    /// What removing the example data would do; the same rules as `removeSamples`.
    var sampleCleanup: SampleCleanup? {
        var copy = self
        let result = copy.removeSamples()
        return result.entries + result.accounts + result.books == 0 ? nil : result
    }
    /// Removes example accounts, books and entries (names starting with “示例 ·”). The user's own entries on an
    /// example account go with it, since its balance cannot exist without it; own entries in an example book move to a real book.
    @discardableResult mutating func removeSamples() -> SampleCleanup {
        var result = SampleCleanup()
        let accountIDs = Set(accounts.filter { Self.isSample($0.name) }.map(\.id))
        let bookIDs = Set(books.filter { Self.isSample($0.name) }.map(\.id))
        var removed = Set(entries.filter { Self.isSample($0.title) || $0.accountID.map(accountIDs.contains) == true || $0.destinationID.map(accountIDs.contains) == true }.map(\.id))
        removed.formUnion(entries.filter { $0.refundOf.map(removed.contains) == true }.map(\.id))
        result.entries = removed.count
        result.ownEntries = entries.filter { removed.contains($0.id) && !Self.isSample($0.title) }.count
        entries.removeAll { removed.contains($0.id) }
        result.accounts = accountIDs.count; result.books = bookIDs.count
        accounts.removeAll { accountIDs.contains($0.id) }
        for i in books.indices where books[i].defaultAccountID.map(accountIDs.contains) == true { books[i].defaultAccountID = nil }
        books.removeAll { bookIDs.contains($0.id) }
        if !books.contains(where: { !$0.archived }) { books.insert(MoneyBook(name: L("日常", "Daily")), at: 0) }
        let home = books.first { !$0.archived }!.id
        for i in entries.indices where entries[i].bookID.map(bookIDs.contains) == true { entries[i].bookID = home; result.moved += 1 }
        let parents = Set(categories.filter { Self.isSample($0.name) }.map(\.id))
        let candidates = parents.union(categories.filter { $0.parentID.map(parents.contains) == true }.map(\.id))
        // Keep a sample category (and its parent) if a user's surviving entry now uses it.
        for _ in 0..<2 {
            let used = Set(entries.compactMap(\.categoryID)).union(categories.compactMap(\.parentID))
            let unused = candidates.subtracting(used)
            let before = categories.count
            categories.removeAll { unused.contains($0.id) }
            result.categories += before - categories.count
        }
        return result
    }
}
