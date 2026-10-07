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
    var isValidReference: Bool {
        !isManual && Money.currencies.contains(base) && Money.currencies.contains(quote) && base != quote
            && Self.valid(rate) && date.count == 10 && fetchedAt.timeIntervalSince1970.isFinite && source.count <= 80
    }
    static func valid(_ rate: Decimal) -> Bool {
        !rate.isNaN && rate >= Decimal(string: "0.000000001")! && rate < 1_000_000_000
    }
}
/// Current valuation may cross two stored quotes; retain both dates and manual provenance.
struct MoneyAssetRate: Equatable {
    var rate: Decimal
    var quotes: [MoneyRate]
    var isManual: Bool { quotes.contains(where: \.isManual) }
    var referenceDates: [String] { Set(quotes.filter { !$0.isManual }.map(\.date)).sorted() }
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
    let accountCurrencies: [UUID: String]
}
