import Foundation
import SwiftData

// A ledger is one atomic value inside the same store/backup as tasks. No separate balance cache to drift.
// ponytail: whole-ledger encoding suits personal books; move to indexed entry models if measured saves grow slow.
@Model final class FinanceLedger {
    var id: String = "personal"
    var payload: Data = Data()
    init(payload: Data) { self.payload = payload }
}

enum FinanceEntityKind { case account, book, category }

enum Money {
    /// Supported ledger currencies; retired reference currencies stay readable in historical accounts.
    static let common = ["CNY", "AUD", "USD", "EUR", "GBP", "HKD", "JPY", "SGD", "CAD", "NZD", "CHF", "KRW"]
    static let more = ["THB", "MYR", "IDR", "PHP", "INR", "TRY", "BRL", "MXN", "ZAR", "ILS", "SEK", "NOK", "DKK", "ISK", "PLN", "CZK", "HUF", "RON", "BGN"]
    static let currencies = common + more
    static func scale(_ currency: String) -> Int { ["JPY", "KRW", "ISK"].contains(currency) ? 0 : 2 }
    static func round(_ value: Decimal, currency: String) -> Decimal {
        var input = value, result = Decimal(); NSDecimalRound(&result, &input, scale(currency), .plain); return result
    }
    static func valid(_ value: Decimal, currency: String, signed: Bool = false) -> Bool {
        !value.isNaN && abs(value) <= Decimal(1_000_000_000_000 as Int64) && (signed || value >= 0) && round(value, currency: currency) == value
    }
    static func parse(_ text: String, currency: String, signed: Bool = false) throws -> Decimal {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = signed ? "^-?[0-9]+(?:\\.[0-9]+)?$" : "^[0-9]+(?:\\.[0-9]+)?$"
        guard s.range(of: pattern, options: .regularExpression) != nil,
              let value = Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")), valid(value, currency: currency, signed: signed) else {
            throw TaskBackup.invalid(L("请输入有效金额，\(currency) 最多 \(scale(currency)) 位小数。", "Enter a valid amount; \(currency) allows \(scale(currency)) decimal places."))
        }
        return value
    }
    /// Follow a recorded rate only while the field still matches the recorded or last calculated value.
    static func rescaledText(_ field: String, recorded: Decimal?, previous: String?, from old: Decimal, to new: Decimal, currency: String) -> String? {
        guard let recorded, old != 0, field == (previous ?? text(recorded)) else { return nil }
        return text(round(recorded * new / old, currency: currency))
    }
    /// Only replace values still owned by automatic conversion, never a manual override.
    static func refreshedEstimate(_ field: String, previous: String?, replacement: String?) -> String? {
        guard field.isEmpty || field == previous else { return nil }
        return replacement
    }
    static func display(_ value: Decimal, _ currency: String, hidden: Bool) -> String {
        hidden ? "••••" : format(value, currency)
    }
    static func text(_ value: Decimal) -> String { NSDecimalNumber(decimal: value).stringValue }
    static func format(_ value: Decimal, _ currency: String) -> String {
        let locale = UISettings.locale, places = scale(currency)
        let key = "Tally.moneyFormatter." + locale.identifier + "." + String(places)
        let storage = Thread.current.threadDictionary
        let f: NumberFormatter
        if let cached = storage[key] as? NumberFormatter { f = cached }
        else {
            f = NumberFormatter(); f.locale = locale; f.numberStyle = .decimal
            f.minimumFractionDigits = places; f.maximumFractionDigits = places
            storage[key] = f
        }
        let digits = f.string(from: NSDecimalNumber(decimal: abs(value))) ?? text(abs(value))
        return (value < 0 ? "-" : "") + symbol(currency) + digits
    }
    /// Short symbols as a bank app shows them; ¥ stays renminbi, so yen gets JP¥.
    static func symbol(_ currency: String) -> String {
        ["CNY": "¥", "AUD": "A$", "USD": "US$", "EUR": "€", "GBP": "£", "HKD": "HK$", "JPY": "JP¥", "SGD": "S$", "CAD": "C$", "NZD": "NZ$", "CHF": "CHF ", "KRW": "₩",
         "THB": "฿", "INR": "₹", "PHP": "₱", "TRY": "₺", "BRL": "R$", "MXN": "MX$", "ILS": "₪", "IDR": "Rp ", "MYR": "RM ", "ZAR": "R ", "PLN": "zł "][currency] ?? currency + " "
    }
    static func name(_ currency: String) -> String {
        ["CNY": L("人民币", "Chinese yuan"), "AUD": L("澳元", "Australian dollar"), "USD": L("美元", "US dollar"), "EUR": L("欧元", "Euro"), "GBP": L("英镑", "British pound"), "HKD": L("港币", "Hong Kong dollar"), "JPY": L("日元", "Japanese yen"), "SGD": L("新加坡元", "Singapore dollar"), "CAD": L("加元", "Canadian dollar"), "NZD": L("新西兰元", "New Zealand dollar"), "CHF": L("瑞郎", "Swiss franc"), "KRW": L("韩元", "Korean won"),
         "THB": L("泰铢", "Thai baht"), "MYR": L("马来西亚林吉特", "Malaysian ringgit"), "IDR": L("印尼盾", "Indonesian rupiah"), "PHP": L("菲律宾比索", "Philippine peso"),
         "INR": L("印度卢比", "Indian rupee"), "TRY": L("土耳其里拉", "Turkish lira"), "BRL": L("巴西雷亚尔", "Brazilian real"), "MXN": L("墨西哥比索", "Mexican peso"),
         "ZAR": L("南非兰特", "South African rand"), "ILS": L("以色列新谢克尔", "Israeli shekel"), "SEK": L("瑞典克朗", "Swedish krona"), "NOK": L("挪威克朗", "Norwegian krone"),
         "DKK": L("丹麦克朗", "Danish krone"), "ISK": L("冰岛克朗", "Icelandic krona"), "PLN": L("波兰兹罗提", "Polish zloty"), "CZK": L("捷克克朗", "Czech koruna"),
         "HUF": L("匈牙利福林", "Hungarian forint"), "RON": L("罗马尼亚列伊", "Romanian leu"), "BGN": L("保加利亚列弗", "Bulgarian lev")][currency] ?? currency
    }
    /// Keypad input such as "12.5+8-3". Nil unless every term is a valid amount for the currency.
    static func evaluate(_ expression: String, currency: String, signed: Bool = false) -> Decimal? {
        var text = expression.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: " ", with: "")
        if text.contains(",") {
            // Accept pasted grouped amounts, but never reinterpret a decimal comma such as 12,50 as 1250.
            guard text.range(of: #"^-?[0-9]{1,3}(,[0-9]{3})+(\.[0-9]+)?$"#, options: .regularExpression) != nil else { return nil }
            text = text.replacingOccurrences(of: ",", with: "")
        }
        guard !text.isEmpty, text.count <= 200, text.range(of: (signed ? "^-?" : "^") + "[0-9.]+([+-][0-9.]+)*[+-]?$", options: .regularExpression) != nil else { return nil }
        var total: Decimal = 0, sign: Decimal = 1, term = ""
        func flush() -> Bool {
            guard !term.isEmpty else { return true }
            guard term.range(of: "^[0-9]+(\\.[0-9]*)?$", options: .regularExpression) != nil,
                  let value = Decimal(string: term.hasSuffix(".") ? String(term.dropLast()) : term, locale: Locale(identifier: "en_US_POSIX")) else { return false }
            total += sign * value; term = ""; return true
        }
        for c in text {
            if c == "+" || c == "-" { guard flush() else { return nil }; sign = c == "+" ? 1 : -1 } else { term.append(c) }
        }
        guard flush(), valid(total, currency: currency, signed: signed) else { return nil }
        return total
    }
}

/// Category and account colors, stored as a key so light and dark mode can each choose their own shade.
enum MoneyColor {
    static let keys = ["coral", "orange", "amber", "green", "teal", "blue", "indigo", "purple", "pink", "red", "brown", "gray"]
    static func label(_ key: String) -> String {
        ["coral": L("珊瑚", "Coral"), "orange": L("橙", "Orange"), "amber": L("琥珀", "Amber"), "green": L("绿", "Green"), "teal": L("青", "Teal"), "blue": L("蓝", "Blue"),
         "indigo": L("靛蓝", "Indigo"), "purple": L("紫", "Purple"), "pink": L("粉", "Pink"), "red": L("红", "Red"), "brown": L("棕", "Brown"), "gray": L("灰", "Gray")][key] ?? key
    }
}

enum MoneyAccountType: String, CaseIterable, Identifiable {
    case cash, debit, credit, online, invest, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .cash: L("现金", "Cash")
        case .debit: L("储蓄卡", "Debit cards")
        case .credit: L("信用卡", "Credit cards")
        case .online: L("网络账户", "Online wallets")
        case .invest: L("投资理财", "Investments")
        case .other: L("其他", "Other")
        }
    }
    var symbol: String {
        switch self {
        case .cash: "banknote"
        case .debit: "creditcard"
        case .credit: "creditcard.and.123"
        case .online: "iphone"
        case .invest: "chart.line.uptrend.xyaxis"
        case .other: "wallet.pass"
        }
    }
}

struct MoneyAccount: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var currency = "CNY"
    var opening: Decimal = 0
    var archived = false
    var emoji: String?
    var symbol: String?
    var iconSymbol: String { symbol ?? resolvedType.symbol }
    var type: String? // MoneyAccountType; optional so ledgers written before 0.2.1 still decode.
    var bankName: String? // An institution label, never a bank account number.
    var resolvedType: MoneyAccountType {
        if let type, let value = MoneyAccountType(rawValue: type) { return value }
        let n = name.lowercased()
        if ["现金", "cash"].contains(where: n.contains) { return .cash }
        if ["支付宝", "微信", "余额宝", "零钱", "paypal", "alipay", "wechat"].contains(where: n.contains) { return .online }
        if ["信用", "credit"].contains(where: n.contains) { return .credit }
        if ["银行", "卡", "bank", "card"].contains(where: n.contains) { return .debit }
        return .other
    }
}
struct MoneyBook: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var defaultAccountID: UUID?
    var archived = false
    var budget: Decimal? // Monthly, in the ledger's base currency.
    var emoji: String?
    var symbol: String?
    var iconSymbol: String { symbol ?? "book.closed" }
}
struct MoneyCategory: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var symbol = "tag"
    var archived = false
    var income: Bool? // Nil on older ledgers: only the built-in salary category counts as income.
    var color: String?
    var emoji: String?
    var parentID: UUID? // Optional for old backups; one parent and one child level.
    static let builtInNames: [String: (zh: String, en: String)] = [
        "food": ("餐饮", "Food"), "transport": ("交通", "Transport"), "shopping": ("购物", "Shopping"), "home": ("居住", "Home"),
        "travel": ("旅行", "Travel"), "health": ("健康", "Health"), "salary": ("工资", "Salary"), "other": ("其他", "Other"),
        "drinks": ("饮品", "Drinks"), "fun": ("娱乐", "Leisure"), "daily": ("日用", "Daily goods"), "phone": ("通讯", "Phone"),
        "study": ("学习", "Learning"), "sports": ("运动", "Sports"), "gifts": ("人情", "Gifts"),
        "bonus": ("奖金", "Bonus"), "invest": ("理财", "Investments"), "parttime": ("兼职", "Side job"),
        "redpacket": ("红包", "Red packets"), "otherincome": ("其他收入", "Other income")]
    static let builtInColors = ["food": "coral", "transport": "blue", "shopping": "pink", "home": "amber", "travel": "teal", "health": "red",
                                "salary": "green", "other": "gray", "drinks": "brown", "fun": "purple", "daily": "orange", "phone": "indigo",
                                "study": "blue", "sports": "green", "gifts": "red", "bonus": "amber", "invest": "teal", "parttime": "indigo",
                                "redpacket": "red", "otherincome": "gray"]
    var label: String { Self.builtInNames[name].map { L($0.zh, $0.en) } ?? name }
    var isIncome: Bool { income ?? ["salary", "bonus", "invest", "parttime", "redpacket", "otherincome"].contains(name) }
    var resolvedColor: String {
        if let color, MoneyColor.keys.contains(color) { return color }
        if let key = Self.builtInColors[name] { return key }
        // Stable per name, so a user category keeps its color between launches.
        let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return MoneyColor.keys[abs(sum) % (MoneyColor.keys.count - 1)]
    }
}
enum MoneyKind: String, Codable, CaseIterable, Identifiable {
    case expense, income, transfer, refund, adjustment
    var id: String { rawValue }
    var label: String {
        switch self {
        case .expense: L("支出", "Expense")
        case .income: L("收入", "Income")
        case .transfer: L("转账", "Transfer")
        case .refund: L("退款", "Refund")
        case .adjustment: L("余额调整", "Balance adjustment")
        }
    }
}
struct MoneyEntry: Codable, Identifiable, Equatable {
    static func timestamp(_ date: Date = Date()) -> Date { Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)) }
    var id = UUID()
    var kind: MoneyKind = .expense
    var title = ""
    var date = Self.timestamp()
    var currency = "CNY"
    var amount: Decimal = 0
    var accountID: UUID?
    var accountAmount: Decimal = 0
    var destinationID: UUID?
    var destinationAmount: Decimal = 0
    var fee: Decimal = 0 // In the source account's currency.
    var bookID: UUID?
    var categoryID: UUID?
    var baseAmount: Decimal? // Locked at posting; absent means excluded from combined totals, visibly.
    var baseFee: Decimal?
    var rateNote = ""
    var notes = ""
    var tags = ""
    var taskID: UUID?
    var refundOf: UUID?
    var deletedAt: Date?
    var deletionBatchID: UUID? // Only rows deleted by the same action are restored together.
}
struct MoneyRate: Codable, Equatable {
    var base: String
    var quote: String
    var rate: Decimal
    var date: String
    var fetchedAt = MoneyEntry.timestamp()
    var source = "ECB"
    var isManual: Bool { source == "Manual" }
    static func valid(_ rate: Decimal) -> Bool {
        !rate.isNaN && rate >= Decimal(string: "0.000000001")! && rate < 1_000_000_000
    }
}
struct MoneyAssetSummary {
    var balances: [String: Decimal] = [:]
    var convertedSubtotal: Decimal = 0
    var missingCurrencies: [String] = []
    var rateDates: [String] = []
    var manualCurrencies: [String] = []
    var total: Decimal? { missingCurrencies.isEmpty ? convertedSubtotal : nil }
}
struct MoneyConversionChange {
    let original: MoneyEntry
    let updated: MoneyEntry
    let rate: MoneyRate? // Nil when the recorded amount is already in the reporting currency.
}
struct MoneyConversionPreview {
    let baseCurrency: String
    let changes: [MoneyConversionChange]
    let unavailableEntries: [MoneyEntry]
    let futureEntries: [MoneyEntry]
    fileprivate let accountCurrencies: [UUID: String]
}
struct FinanceData: Codable, Equatable {
    var version = 1
    var baseCurrency = "CNY"
    var accounts: [MoneyAccount] = []
    var books: [MoneyBook] = []
    var categories: [MoneyCategory] = []
    var entries: [MoneyEntry] = []
    var rates: [MoneyRate] = []
    static var initial: Self {
        var result = Self()
        result.books = [MoneyBook(id: UUID(uuidString: "E837FC77-248C-4DE3-AF81-000000000001")!, name: L("日常", "Daily"))]
        result.categories = zip(["food", "transport", "shopping", "home", "travel", "health", "salary", "other"],
                                ["fork.knife", "tram", "bag", "house", "airplane", "heart", "banknote", "ellipsis.circle"]).enumerated().map { i, pair in
            MoneyCategory(id: UUID(uuidString: String(format: "E837FC77-248C-4DE3-AF81-%012d", i + 100))!, name: pair.0, symbol: pair.1)
        } + Self.addedDefaults
        return result
    }
    /// Categories added in 0.2.1. Fixed IDs, so two devices that each add them still merge cleanly.
    static let addedDefaults: [MoneyCategory] = [
        ("drinks", "cup.and.saucer", false), ("fun", "gamecontroller", false), ("daily", "basket", false), ("phone", "iphone", false),
        ("study", "book", false), ("sports", "figure.run", false), ("gifts", "gift", false),
        ("bonus", "rosette", true), ("invest", "chart.line.uptrend.xyaxis", true), ("parttime", "briefcase", true),
        ("redpacket", "envelope", true), ("otherincome", "plus.circle", true)
    ].enumerated().map { i, item in
        MoneyCategory(id: UUID(uuidString: String(format: "E837FC77-248C-4DE3-AF81-%012d", i + 200))!, name: item.0, symbol: item.1, income: item.2)
    }
    /// Adds the 0.2.1 defaults an older ledger lacks, skipping any whose name the user already has.
    mutating func addMissingDefaults() {
        for category in Self.addedDefaults where !categories.contains(where: { $0.id == category.id || $0.name == category.name || $0.label == category.label }) {
            categories.append(category)
        }
    }
    func remainingRefund(for id: UUID, excluding refundID: UUID? = nil) -> Decimal {
        guard let original = entries.first(where: { $0.id == id && $0.kind == .expense && $0.deletedAt == nil }) else { return 0 }
        return max(0, original.amount - entries.filter { $0.refundOf == id && $0.deletedAt == nil && $0.id != refundID }.reduce(0) { $0 + $1.amount })
    }
    func categoryIDs(including id: UUID) -> Set<UUID> {
        Set([id] + categories.filter { $0.parentID == id }.map(\.id))
    }
    func categoryMatches(_ entryCategoryID: UUID?, filterID: UUID) -> Bool {
        entryCategoryID.map { categoryIDs(including: filterID).contains($0) } ?? false
    }
    func rootCategoryID(_ id: UUID?) -> UUID? {
        guard let id else { return nil }
        return categories.first { $0.id == id }?.parentID ?? id
    }
    func categoryPath(_ id: UUID?) -> String {
        guard let category = categories.first(where: { $0.id == id }) else { return "" }
        guard let parent = categories.first(where: { $0.id == category.parentID }) else { return category.label }
        return parent.label + " / " + category.label
    }
    /// An invalid incoming hierarchy is rejected before it can replace the working ledger.
    func validateCategoryHierarchy() throws {
        let byID = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for category in categories {
            guard let parentID = category.parentID else { continue }
            guard parentID != category.id, let parent = byID[parentID], parent.parentID == nil,
                  parent.isIncome == category.isIncome, !parent.archived || category.archived else {
                throw TaskBackup.invalid(L("子分类必须属于同类型的一级分类；已归档的父分类下不能启用子分类。", "A subcategory needs a top-level parent of the same type; an archived parent cannot have active children."))
            }
        }
    }
    mutating func updateCategory(_ category: MoneyCategory, expected: MoneyCategory?) throws {
        guard categories.first(where: { $0.id == category.id }) == expected else {
            throw TaskBackup.invalid(L("分类已改变，请重新打开。", "Category changed. Reopen it."))
        }
        guard !categories.contains(where: { $0.id != category.id && $0.parentID == category.parentID && $0.isIncome == category.isIncome && $0.label.caseInsensitiveCompare(category.label) == .orderedSame }) else {
            throw TaskBackup.invalid(L("此分组内的分类名称已存在。", "A category with this name already exists in this group."))
        }
        if let expected, expected.isIncome != category.isIncome,
           entries.contains(where: { $0.categoryID == category.id }) || categories.contains(where: { $0.parentID == category.id }) {
            throw TaskBackup.invalid(L("已有账单或子分类，不能切换收支类型。", "A category with entries or subcategories cannot change between income and spending."))
        }
        var changed = self
        if let index = changed.categories.firstIndex(where: { $0.id == category.id }) { changed.categories[index] = category }
        else { changed.categories.append(category) }
        if category.archived {
            for i in changed.categories.indices where changed.categories[i].parentID == category.id { changed.categories[i].archived = true }
        }
        try changed.validateCategoryHierarchy()
        categories = changed.categories
    }
    func removalBlock(_ kind: FinanceEntityKind, id: UUID) -> String? {
        let referenced: Bool
        switch kind {
        case .account: referenced = entries.contains { $0.accountID == id || $0.destinationID == id }
        case .book:
            if books.count <= 1 || (books.first { $0.id == id }?.archived == false && !books.contains { $0.id != id && !$0.archived }) {
                return L("请至少保留一个可用账本。", "Keep at least one available book.")
            }
            referenced = entries.contains { $0.bookID == id }
        case .category:
            if categories.contains(where: { $0.parentID == id }) {
                return L("请先移走或删除子分类；归档父分类会同时归档子分类并保留全部历史。", "Move or remove subcategories first. Archiving the parent also archives its children and keeps all history.")
            }
            if Self.initial.categories.contains(where: { $0.id == id }) {
                return L("系统预设分类可归档；自建的空分类可删除。", "Archive preset categories; unused custom categories can be deleted.")
            }
            referenced = entries.contains { $0.categoryID == id }
        }
        return referenced ? L("有关联账单（含最近删除），请使用归档以保留历史。", "Linked entries exist, including Recently deleted. Archive this item to keep its history.") : nil
    }
    mutating func remove(_ kind: FinanceEntityKind, id: UUID, expected: Self) throws {
        let unchanged: Bool
        switch kind {
        case .account: unchanged = accounts.contains { $0.id == id } && accounts.first { $0.id == id } == expected.accounts.first { $0.id == id }
        case .book: unchanged = books.contains { $0.id == id } && books.first { $0.id == id } == expected.books.first { $0.id == id }
        case .category: unchanged = categories.contains { $0.id == id } && categories.first { $0.id == id } == expected.categories.first { $0.id == id }
        }
        guard unchanged else { throw TaskBackup.invalid(L("项目已改变，请重新打开。", "This item changed. Reopen it.")) }
        if let reason = removalBlock(kind, id: id) { throw TaskBackup.invalid(reason) }
        switch kind {
        case .account:
            accounts.removeAll { $0.id == id }
            for i in books.indices where books[i].defaultAccountID == id { books[i].defaultAccountID = nil }
        case .book: books.removeAll { $0.id == id }
        case .category: categories.removeAll { $0.id == id }
        }
    }
    /// With `selected` (the entries of the viewed period), an archived book's budget counts only in periods it was used,
    /// so a finished trip keeps its history without inflating every later month.
    func budgetBooks(for bookID: UUID?, in selected: [MoneyEntry]? = nil) -> [MoneyBook] {
        let used = selected.map { Set($0.filter { $0.deletedAt == nil }.compactMap(\.bookID)) }
        return books.filter { book in
            book.budget != nil && (bookID.map { book.id == $0 } ?? (!book.archived || used?.contains(book.id) ?? true))
        }
    }
    func budget(for bookID: UUID?, in selected: [MoneyEntry]? = nil) -> Decimal? {
        let values = budgetBooks(for: bookID, in: selected).compactMap(\.budget)
        return values.isEmpty ? nil : values.reduce(0, +)
    }
    /// Deleting a purchase takes its refunds along, so no refund is left pointing at a deleted purchase.
    mutating func trash(_ entry: MoneyEntry, at date: Date = Date()) throws {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }), entries[index] == entry, entry.deletedAt == nil else {
            throw TaskBackup.invalid(L("账单已在其他窗口修改。请重新打开再操作。", "This entry changed in another window. Reopen it first."))
        }
        let stamp = MoneyEntry.timestamp(date), batch = UUID()
        entries[index].deletedAt = stamp; entries[index].deletionBatchID = batch
        if entry.kind == .expense {
            for i in entries.indices where entries[i].refundOf == entry.id && entries[i].deletedAt == nil {
                entries[i].deletedAt = stamp; entries[i].deletionBatchID = batch
            }
        }
    }
    /// Restores what was deleted together: a purchase brings back its refunds, a refund brings back its purchase.
    mutating func restore(_ entry: MoneyEntry) throws {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }), entries[index] == entry, entry.deletedAt != nil else {
            throw TaskBackup.invalid(L("账单已在其他窗口修改。请重新打开再操作。", "This entry changed in another window. Reopen it first."))
        }
        entries[index].deletedAt = nil; entries[index].deletionBatchID = nil
        // Legacy records have no batch. Restore those refunds individually rather than guessing by timestamp.
        if entry.kind == .expense, let batch = entry.deletionBatchID {
            for i in entries.indices where entries[i].refundOf == entry.id && entries[i].deletedAt != nil && entries[i].deletionBatchID == batch {
                entries[i].deletedAt = nil; entries[i].deletionBatchID = nil
            }
        }
        if entry.kind == .refund, let original = entries.firstIndex(where: { $0.id == entry.refundOf }), entries[original].deletedAt != nil {
            entries[original].deletedAt = nil; entries[original].deletionBatchID = nil
        }
    }
    func liveRefunds(of id: UUID) -> [MoneyEntry] { entries.filter { $0.refundOf == id && $0.deletedAt == nil } }

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
    func budgetSpending(_ selected: [MoneyEntry], for bookID: UUID?) -> MoneyStatisticsTotal {
        let ids = Set(budgetBooks(for: bookID, in: selected).map(\.id))
        let entries = selected.filter { $0.deletedAt == nil && $0.bookID.map(ids.contains) == true }
        return statisticsTotal(entries, income: false, in: baseCurrency, history: nil, days: nil)
    }
    func balance(_ id: UUID, before date: Date? = nil) -> Decimal {
        guard let account = accounts.first(where: { $0.id == id }) else { return 0 }
        return entries.filter { $0.deletedAt == nil && (date == nil || $0.date < date!) }
            .reduce(account.opening) { $0 + $1.accountChange(for: id) }
    }
    /// Stored entry dates have second precision; reconciliation includes entries at the selected instant.
    func balance(_ id: UUID, at date: Date) -> Decimal {
        balance(id, before: MoneyEntry.timestamp(date).addingTimeInterval(1))
    }
    /// Editing replaces the old posting; a new UUID adds a separate posting.
    func balanceAfterSaving(_ entry: MoneyEntry, for id: UUID) -> Decimal {
        let old = entries.first { $0.id == entry.id && $0.deletedAt == nil }
        return balance(id) - (old?.accountChange(for: id) ?? 0)
            + (entry.deletedAt == nil ? entry.accountChange(for: id) : 0)
    }
    func reconciliationEntry(for id: UUID, bookID: UUID? = nil) -> MoneyEntry {
        var entry = MoneyEntry(); entry.kind = .adjustment; entry.title = L("余额校准", "Balance adjustment")
        entry.accountID = id; entry.currency = accounts.first { $0.id == id }?.currency ?? baseCurrency
        entry.bookID = books.first { $0.id == bookID }?.id ?? books.first { !$0.archived }?.id ?? books.first?.id
        return entry
    }
    mutating func updateAccount(_ account: MoneyAccount, expected: MoneyAccount?, allowOpeningCorrection: Bool = false) throws {
        guard accounts.first(where: { $0.id == account.id }) == expected else {
            throw TaskBackup.invalid(L("账户已改变，请重新打开。", "Account changed. Reopen it."))
        }
        guard !accounts.contains(where: { $0.id != account.id && $0.name.caseInsensitiveCompare(account.name) == .orderedSame }) else {
            throw TaskBackup.invalid(L("账户名称已存在。", "Account name already exists."))
        }
        if let expected, entries.contains(where: { $0.accountID == account.id || $0.destinationID == account.id }) {
            guard expected.currency == account.currency else {
                throw TaskBackup.invalid(L("账户已有流水，不能直接更换币种。请新建对应币种的账户。", "An account with entries cannot change currency. Create an account in the required currency."))
            }
            guard expected.opening == account.opening || allowOpeningCorrection else {
                throw TaskBackup.invalid(L("更正期初余额会影响所有历史余额，请先确认。", "Correcting the opening balance changes all historical balances. Confirm first."))
            }
        }
        if let index = accounts.firstIndex(where: { $0.id == account.id }) { accounts[index] = account }
        else { accounts.append(account) }
    }
    func reconciliationChange(_ id: UUID, at date: Date, checked: Decimal, expected: Decimal) throws -> Decimal {
        guard let account = accounts.first(where: { $0.id == id }), Money.valid(checked, currency: account.currency, signed: true) else {
            throw TaskBackup.invalid(L("请输入有效的账户余额。", "Enter a valid account balance."))
        }
        let current = balance(id, at: date)
        guard current == expected else { throw TaskBackup.invalid(L("这个时刻的账面余额已变化，请重新打开核对。", "The balance at this time changed. Reopen reconciliation.")) }
        return checked - current
    }
    /// Compute once for the entire account, so date/category filters cannot change balances beside a row.
    func runningBalances(_ id: UUID) -> [UUID: Decimal] {
        guard let account = accounts.first(where: { $0.id == id }) else { return [:] }
        var balance = account.opening, result: [UUID: Decimal] = [:]
        for e in entries.filter({ $0.deletedAt == nil && $0.matches(bookID: nil, accountID: id) }).sorted(by: { MoneyEntry.newestFirst($1, $0) }) {
            balance += e.accountChange(for: id); result[e.id] = balance
        }
        return result
    }
    func defaultAccount(for bookID: UUID?) -> UUID? {
        guard let id = books.first(where: { $0.id == bookID })?.defaultAccountID else { return nil }
        return accounts.first { $0.id == id && !$0.archived }?.id
    }
    func allowsAccount(_ id: UUID, for entry: MoneyEntry, replacing original: MoneyEntry?) -> Bool {
        guard let account = accounts.first(where: { $0.id == id }) else { return false }
        if !account.archived || original?.accountID == id || original?.destinationID == id { return true }
        // Historical refunds and explicit reconciliation can still settle a closed account.
        if entry.kind == .refund, entries.first(where: { $0.id == entry.refundOf })?.accountID == id { return true }
        return entry.kind == .adjustment && entry.accountID == id
    }
    func checkAccounts(for entry: MoneyEntry, replacing original: MoneyEntry?) throws {
        for id in [entry.accountID, entry.destinationID].compactMap({ $0 }) where !allowsAccount(id, for: entry, replacing: original) {
            throw TaskBackup.invalid(L("所选账户已归档或不存在，请选择可用账户。", "The selected account is archived or missing. Choose an available account."))
        }
    }
    func copyEntry(_ original: MoneyEntry, preferredBookID: UUID? = nil, at date: Date = Date()) -> MoneyEntry {
        var entry = original
        entry.id = UUID(); entry.date = MoneyEntry.timestamp(date); entry.deletedAt = nil; entry.deletionBatchID = nil; entry.refundOf = nil; entry.taskID = nil; entry.rateNote = ""
        let source = accounts.first { $0.id == entry.accountID }, destination = accounts.first { $0.id == entry.destinationID }
        if entry.currency != baseCurrency || source.map({ $0.currency != entry.currency }) == true || destination.map({ $0.currency != entry.currency }) == true {
            entry.accountAmount = 0; entry.destinationAmount = 0; entry.baseAmount = nil; entry.baseFee = nil
        }
        if source?.archived == true { entry.accountID = nil; entry.accountAmount = 0 }
        if destination?.archived == true { entry.destinationID = nil; entry.destinationAmount = 0 }
        if books.first(where: { $0.id == entry.bookID })?.archived != false {
            entry.bookID = books.first { $0.id == preferredBookID && !$0.archived }?.id ?? books.first { !$0.archived }?.id
        }
        return entry
    }
    func searchText(for entry: MoneyEntry) -> String {
        [entry.title, entry.notes, entry.tags, books.first { $0.id == entry.bookID }?.name ?? "",
         accounts.first { $0.id == entry.accountID }?.name ?? "", accounts.first { $0.id == entry.destinationID }?.name ?? "",
         categoryPath(entry.categoryID)].joined(separator: " ")
    }
    func accountFlow(_ id: UUID, in selected: [MoneyEntry]) -> (incoming: Decimal, outgoing: Decimal) {
        var incoming: Decimal = 0, outgoing: Decimal = 0
        for entry in selected where entry.deletedAt == nil {
            let change = entry.accountChange(for: id)
            if change > 0 { incoming += change } else { outgoing -= change }
        }
        return (incoming, outgoing)
    }
    func converted(_ amount: Decimal, from: String, to: String) -> Decimal? {
        if from == to { return amount }
        guard let rate = storedRate(from: from, to: to) else { return nil }
        return Money.round(amount * rate.rate, currency: to)
    }
    /// Use either stored direction; an explicit manual quote takes priority over a cached reference.
    func storedRate(from: String, to: String) -> MoneyRate? {
        let matches = rates.filter { ($0.base == from && $0.quote == to || $0.base == to && $0.quote == from) && MoneyRate.valid($0.rate) }
        guard var selected = matches.sorted(by: {
            if $0.isManual != $1.isManual { return $0.isManual }
            if $0.date != $1.date { return $0.date > $1.date }
            if $0.fetchedAt != $1.fetchedAt { return $0.fetchedAt > $1.fetchedAt }
            return $0.base == from && $1.base != from
        }).first else { return nil }
        if selected.base != from { selected.base = from; selected.quote = to; selected.rate = 1 / selected.rate }
        return selected
    }
    func assetSummary(in currency: String = "CNY") -> MoneyAssetSummary {
        var result = MoneyAssetSummary()
        let accountMap = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for account in accounts { result.balances[account.currency, default: 0] += account.opening }
        for entry in entries where entry.deletedAt == nil {
            if let id = entry.accountID, let account = accountMap[id] { result.balances[account.currency, default: 0] += entry.accountChange(for: id) }
            if let id = entry.destinationID, id != entry.accountID, let account = accountMap[id] { result.balances[account.currency, default: 0] += entry.accountChange(for: id) }
        }
        for (original, amount) in result.balances {
            if original == currency { result.convertedSubtotal += amount; continue }
            if amount == 0 { continue }
            guard let quote = storedRate(from: original, to: currency) else { result.missingCurrencies.append(original); continue }
            // Round the total once, not each account; tiny foreign balances must not disappear.
            result.convertedSubtotal += amount * quote.rate
            if quote.isManual { result.manualCurrencies.append(original) }
            else { result.rateDates.append(quote.date) }
        }
        result.convertedSubtotal = Money.round(result.convertedSubtotal, currency: currency)
        result.missingCurrencies.sort(); result.rateDates = Set(result.rateDates).sorted(); result.manualCurrencies.sort()
        return result
    }
    mutating func setManualRate(from: String, to: String, text: String, at date: Date = Date()) throws {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Money.currencies.contains(from), Money.currencies.contains(to), from != to,
              cleaned.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
              let rate = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")), MoneyRate.valid(rate),
              date.timeIntervalSince1970.isFinite else {
            throw TaskBackup.invalid(L("请输入大于等于 0.000000001 且小于 1000000000 的有效汇率。", "Enter a valid rate from 0.000000001 up to, but not including, 1000000000."))
        }
        rates.removeAll { $0.base == from && $0.quote == to || $0.base == to && $0.quote == from }
        rates.append(MoneyRate(base: from, quote: to, rate: rate, date: ExchangeRates.dayString(date), fetchedAt: MoneyEntry.timestamp(date), source: "Manual"))
    }
    mutating func removeManualRate(from: String, to: String) {
        rates.removeAll { $0.isManual && ($0.base == from && $0.quote == to || $0.base == to && $0.quote == from) }
    }
    mutating func mergeReferenceRates(_ incoming: [MoneyRate], replaceManual: Bool = false) throws {
        var updated = self
        for rate in incoming {
            guard !rate.isManual, Money.currencies.contains(rate.base), Money.currencies.contains(rate.quote), rate.base != rate.quote,
                  MoneyRate.valid(rate.rate), rate.date.count == 10, rate.fetchedAt.timeIntervalSince1970.isFinite, rate.source.count <= 80 else {
                throw TaskBackup.invalid(L("汇率数据无效。", "Invalid exchange rate data."))
            }
            if updated.storedRate(from: rate.base, to: rate.quote)?.isManual == true {
                guard replaceManual else { continue }
                updated.removeManualRate(from: rate.base, to: rate.quote)
            }
            if updated.rates.contains(where: { $0.base == rate.base && $0.quote == rate.quote && $0.date > rate.date }) { continue }
            updated.rates.removeAll { $0.base == rate.base && $0.quote == rate.quote }
            updated.rates.append(rate)
        }
        rates = updated.rates
    }
    var missingConversionEntries: [MoneyEntry] {
        entries.filter { entry in
            guard entry.deletedAt == nil else { return false }
            switch entry.kind {
            case .income, .expense, .refund: return entry.baseAmount == nil
            case .transfer: return entry.fee > 0 && entry.baseFee == nil
            case .adjustment: return false
            }
        }
    }
    /// Preview only missing postings. Asset quotes never stand in for a historical transaction quote.
    func missingConversionPreview(history: RateHistory?, now: Date = Date()) -> MoneyConversionPreview {
        let today = ExchangeRates.dayString(now), days = history?.sortedDays
        let coveredThrough = history.map { min(today, ExchangeRates.dayString($0.fetchedAt)) }
        let accountsByID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changes: [MoneyConversionChange] = [], unavailable: [MoneyEntry] = [], future: [MoneyEntry] = []
        var currencies: [UUID: String] = [:]
        for entry in missingConversionEntries {
            let day = ExchangeRates.dayString(entry.date)
            guard day <= today else { future.append(entry); continue }
            let account = entry.accountID.flatMap { accountsByID[$0] }
            let currency = account?.currency ?? entry.currency
            let amount = entry.kind == .transfer ? entry.fee : (account == nil ? entry.amount : entry.accountAmount)
            let rate: MoneyRate?
            let converted: Decimal
            let note: String
            if currency == baseCurrency {
                rate = nil; converted = amount
                note = L("折算采用已记录的本币金额", "Conversion uses the recorded reporting-currency amount")
            } else if let history, let coveredThrough, day <= coveredThrough,
                      let quote = history.rate(from: currency, to: baseCurrency, on: day, sorted: days), MoneyRate.valid(quote.rate) {
                rate = MoneyRate(base: currency, quote: baseCurrency, rate: quote.rate, date: quote.day,
                                 fetchedAt: MoneyEntry.timestamp(history.fetchedAt), source: "ECB")
                converted = Money.round(amount * quote.rate, currency: baseCurrency)
                note = "ECB \(quote.day) · 1 \(currency) = \(Money.text(quote.rate)) \(baseCurrency)"
            } else { unavailable.append(entry); continue }
            var updated = entry
            if entry.kind == .transfer { updated.baseFee = converted } else { updated.baseAmount = converted }
            updated.rateNote = [entry.rateNote, note].filter { !$0.isEmpty }.joined(separator: "\n")
            guard Money.valid(converted, currency: baseCurrency), updated.rateNote.count <= 500 else { unavailable.append(entry); continue }
            changes.append(MoneyConversionChange(original: entry, updated: updated, rate: rate))
            if let account { currencies[account.id] = account.currency }
        }
        return MoneyConversionPreview(baseCurrency: baseCurrency, changes: changes, unavailableEntries: unavailable,
                                      futureEntries: future, accountCurrencies: currencies)
    }
    /// Check the entire preview before committing; a concurrent edit must never be overwritten or partially saved.
    mutating func applyMissingConversions(_ preview: MoneyConversionPreview) throws {
        let indices = Dictionary(entries.indices.map { (entries[$0].id, $0) }, uniquingKeysWith: { first, _ in first })
        guard baseCurrency == preview.baseCurrency,
              preview.accountCurrencies.allSatisfy({ id, currency in accounts.contains { $0.id == id && $0.currency == currency } }),
              Set(preview.changes.map { $0.original.id }).count == preview.changes.count else {
            throw TaskBackup.invalid(L("账户或统计币种已变化，请重新预览折算。", "Accounts or reporting currency changed. Preview conversions again."))
        }
        var next = self
        for change in preview.changes {
            guard let index = indices[change.original.id], entries[index] == change.original else {
                throw TaskBackup.invalid(L("账单已修改或删除，请重新预览折算。", "An entry changed or was deleted. Preview conversions again."))
            }
            var allowed = change.original
            if allowed.kind == .transfer, allowed.fee > 0, allowed.baseFee == nil { allowed.baseFee = change.updated.baseFee }
            else if [.expense, .income, .refund].contains(allowed.kind), allowed.baseAmount == nil { allowed.baseAmount = change.updated.baseAmount }
            else { throw TaskBackup.invalid(L("账单已有折算金额，请重新预览。", "The entry already has a conversion. Preview again.")) }
            allowed.rateNote = change.updated.rateNote
            guard allowed == change.updated, allowed.deletedAt == nil else { throw TaskBackup.invalid(L("折算预览无效，请重试。", "Invalid conversion preview. Please try again.")) }
            next.entries[index] = allowed
        }
        try next.validate()
        self = next
    }
    func totals(_ selected: [MoneyEntry]) -> (income: Decimal, expense: Decimal, refunds: Decimal, missing: Int) {
        var income: Decimal = 0, expense: Decimal = 0, refunds: Decimal = 0, missing = 0
        for e in selected where e.deletedAt == nil {
            if e.kind != .transfer && e.kind != .adjustment {
                if let amount = e.baseAmount {
                    switch e.kind { case .income: income += amount; case .expense: expense += amount; case .refund: refunds += amount; default: break }
                } else { missing += 1 }
            }
            if e.fee > 0 { if let fee = e.baseFee { expense += fee } else { missing += 1 } }
        }
        return (income, expense, refunds, missing)
    }
    func validate() throws {
        func check(_ valid: Bool, _ zh: String, _ en: String) throws { if !valid { throw TaskBackup.invalid(L(zh, en)) } }
        func unique<T: Identifiable>(_ items: [T]) -> Bool where T.ID: Hashable { Set(items.map(\.id)).count == items.count }
        try check(entries.count <= 100_000 && accounts.count <= 1000 && books.count <= 1000 && categories.count <= 1000, "记账数据超过当前支持的大小。", "Ledger exceeds supported size.")
        try check(version == 1 && Money.currencies.contains(baseCurrency), "记账数据版本或本位币无效。", "Invalid ledger version or base currency.")
        try check(unique(accounts) && unique(books) && unique(categories) && unique(entries), "记账数据含重复编号。", "Duplicate ledger identifiers.")
        try validateCategoryHierarchy()
        let accountMap = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let bookIDs = Set(books.map(\.id)), categoryIDs = Set(categories.map(\.id))
        let entryMap = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        func name(_ s: String) -> Bool { !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && s.count <= 80 }
        try check(accounts.allSatisfy { name($0.name) && ($0.bankName.map(name) ?? true) && Money.currencies.contains($0.currency) && Money.valid($0.opening, currency: $0.currency, signed: true) }, "账户名称、银行、币种或期初余额无效。", "Invalid account name, bank, currency or opening balance.")
        try check(books.allSatisfy { name($0.name) && ($0.defaultAccountID == nil || accountMap[$0.defaultAccountID!] != nil) && ($0.budget.map { Money.valid($0, currency: baseCurrency) && $0 > 0 } ?? true) } && categories.allSatisfy { name($0.name) && $0.symbol.count <= 80 && ($0.color?.count ?? 0) <= 20 } && accounts.allSatisfy { ($0.type?.count ?? 0) <= 20 }, "账本或分类无效。", "Invalid book or category.")
        let icons = accounts.map(\.emoji) + books.map(\.emoji) + categories.map(\.emoji)
        try check(icons.allSatisfy { $0.map(TaskList.validEmoji) ?? true }, "请选择一个表情作为图标。", "Choose one emoji for an icon.")
        try check((accounts.map(\.symbol) + books.map(\.symbol)).allSatisfy { $0.map { !$0.isEmpty && $0.count <= 80 } ?? true }, "图标无效。", "Invalid icon.")
        for e in entries {
            let account = e.accountID.flatMap { accountMap[$0] }, destination = e.destinationID.flatMap { accountMap[$0] }
            try check(name(e.title) && e.notes.count <= 10000 && e.tags.count <= 500 && e.rateNote.count <= 500 && e.date.timeIntervalSince1970.isFinite && (-62135596800...253402300799).contains(e.date.timeIntervalSince1970) && (e.deletedAt.map { $0.timeIntervalSince1970.isFinite && (-62135596800...253402300799).contains($0.timeIntervalSince1970) } ?? true), "账单名称、日期或备注无效。", "Invalid entry title, date or notes.")
            try check(Money.currencies.contains(e.currency) && Money.valid(e.amount, currency: e.currency, signed: e.kind == .adjustment) && (e.amount > 0 || e.kind == .adjustment && e.amount != 0), "账单金额必须有效且非零。", "Entry amount must be valid and nonzero.")
            try check(e.bookID.map { bookIDs.contains($0) } ?? false, "请选择账本。", "Choose a book.")
            try check(e.categoryID.map { categoryIDs.contains($0) } ?? true, "分类不存在。", "Category does not exist.")
            try check((e.accountID == nil || account != nil) && (e.destinationID == nil || destination != nil), "关联账户不存在。", "Linked account is missing.")
            if let account {
                try check(Money.valid(e.accountAmount, currency: account.currency, signed: e.kind == .adjustment) && (e.accountAmount > 0 || e.kind == .adjustment && e.accountAmount != 0), "请输入账户的实际金额。", "Enter the actual account amount.")
                if account.currency == baseCurrency && e.currency != baseCurrency && e.kind != .transfer && e.kind != .adjustment { try check(e.baseAmount == e.accountAmount, "折算金额必须与本币账户实际金额一致。", "Converted amount must match the base-currency account amount.") }
                if e.currency == account.currency { try check(e.amount == e.accountAmount, "同币种的账单和扣款金额必须相同。", "Same-currency entry and account amounts must match.") }
            } else { try check(e.accountAmount == 0 && e.fee == 0, "无账户账单不能改变余额。", "Unassigned entries cannot change balances.") }
            // A positive foreign amount can legitimately round to zero in the reporting currency.
            try check(e.baseAmount.map { Money.valid($0, currency: baseCurrency, signed: e.kind == .adjustment) && (e.kind != .adjustment || $0 != 0) } ?? true, "折算金额无效。", "Invalid converted amount.")
            if e.currency == baseCurrency && e.kind != .transfer && e.kind != .adjustment { try check(e.baseAmount == e.amount, "本币账单的统计金额必须等于原金额。", "Base-currency totals must match the entry amount.") }
            try check(Money.valid(e.fee, currency: account?.currency ?? baseCurrency) && (e.baseFee.map { Money.valid($0, currency: baseCurrency) } ?? true), "手续费无效。", "Invalid fee.")
            if e.kind == .transfer {
                try check(account != nil && destination != nil && e.accountID != e.destinationID && e.currency == account?.currency, "转账需要两个不同的账户。", "Transfers need two different accounts.")
                try check(Money.valid(e.destinationAmount, currency: destination!.currency) && e.destinationAmount > 0, "请输入实际到账金额。", "Enter the amount received.")
                if account?.currency == destination?.currency { try check(e.accountAmount == e.destinationAmount, "同币种转账金额应一致，手续费单独填写。", "Same-currency transfers must match; enter the fee separately.") }
                if e.fee > 0 && account?.currency == baseCurrency { try check(e.baseFee == e.fee, "本币手续费必须计入支出。", "Base-currency fees must be counted as expenses.") }
            } else { try check(e.destinationID == nil && e.destinationAmount == 0 && e.fee == 0 && e.baseFee == nil, "仅转账支持到账账户和手续费。", "Only transfers have a receiving account and fee.") }
            if e.kind == .adjustment { try check(account != nil && e.currency == account?.currency, "余额调整需要同币种账户。", "Adjustments require an account in the same currency.") }
            if e.kind == .refund {
                guard let original = e.refundOf.flatMap({ entryMap[$0] }) else { throw TaskBackup.invalid(L("退款缺少原消费。", "Refund requires the original expense.")) }
                try check(original.kind == .expense && original.currency == e.currency && original.bookID == e.bookID && original.categoryID == e.categoryID && (e.deletedAt != nil || original.deletedAt == nil), "退款应与原消费的币种、账本和分类一致；请先处理关联退款再删除消费。", "Refunds must match the original currency, book and category; handle linked refunds before deleting the expense.")
                try check(e.date >= original.date, "退款日期不能早于原消费。", "Refund date cannot precede the expense.")
            } else { try check(e.refundOf == nil, "非退款账单不能关联原消费。", "Only refunds reference an expense.") }
        }
        var refunded: [UUID: Decimal] = [:]
        for e in entries where e.kind == .refund && e.deletedAt == nil { refunded[e.refundOf!, default: 0] += e.amount }
        try check(refunded.allSatisfy { id, amount in amount <= entryMap[id]!.amount }, "累计退款不能超过原消费金额。", "Total refunds cannot exceed the original expense.")
        try check(rates.count <= 500 && Set(rates.map { $0.base + $0.quote }).count == rates.count && rates.allSatisfy { Money.currencies.contains($0.base) && Money.currencies.contains($0.quote) && MoneyRate.valid($0.rate) && $0.date.count == 10 && $0.fetchedAt.timeIntervalSince1970.isFinite && $0.source.count <= 80 }, "汇率数据无效。", "Invalid exchange rate data.")
    }
    func merging(_ incoming: Self) throws -> Self {
        // A divergent shared account/transaction needs an explicit full restore, never silent double posting.
        func merge<T: Identifiable & Equatable>(_ existing: [T], _ added: [T]) throws -> [T] where T.ID: Hashable {
            let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
            for value in added { if let old = byID[value.id], old != value { throw TaskBackup.invalid(L("记账记录存在不同版本，无法安全合并。请先导出当前备份，再选择完整替换恢复。", "Conflicting ledger records cannot be merged safely. Export a current backup, then use full replacement.")) } }
            return existing + added.filter { byID[$0.id] == nil }
        }
        try validate(); try incoming.validate()
        guard baseCurrency == incoming.baseCurrency else { throw TaskBackup.invalid(L("本位币不同，不能合并记账数据。", "Ledgers with different base currencies cannot be merged.")) }
        var result = self
        result.accounts = try merge(accounts, incoming.accounts); result.books = try merge(books, incoming.books)
        result.categories = try merge(categories, incoming.categories); result.entries = try merge(entries, incoming.entries)
        for rate in incoming.rates where !result.rates.contains(where: { $0.base == rate.base && $0.quote == rate.quote }) { result.rates.append(rate) }
        try result.validate(); return result
    }
    func csv(_ selected: [MoneyEntry]) -> String {
        func cell(_ text: String) -> String {
            // Formula-safe export, including user-authored labels beginning with spreadsheet operators.
            let safe = ["=", "+", "-", "@", "\t", "\r"].contains(String(text.prefix(1))) ? "'" + text : text
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let header = ["ID", "Date", "Type", "Title", "Currency", "Amount", "Account", "Account currency", "Account amount", "Destination", "Destination currency", "Received", "Fee", "Base currency", "Base amount", "Base fee", "Book", "Category", "Tags", "Notes", "Task ID", "Refund of", "Rate note"]
        let rows = selected.map { e -> [String] in
            let a = accounts.first { $0.id == e.accountID }, d = accounts.first { $0.id == e.destinationID }
            return [e.id.uuidString, e.date.ISO8601Format(), e.kind.rawValue, e.title, e.currency, Money.text(e.amount), a?.name ?? "", a?.currency ?? "", Money.text(e.accountAmount), d?.name ?? "", d?.currency ?? "", Money.text(e.destinationAmount), Money.text(e.fee), baseCurrency, e.baseAmount.map(Money.text) ?? "", e.baseFee.map(Money.text) ?? "", books.first { $0.id == e.bookID }?.name ?? "", categoryPath(e.categoryID), e.tags, e.notes, e.taskID?.uuidString ?? "", e.refundOf?.uuidString ?? "", e.rateNote]
        }
        return "\u{FEFF}" + ([header] + rows).map { $0.map(cell).joined(separator: ",") }.joined(separator: "\r\n")
    }
}

@MainActor enum FinanceStore {
    // One validated snapshot, shared by readers. Always compare the stored bytes:
    // another window, sync, restore or a rollback can replace the ledger at any time.
    private static var cached: (payload: Data, value: FinanceData)?

    static func payload(_ context: ModelContext) throws -> Data? {
        let records = try context.fetch(FetchDescriptor<FinanceLedger>())
        guard records.count <= 1 else { throw TaskBackup.invalid(L("发现多份记账数据，请从备份恢复。", "Multiple ledgers found. Restore a backup.")) }
        return records.first?.payload
    }
    static func read(_ context: ModelContext) throws -> FinanceData? {
        guard let bytes = try payload(context) else { return nil }
        return try decode(bytes)
    }
    static func decode(_ bytes: Data) throws -> FinanceData {
        if let cached, cached.payload == bytes { return cached.value }
        let value = try JSONDecoder().decode(FinanceData.self, from: bytes)
        try value.validate()
        cached = (bytes, value)
        return value
    }
    static func stage(_ value: FinanceData, in context: ModelContext) throws {
        try value.validate()
        var normalized = value
        for i in normalized.entries.indices {
            normalized.entries[i].date = MoneyEntry.timestamp(normalized.entries[i].date)
            normalized.entries[i].deletedAt = normalized.entries[i].deletedAt.map(MoneyEntry.timestamp)
        }
        for i in normalized.rates.indices { normalized.rates[i].fetchedAt = MoneyEntry.timestamp(normalized.rates[i].fetchedAt) }
        let data = try JSONEncoder().encode(normalized)
        let existing = try context.fetch(FetchDescriptor<FinanceLedger>())
        guard existing.count <= 1 else { throw TaskBackup.invalid("Multiple ledgers") }
        if let record = existing.first { record.payload = data } else { context.insert(FinanceLedger(payload: data)) }
        cached = (data, normalized)
    }
    static func update(_ context: ModelContext, _ change: (inout FinanceData) throws -> Void) throws {
        try Store.recovery.requireWritable(context)
        var value = try read(context) ?? .initial
        try change(&value); try stage(value, in: context); try Store.save(context)
    }
    static func put(_ entry: MoneyEntry, expected: MoneyEntry?, in context: ModelContext) throws {
        try update(context) { value in
            let current = value.entries.first { $0.id == entry.id }
            guard current == expected else { throw TaskBackup.invalid(L("账单已在其他窗口修改。请重新打开再编辑。", "This entry changed in another window. Reopen it before editing.")) }
            try value.checkAccounts(for: entry, replacing: expected)
            value.entries.removeAll { $0.id == entry.id }; value.entries.append(entry)
            // Moving a purchase between books is only reclassification; refunds follow without another debit.
            if entry.kind == .expense {
                for i in value.entries.indices where value.entries[i].refundOf == entry.id {
                    value.entries[i].bookID = entry.bookID; value.entries[i].categoryID = entry.categoryID
                }
            }
        }
    }
}

struct MoneyRateResult {
    let rates: [MoneyRate]
    let missingCurrencies: [String]
}
enum ExchangeRates {
    static func dayString(_ date: Date, timeZone: TimeZone = .current) -> String {
        let zone = timeZone, storage = Thread.current.threadDictionary
        let key = "Tally.exchangeRateDayFormatter"
        let f: DateFormatter
        if let cached = storage[key] as? DateFormatter, cached.timeZone == zone { f = cached }
        else {
            f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = zone; f.dateFormat = "yyyy-MM-dd"
            storage[key] = f
        }
        return f.string(from: date)
    }
    static func fetch(base: String, quotes: [String], date: Date? = nil) async throws -> [MoneyRate] {
        let result = try await fetchAvailable(base: base, quotes: quotes, date: date)
        guard result.missingCurrencies.isEmpty else { throw URLError(.cannotParseResponse) }
        return result.rates
    }
    static func fetchAvailable(base: String, quotes: [String], date: Date? = nil) async throws -> MoneyRateResult {
        let targets = Set(quotes).filter { $0 != base }.sorted()
        guard Money.currencies.contains(base), targets.allSatisfy(Money.currencies.contains) else { throw URLError(.badURL) }
        if targets.isEmpty { return MoneyRateResult(rates: [], missingCurrencies: []) }
        let selected = min(date ?? Date(), Date())
        let archive = selected < Date().addingTimeInterval(-80 * 86400) ? "eurofxref-hist.xml" : "eurofxref-hist-90d.xml"
        var request = URLRequest(url: URL(string: "https://www.ecb.europa.eu/stats/eurofxref/" + archive)!); request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 20_000_000 else { throw URLError(.badServerResponse) }
        return try parseAvailable(data, base: base, quotes: targets, onOrBefore: dayString(selected))
    }
    static func parse(_ data: Data, base: String, quotes: [String], onOrBefore date: String) throws -> [MoneyRate] {
        let result = try parseAvailable(data, base: base, quotes: quotes, onOrBefore: date)
        guard result.missingCurrencies.isEmpty else { throw URLError(.cannotParseResponse) }
        return result.rates
    }
    static func parseAvailable(_ data: Data, base: String, quotes: [String], onOrBefore date: String) throws -> MoneyRateResult {
        let delegate = ECBRatesParser(limit: date), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), let day = delegate.days.keys.max(), let values = delegate.days[day] else { throw URLError(.cannotParseResponse) }
        var rates: [MoneyRate] = [], missing: [String] = []
        for quote in Set(quotes).filter({ $0 != base }).sorted() {
            guard let source = values[base], source > 0, let value = values[quote], value > 0,
                  MoneyRate.valid(value / source) else { missing.append(quote); continue }
            rates.append(MoneyRate(base: base, quote: quote, rate: value / source, date: day, source: "ECB"))
        }
        return MoneyRateResult(rates: rates, missingCurrencies: missing)
    }
}
/// Daily ECB reference rates (per euro), so reports can convert each entry at the rate of its own day.
struct RateHistory: Codable, Equatable {
    var days: [String: [String: Decimal]] = [:] // "yyyy-MM-dd" → currency → units per euro
    var fetchedAt = Date.distantPast
    var sortedDays: [String] { days.keys.sorted() }
    /// Crossing a local calendar day must refresh coverage even when the six-hour cache has not expired.
    func isFresh(since day: String, at now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(fetchedAt)
        return days.keys.min().map { $0 <= day } == true && age >= 0 && age < 6 * 3600
            && ExchangeRates.dayString(fetchedAt) == ExchangeRates.dayString(now)
    }
    /// Units of `to` per one unit of `from` on the latest published day on or before `day`.
    func rate(from: String, to: String, on day: String, sorted: [String]? = nil) -> (rate: Decimal, day: String)? {
        if from == to { return (1, day) }
        let keys = sorted ?? sortedDays
        var low = 0, high = keys.count - 1, found: String?
        while low <= high {
            let mid = (low + high) / 2
            if keys[mid] <= day { found = keys[mid]; low = mid + 1 } else { high = mid - 1 }
        }
        guard let found, let values = days[found], let a = values[from], let b = values[to], a > 0 else { return nil }
        return (b / a, found)
    }
    static func parse(_ data: Data, since: String) throws -> Self {
        let delegate = ECBRatesParser(limit: "9999-12-31"), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), !delegate.days.isEmpty else { throw URLError(.cannotParseResponse) }
        // Keep one earlier day so the first requested date still has a rate on or before it.
        let keys = delegate.days.keys.sorted()
        let first = keys.last { $0 < since } ?? keys.first!
        return Self(days: delegate.days.filter { $0.key >= first }, fetchedAt: Date())
    }
}

/// Downloads daily rates once and keeps them on disk; rates are public data, nothing about the ledger is sent.
@MainActor enum RateHistoryStore {
    private static var memory: RateHistory?
    private static var file: URL? {
        try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("JianshiRates", isDirectory: true).appendingPathComponent("ecb-daily.json")
    }
    static var cached: RateHistory? {
        if let memory { return memory }
        guard let file, let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(RateHistory.self, from: data) else { return nil }
        memory = value; return value
    }
    /// Covers `since` through today; refreshes at most every few hours. Throws only when nothing usable exists.
    static func load(since: Date) async throws -> RateHistory {
        let start = ExchangeRates.dayString(since)
        if let cached, cached.isFresh(since: start) { return cached }
        do {
            let archive = since < Date().addingTimeInterval(-80 * 86400) ? "eurofxref-hist.xml" : "eurofxref-hist-90d.xml"
            var request = URLRequest(url: URL(string: "https://www.ecb.europa.eu/stats/eurofxref/" + archive)!); request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 40_000_000 else { throw URLError(.badServerResponse) }
            let value = try await Task.detached(priority: .utility) { try RateHistory.parse(data, since: start) }.value
            memory = value
            if let file {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? JSONEncoder().encode(value).write(to: file, options: .atomic)
            }
            return value
        } catch {
            if let cached { return cached }
            throw error
        }
    }
}

extension MoneyEntry {
    /// What this entry adds to spending (refunds negative, transfer fees included) or income, in its own money:
    /// the original currency, or the paying account's currency for a transfer fee.
    func originalStatistics(income: Bool, feeCurrency: String?) -> (amount: Decimal, currency: String)? {
        switch kind {
        case .income where income, .expense where !income: return (amount, currency)
        case .refund where !income: return (-amount, currency)
        case .transfer where !income && fee > 0: return (fee, feeCurrency ?? currency)
        default: return nil
        }
    }
}

struct MoneyStatisticsTotal {
    var total: Decimal = 0
    var missing = 0
    var convertedCount = 0
    var estimateDates: Set<String> = []
    var complete: Bool { missing == 0 && estimateDates.isEmpty }
    static func average(_ totals: [Self]) -> Decimal? {
        guard !totals.isEmpty, totals.allSatisfy(\.complete) else { return nil }
        return totals.reduce(Decimal.zero) { $0 + $1.total } / Decimal(totals.count)
    }
    func change(from previous: Self) -> Decimal? {
        guard complete, previous.complete, previous.total > 0 else { return nil }
        return (total - previous.total) / previous.total
    }
}

extension FinanceData {
    /// Carry the provenance alongside the value, so a cached estimate cannot masquerade as a historical quote.
    func statisticsValue(_ entry: MoneyEntry, income: Bool, in display: String, history: RateHistory?, days: [String]?) -> (amount: Decimal, estimateDate: String?)? {
        let feeCurrency = accounts.first { $0.id == entry.accountID }?.currency
        guard let original = entry.originalStatistics(income: income, feeCurrency: feeCurrency) else { return nil }
        if original.currency == display { return (original.amount, nil) }
        if feeCurrency == display, entry.kind == .expense || entry.kind == .income || entry.kind == .refund {
            return (entry.kind == .refund ? -entry.accountAmount : entry.accountAmount, nil)
        }
        guard let base = entry.statisticsAmount(income: income) else { return nil }
        if display == baseCurrency { return (base, nil) }
        let day = ExchangeRates.dayString(entry.date)
        if let history, let quote = history.rate(from: baseCurrency, to: display, on: day, sorted: days) {
            let estimate = day > ExchangeRates.dayString(history.fetchedAt)
            return (Money.round(base * quote.rate, currency: display), estimate ? quote.day : nil)
        }
        if let quote = storedRate(from: baseCurrency, to: display) {
            return (Money.round(base * quote.rate, currency: display), quote.date)
        }
        return nil
    }
    func statisticsAmount(_ entry: MoneyEntry, income: Bool, in display: String, history: RateHistory?, days: [String]?) -> Decimal? {
        statisticsValue(entry, income: income, in: display, history: history, days: days)?.amount
    }
    func statisticsTotal(_ entries: [MoneyEntry], income: Bool, in display: String, history: RateHistory?, days: [String]?) -> MoneyStatisticsTotal {
        var result = MoneyStatisticsTotal()
        for entry in entries where entry.originalStatistics(income: income, feeCurrency: nil) != nil {
            if let value = statisticsValue(entry, income: income, in: display, history: history, days: days) {
                result.total += value.amount
                result.convertedCount += 1
                if let date = value.estimateDate { result.estimateDates.insert(date) }
            } else { result.missing += 1 }
        }
        return result
    }
    func categoryMonthlyTotals(_ key: MoneyCategoryKey, income: Bool, endingAt anchor: Date, bookID: UUID?, in display: String, history: RateHistory?) -> [(start: Date, summary: MoneyStatisticsTotal)] {
        guard let endMonth = Dates.calendar.dateInterval(of: .month, for: anchor),
              let start = Dates.calendar.date(byAdding: .month, value: -5, to: endMonth.start) else { return [] }
        let selected = entries.filter {
            $0.deletedAt == nil && $0.date >= start && $0.date < endMonth.end
                && (bookID == nil || $0.bookID == bookID) && key.includes($0, income: income, data: self)
        }
        let grouped = Dictionary(grouping: selected) { Dates.calendar.dateInterval(of: .month, for: $0.date)!.start }
        let days = history?.sortedDays
        return (0..<6).compactMap { offset in
            guard let month = Dates.calendar.date(byAdding: .month, value: offset, to: start) else { return nil }
            return (month, statisticsTotal(grouped[month] ?? [], income: income, in: display, history: history, days: days))
        }
    }

}

private final class ECBRatesParser: NSObject, XMLParserDelegate {
    let limit: String
    var days: [String: [String: Decimal]] = [:]
    var current: String?
    init(limit: String) { self.limit = limit }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        guard elementName == "Cube" else { return }
        if let day = attributes["time"] {
            current = day <= limit && day.count == 10 ? day : nil
            if let current { days[current] = ["EUR": 1] }
        } else if let current, let currency = attributes["currency"], Money.currencies.contains(currency),
                  let text = attributes["rate"], let rate = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !rate.isNaN && rate > 0 && rate < 1_000_000_000 {
            days[current]?[currency] = rate
        }
    }
}

// One contribution rule for category totals, the trend, and drill-down results.
enum MoneyCategoryKey: Hashable {
    case category(UUID?)
    case fees
    func includes(_ entry: MoneyEntry, income: Bool) -> Bool {
        switch self {
        case .fees: return !income && entry.kind == .transfer && entry.fee > 0
        case .category(let id):
            return entry.categoryID == id && (income ? entry.kind == .income : entry.kind == .expense || entry.kind == .refund)
        }
    }
    func includes(_ entry: MoneyEntry, income: Bool, data: FinanceData) -> Bool {
        if case .category(let id?) = self {
            return data.categoryMatches(entry.categoryID, filterID: id) && (income ? entry.kind == .income : entry.kind == .expense || entry.kind == .refund)
        }
        return includes(entry, income: income)
    }
}
struct MoneyCategoryTotal: Identifiable {
    var id: MoneyCategoryKey
    var total: Decimal
    var count: Int
    var missing = 0
    var estimateDates: Set<String> = []
    var summary: MoneyStatisticsTotal { MoneyStatisticsTotal(total: total, missing: missing, convertedCount: count, estimateDates: estimateDates) }
}
struct MoneyDrilldown {
    var range: DateInterval
    var key: MoneyCategoryKey
    var income: Bool
    var includeSubcategories = true
    func matches(_ entry: MoneyEntry) -> Bool {
        entry.deletedAt == nil && entry.date >= range.start && entry.date < range.end && key.includes(entry, income: income)
    }
    func matches(_ entry: MoneyEntry, data: FinanceData) -> Bool {
        entry.deletedAt == nil && entry.date >= range.start && entry.date < range.end
            && (includeSubcategories ? key.includes(entry, income: income, data: data) : key.includes(entry, income: income))
    }
}
extension MoneyEntry {
    func statisticsAmount(income: Bool) -> Decimal? {
        switch kind {
        case .income where income, .expense where !income: return baseAmount
        case .refund where !income: return baseAmount.map { -$0 }
        case .transfer where !income && fee > 0: return baseFee
        default: return nil
        }
    }
}
extension FinanceData {
    func byCategory(_ selected: [MoneyEntry], income: Bool) -> (rows: [MoneyCategoryTotal], missing: Int) {
        var sums: [MoneyCategoryKey: (total: Decimal, count: Int)] = [:], missing = 0
        for entry in selected where entry.deletedAt == nil {
            let key: MoneyCategoryKey = entry.kind == .transfer ? .fees : .category(rootCategoryID(entry.categoryID))
            guard key.includes(entry, income: income, data: self) else { continue }
            guard let amount = entry.statisticsAmount(income: income) else { missing += 1; continue }
            var row = sums[key] ?? (0, 0)
            row.total += amount; row.count += 1
            sums[key] = row
        }
        let rows = sums.map { MoneyCategoryTotal(id: $0.key, total: $0.value.total, count: $0.value.count) }
            .sorted { abs($0.total) > abs($1.total) }
        return (rows, missing)
    }
}

/// Actual account-currency movement, distinct from spending/income statistics.
extension MoneyEntry {
    static func newestFirst(_ a: Self, _ b: Self) -> Bool {
        a.date != b.date ? a.date > b.date : a.id.uuidString < b.id.uuidString
    }
    func matches(bookID: UUID?, accountID: UUID?) -> Bool {
        (bookID == nil || self.bookID == bookID) && (accountID == nil || self.accountID == accountID || destinationID == accountID)
    }
    func accountChange(for id: UUID) -> Decimal {
        var change: Decimal = 0
        if accountID == id {
            switch kind {
            case .expense, .transfer: change -= accountAmount + fee
            case .income, .refund, .adjustment: change += accountAmount
            }
        }
        if kind == .transfer && destinationID == id { change += destinationAmount }
        return change
    }
}

enum MoneyDateRange: String, CaseIterable, Identifiable {
    case day, week, month, year, all, custom
    var id: String { rawValue }
    var component: Calendar.Component? {
        switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        case .all, .custom: nil
        }
    }
    func interval(at anchor: Date, through end: Date, calendar: Calendar = Dates.calendar) -> DateInterval? {
        if let component { return calendar.dateInterval(of: component, for: anchor) }
        guard self == .custom else { return nil }
        let start = calendar.startOfDay(for: min(anchor, end))
        let upper = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(anchor, end)))!
        return DateInterval(start: start, end: upper)
    }
}
