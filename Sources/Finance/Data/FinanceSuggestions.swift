import Foundation

/// An earlier entry's name with a category and account it was used with.
struct MoneyEntrySuggestion: Equatable, Identifiable {
    var title: String
    var categoryID: UUID?
    var accountID: UUID?
    var id: String { title + "|" + (categoryID?.uuidString ?? "") + "|" + (accountID?.uuidString ?? "") }
}

/// Earlier income and expense names, built once per ledger so typing never rescans every entry.
/// Each name keeps one suggestion per category and account it was used with, so "Lunch · card" and
/// "Lunch · cash" are both offered. An entry saved without a name carries its category's name, and is offered too,
/// so typing "吃饭" still finds entries recorded under the 吃饭 category.
struct MoneyTitleIndex {
    private struct Item {
        var suggestion: MoneyEntrySuggestion
        var kind: MoneyKind
        var key: String
        var count: Int
        var latest: Date
    }
    private var items: [Item] = []

    init() {}
    init(_ ledger: FinanceData) {
        var bySlot: [String: Item] = [:]
        for entry in ledger.entries where entry.deletedAt == nil && (entry.kind == .expense || entry.kind == .income) {
            let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let key = Self.normalized(title)
            let suggestion = MoneyEntrySuggestion(title: title, categoryID: entry.categoryID, accountID: entry.accountID)
            let slot = [entry.kind.rawValue, key, entry.categoryID?.uuidString ?? "", entry.accountID?.uuidString ?? ""].joined(separator: "|")
            if var item = bySlot[slot] {
                item.count += 1
                if entry.date >= item.latest { item.latest = entry.date; item.suggestion = suggestion }
                bySlot[slot] = item
            } else {
                bySlot[slot] = Item(suggestion: suggestion, kind: entry.kind, key: key, count: 1, latest: entry.date)
            }
        }
        items = Array(bySlot.values)
    }

    /// Up to `limit` earlier names containing `text`: the exact name first, then names starting with it,
    /// then the most used and most recent.
    func matches(_ text: String, kind: MoneyKind, limit: Int = 4) -> [MoneyEntrySuggestion] {
        let query = Self.normalized(text)
        guard !query.isEmpty else { return [] }
        func rank(_ item: Item) -> Int { item.key == query ? 0 : item.key.hasPrefix(query) ? 1 : 2 }
        return items.filter { $0.kind == kind && $0.key.contains(query) }
            .sorted { left, right in
                if rank(left) != rank(right) { return rank(left) < rank(right) }
                if left.count != right.count { return left.count > right.count }
                return left.latest > right.latest
            }
            .prefix(limit).map(\.suggestion)
    }

    /// The most recent use of exactly this name (ignoring case, width and surrounding spaces).
    func exact(_ text: String, kind: MoneyKind) -> MoneyEntrySuggestion? {
        let query = Self.normalized(text)
        guard !query.isEmpty else { return nil }
        return items.filter { $0.kind == kind && $0.key == query }.max { $0.latest < $1.latest }?.suggestion
    }

    /// Whether a suggestion is exactly the typed name, for highlighting.
    static func isExact(_ suggestion: MoneyEntrySuggestion, _ text: String) -> Bool {
        normalized(suggestion.title) == normalized(text)
    }

    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
