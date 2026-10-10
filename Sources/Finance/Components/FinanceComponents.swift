import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Charts
#if os(iOS)
import UIKit
#endif

extension MoneyColor {
    static func color(_ key: String) -> Color {
        switch key {
        case "coral": Color(red: 0.93, green: 0.42, blue: 0.33)
        case "orange": .orange
        case "amber": Color(red: 0.88, green: 0.62, blue: 0.12)
        case "green": .green
        case "teal": .teal
        case "blue": .blue
        case "indigo": .indigo
        case "purple": .purple
        case "pink": .pink
        case "red": .red
        case "brown": .brown
        default: .gray
        }
    }
}

/// Round tinted symbol used for categories and accounts, so a glance tells food from transport.
struct MoneyGlyph: View {
    let symbol: String
    var emoji: String? = nil
    var body: some View {
        if let emoji, TaskList.validEmoji(emoji) { Text(emoji) }
        else { Image(systemName: symbol) }
    }
}
// Native menus require an Image in the icon slot; rendering each emoji once keeps titles aligned.
@MainActor private enum MoneyMenuEmoji {
    private static var images: [String: Image] = [:]
    static func image(_ emoji: String) -> Image {
        if let image = images[emoji] { return image }
        let renderer = ImageRenderer(content: Text(emoji).font(.system(size: 20)).frame(width: 24, height: 24))
        renderer.scale = 2
        #if os(iOS)
        let image = renderer.uiImage.map { Image(uiImage: $0).renderingMode(.original) } ?? Image(systemName: "tag")
        #else
        let image = renderer.nsImage.map { Image(nsImage: $0).renderingMode(.original) } ?? Image(systemName: "tag")
        #endif
        images[emoji] = image
        return image
    }
}
struct MoneyMenuLabel: View {
    let title: String
    let symbol: String
    var emoji: String? = nil
    var body: some View {
        Label { Text(title) } icon: {
            if let emoji, TaskList.validEmoji(emoji) { MoneyMenuEmoji.image(emoji) }
            else { Image(systemName: symbol) }
        }
    }
}
struct MoneyIcon: View {
    let symbol: String
    var emoji: String? = nil
    let tint: Color
    var size: CGFloat = 36
    var body: some View {
        MoneyGlyph(symbol: symbol, emoji: emoji)
            .font(.system(size: size * (emoji == nil ? 0.44 : 0.58), weight: .medium))
            .foregroundStyle(tint).frame(width: size, height: size)
            .background(tint.opacity(0.16), in: Circle())
    }
}

struct MoneyIconPicker: View {
    @Binding var symbol: String
    @Binding var emoji: String
    let fallback: String
    @State private var useEmoji = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var emojiFocused: Bool
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L("选择图标", "Choose an icon")).font(.headline)
                Spacer()
                Button(L("完成", "Done")) { emojiFocused = false; dismiss() }
                    .frame(minHeight: 44)
            }
            Picker(L("图标类型", "Icon type"), selection: $useEmoji) {
                Text(L("系统图标", "Symbols")).tag(false)
                Text(L("表情", "Emoji")).tag(true)
            }.pickerStyle(.segmented).labelsHidden()
            if useEmoji {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("使用任意表情", "Use any emoji")).font(.subheadline.weight(.medium))
                    TextField(L("输入或粘贴一个表情", "Type or paste one emoji"), text: $emoji)
                        .textFieldStyle(.roundedBorder).font(.title3).frame(minHeight: 44).focused($emojiFocused)
                        .accessibilityLabel(L("图标表情", "Icon emoji"))
                        .autocorrectionDisabled()
                        .onChange(of: emoji) { _, value in
                            if value.count > 1, let last = value.last { emoji = String(last) }
                        }
                        .onSubmit { emojiFocused = false }
                    #if os(iOS)
                    Text(L("点输入框，再用键盘的笑脸或地球按钮切换到表情键盘；也可以粘贴表情。", "Tap the field, then use the keyboard’s smiley or globe key to choose any emoji. You can also paste one."))
                        .font(.caption).foregroundStyle(.secondary)
                    #else
                    Button(L("打开系统表情选择器…", "Open emoji picker…")) {
                        emojiFocused = true
                        DispatchQueue.main.async { NSApp.orderFrontCharacterPalette(nil) }
                    }.frame(minHeight: 44)
                    #endif
                    if !emoji.isEmpty && !TaskList.validEmoji(emoji) {
                        Text(L("请输入一个表情符号。", "Enter one emoji character.")).font(.caption).foregroundStyle(.red)
                    }
                }
                Text(L("常用表情", "Suggestions")).font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 8) {
                    ForEach(["🏠", "✈️", "💳", "🏦", "💰", "☕", "🍜", "🛍️", "🎮", "🚗", "📚", "🎁"], id: \.self) { item in
                        Button { emoji = item } label: {
                            Text(item).font(.title2).frame(width: 44, height: 44)
                                .background(emoji == item ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).accessibilityLabel(item)
                    }
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 8) {
                    ForEach(FinanceEntityEditor.symbols, id: \.self) { item in
                        Button { symbol = item; emoji = "" } label: {
                            Image(systemName: item).font(.system(size: 15)).frame(width: 44, height: 44)
                                .background(emoji.isEmpty && (symbol.isEmpty ? fallback : symbol) == item ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain).accessibilityLabel(item).accessibilityAddTraits(symbol == item && emoji.isEmpty ? [.isSelected] : [])
                    }
                }
            }
            Button(L("恢复默认图标", "Use default icon")) { symbol = ""; emoji = "" }
                .font(.caption)
        }.padding(16)
        }
        #if os(macOS)
        .frame(width: 360, height: 500)
        #else
        .frame(maxWidth: .infinity)
        .presentationCompactAdaptation(.sheet)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
        .onAppear { useEmoji = !emoji.isEmpty }
    }
}

/// Capsule look shared by the entry sheet's date, account and book controls.
struct MoneyChip: ViewModifier {
    var expanded = false
    func body(content: Content) -> some View {
        content.font(.callout).padding(.horizontal, 10).padding(.vertical, expanded ? 8 : 5)
            .frame(maxWidth: expanded ? .infinity : nil, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: expanded ? Design.Radius.large : Design.Radius.medium, style: .continuous).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: expanded ? Design.Radius.large : Design.Radius.medium, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            #if os(iOS)
            .frame(minHeight: 44).contentShape(Rectangle())
            #endif
    }
}

struct MoneyKeyStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View { Key(configuration: configuration, prominent: prominent) }
    private struct Key: View {
        let configuration: Configuration
        let prominent: Bool
        @Environment(\.colorScheme) private var scheme
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        // The app accent is dark green in light mode and pale green in dark mode.
        var body: some View {
        configuration.label
            .font(.system(size: 17, weight: .medium, design: .rounded))
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(prominent ? (scheme == .dark ? Color.black.opacity(0.82) : Color.white) : Color.primary)
            .opacity(enabled ? 1 : 0.45)
            .background(RoundedRectangle(cornerRadius: 9).fill(prominent ? Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1) : Color.primary.opacity(configuration.isPressed ? 0.15 : 0.06)))
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

enum MoneyPeriod: String, CaseIterable, Identifiable {
    case week, month, year
    var id: String { rawValue }
    var label: String {
        switch self { case .week: L("周", "Week"); case .month: L("月", "Month"); case .year: L("年", "Year") }
    }
    var component: Calendar.Component {
        switch self { case .week: .weekOfYear; case .month: .month; case .year: .year }
    }
    var current: String {
        switch self { case .week: L("本周", "This week"); case .month: L("本月", "This month"); case .year: L("今年", "This year") }
    }
}

extension MoneyDateRange {
    var label: String {
        switch self {
        case .day: L("日", "Day")
        case .week: L("周", "Week")
        case .month: L("月", "Month")
        case .year: L("年", "Year")
        case .all: L("全部日期", "All dates")
        case .custom: L("自定义", "Custom")
        }
    }
    var current: String {
        switch self {
        case .day: L("今天", "Today")
        case .week: L("本周", "This week")
        case .month: L("本月", "This month")
        case .year: L("今年", "This year")
        case .all, .custom: label
        }
    }
}

extension FinanceData {
    func category(_ id: UUID?) -> MoneyCategory? { id.flatMap { id in categories.first { $0.id == id } } }
    func account(_ id: UUID?) -> MoneyAccount? { id.flatMap { id in accounts.first { $0.id == id } } }
    func book(_ id: UUID?) -> MoneyBook? { id.flatMap { id in books.first { $0.id == id } } }
    func tint(_ category: MoneyCategory?) -> Color { category.map { MoneyColor.color($0.resolvedColor) } ?? .gray }
    func icon(_ e: MoneyEntry) -> (symbol: String, emoji: String?, tint: Color) {
        switch e.kind {
        case .transfer: return ("arrow.left.arrow.right", nil, .gray)
        case .adjustment: return ("slider.horizontal.3", nil, .gray)
        default:
            guard let c = category(e.categoryID) else { return (e.kind == .income ? "banknote" : "tag", nil, .gray) }
            return (c.symbol, c.emoji, MoneyColor.color(c.resolvedColor))
        }
    }
    /// The category used last for this direction, else the first active one.
    func defaultCategory(income: Bool) -> UUID? {
        let active = categories.filter { !$0.archived && $0.isIncome == income }
        if let raw = UserDefaults.standard.string(forKey: "lastMoneyCategory." + (income ? "income" : "expense")),
           let hit = active.first(where: { $0.id.uuidString == raw }) { return hit.id }
        return active.first?.id
    }
}

extension FinanceData {
    /// Overview balances describe an explicit scope, never the last-used entry defaults.
    func balanceAccount(bookID: UUID?, filteredAccountID: UUID?) -> MoneyAccount? {
        if let filteredAccountID { return account(filteredAccountID) }
        return account(defaultAccount(for: bookID))
    }

    /// Shared entry/currency defaults; resolving these never creates a temporary entry.
    func entryDefaults(preferredBook: UUID?, preferredAccount: UUID? = nil) -> (book: MoneyBook?, account: MoneyAccount?) {
        let active = books.filter { !$0.archived }
        let recent = active.first { $0.id.uuidString == UserDefaults.standard.string(forKey: "lastMoneyBook") }
        let book = active.first { $0.id == preferredBook } ?? recent ?? active.first
        var accountID = defaultAccount(for: book?.id)
        if accountID == nil && book?.defaultAccountID == nil {
            // "none" remembers a deliberate choice; a forgotten or removed account falls back to the first one.
            let raw = UserDefaults.standard.string(forKey: "lastMoneyAccount"), usable = accounts.filter { !$0.archived }
            if raw != "none" { accountID = usable.first { $0.id.uuidString == raw }?.id ?? usable.first?.id }
        }
        if let id = preferredAccount, account(id)?.archived == false { accountID = id }
        return (book, account(accountID))
    }
    func newEntry(preferredBook: UUID?, preferredAccount: UUID? = nil) -> MoneyEntry {
        let defaults = entryDefaults(preferredBook: preferredBook, preferredAccount: preferredAccount)
        var entry = MoneyEntry()
        entry.bookID = defaults.book?.id; entry.accountID = defaults.account?.id
        entry.currency = defaults.account?.currency ?? baseCurrency
        entry.categoryID = defaultCategory(income: false)
        return entry
    }
    /// Keep a parent immediately before its children in every menu.
    var orderedCategories: [MoneyCategory] {
        categories.filter { $0.parentID == nil }.flatMap { parent in
            [parent] + categories.filter { $0.parentID == parent.id }
        }
    }
    var hasSamples: Bool {
        accounts.contains { Self.isSample($0.name) } || books.contains { Self.isSample($0.name) } || entries.contains { Self.isSample($0.title) }
    }
}

/// Hover state kept per row, so moving the pointer never re-renders a whole page.
struct MoneyHover<Content: View>: View {
    @State private var hovering = false
    @ViewBuilder let content: (Bool) -> Content
    var body: some View { content(hovering).onHover { inside in if inside != hovering { hovering = inside } } }
}

/// Keep chart hover local: highlighting a bar must not refilter the ledger or recalculate rankings.
struct MoneyChartHover<Content: View>: View {
    @State private var date: Date?
    @ViewBuilder var content: (Binding<Date?>) -> Content
    var body: some View { content($date) }
}

/// Common currencies first; the rest of the reference-rate currencies one level down.
struct CurrencyChoices: View {
    let pick: (String) -> Void
    var body: some View {
        ForEach(Money.common, id: \.self) { c in Button(Money.name(c) + " · " + c) { pick(c) } }
        Menu(L("更多币种", "More currencies")) {
            ForEach(Money.more, id: \.self) { c in Button(Money.name(c) + " · " + c) { pick(c) } }
        }
    }
}
struct CurrencyPickerItems: View {
    var body: some View {
        Section(L("常用", "Common")) { ForEach(Money.common, id: \.self) { Text(Money.name($0) + " · " + $0).tag($0) } }
        Section(L("更多币种", "More currencies")) { ForEach(Money.more, id: \.self) { Text(Money.name($0) + " · " + $0).tag($0) } }
    }
}

extension Array where Element: Identifiable {
    /// Edits keep their place in the sidebar and grids; new items go last.
    mutating func upsert(_ value: Element) {
        if let i = firstIndex(where: { $0.id == value.id }) { self[i] = value } else { append(value) }
    }
}

func double(_ value: Decimal) -> Double { NSDecimalNumber(decimal: value).doubleValue }

/// Page navigation exposes only the active tab and a selection action.
struct FinancePageTabs: View {
    @AppStorage("appLanguage") private var language = "system"
    let active: String
    let dynamicTypeSize: DynamicTypeSize
    let select: (String) -> Void

    var body: some View {
        (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))) {
            ForEach([("all", L("账单", "Entries")), ("stats", L("统计", "Statistics")), ("accounts", L("资产", "Assets"))], id: \.0) { key, title in
                Button {
                    select(key)
                } label: {
                    Text(title).font(.subheadline.weight(active == key ? .semibold : .regular))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(active == key ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(active == key ? Color.accentColor : .secondary)
                    .accessibilityAddTraits(active == key ? [.isSelected] : [])
            }
        }.padding(4).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16).padding(.vertical, 6)
    }
}
