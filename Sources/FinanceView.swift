import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Charts
#if os(iOS)
import UIKit
#endif

struct AppSectionPicker: View {
    @AppStorage("appLanguage") private var language = "system"
    @Binding var finance: Bool
    var body: some View {
        Picker(L("功能", "Workspace"), selection: $finance) {
            Text(L("待办", "Tasks")).tag(false)
            Text(L("财务", "Finance")).tag(true)
        }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 14)
    }
}

// MARK: - Shared pieces

/// Only the ranking reads this observable property during rendering. Opening a row
/// doesn't recompute FinanceHome's charts, filtered entries or asset summaries.
@Observable private final class MoneyRankingExpansion { var key: MoneyCategoryKey? }
private struct MoneyRanking<Row: View, Detail: View>: View {
    let rows: [MoneyCategoryTotal]
    let expansion: MoneyRankingExpansion
    @ViewBuilder var row: (MoneyCategoryTotal) -> Row
    @ViewBuilder var detail: (MoneyCategoryTotal) -> Detail
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L("点一个分类，看它每个月的变化", "Click a category to see it month by month")).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 8)
            ForEach(rows) { item in
                let open = expansion.key == item.id
                MoneyHover { hovering in
                    Button {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { expansion.key = open ? nil : item.id }
                    } label: {
                        HStack(spacing: 12) {
                            row(item)
                            Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }.padding(.vertical, 8).padding(.horizontal, 10).contentShape(Rectangle())
                            .background(RoundedRectangle(cornerRadius: 10).fill(hovering || open ? Color.primary.opacity(0.05) : .clear))
                    }.buttonStyle(.plain)
                }
                if open { detail(item) }
            }
        }.background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.035)))
    }
}

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
private struct MoneyMenuLabel: View {
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

private struct MoneyIconPicker: View {
    @Binding var symbol: String
    @Binding var emoji: String
    let fallback: String
    @State private var useEmoji = false
    @FocusState private var emojiFocused: Bool
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            Picker(L("图标类型", "Icon type"), selection: $useEmoji) {
                Text(L("系统图标", "Symbols")).tag(false)
                Text(L("表情", "Emoji")).tag(true)
            }.pickerStyle(.segmented).labelsHidden()
            if useEmoji {
                HStack {
                    TextField("🙂", text: $emoji).textFieldStyle(.roundedBorder).frame(width: 60).focused($emojiFocused)
                        .accessibilityLabel(L("图标表情", "Icon emoji"))
                        .onChange(of: emoji) { _, value in if value.count > 1 { emoji = String(value.last!) } }
                    #if os(macOS)
                    Button(L("更多表情…", "More emoji…")) {
                        emojiFocused = true
                        DispatchQueue.main.async { NSApp.orderFrontCharacterPalette(nil) }
                    }
                    #endif
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 8) {
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
        .frame(width: 340, height: 470)
        #else
        .frame(maxWidth: 340)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        .onAppear { useEmoji = !emoji.isEmpty }
    }
}

/// Capsule look shared by the entry sheet's date, account and book controls.
private struct MoneyChip: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.callout).padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
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
    /// Shared by the entry form and its overview; resolving defaults does not create a temporary entry.
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
private struct MoneyChartHover<Content: View>: View {
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

private func double(_ value: Decimal) -> Double { NSDecimalNumber(decimal: value).doubleValue }

/// A thin colored bar; the system progress bar ignores category colors on the Mac.
struct MoneyBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Double
    let tint: Color
    var body: some View {
        Capsule().fill(Color.primary.opacity(0.08)).frame(height: 5)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in Capsule().fill(tint).frame(width: proxy.size.width * min(1, max(0, value))) }
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: value)
    }
}

// MARK: - Sidebar

#if os(macOS)
struct FinanceSidebar: View {
    @AppStorage("appLanguage") private var language = "system"
    @Binding var selection: String
    var body: some View {
        List(selection: $selection) {
            Label(L("账单", "Entries"), systemImage: "list.bullet.rectangle").tag("all")
            Label(L("统计", "Statistics"), systemImage: "chart.bar").tag("stats")
            Label(L("资产", "Assets"), systemImage: "wallet.pass").tag("accounts")
            Section {
                Label(L("记账管理", "Manage finance"), systemImage: "slider.horizontal.3").tag("manage")
                Label(L("最近删除", "Recently deleted"), systemImage: "trash").tag("trash")
            }
        }.foregroundStyle(.primary)
    }
}

#endif

private struct FinanceSearch: ViewModifier {
    let enabled: Bool
    @Binding var text: String
    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            #if os(iOS)
            content.searchable(text: $text, placement: .toolbar, prompt: L("搜索账单、备注、标签", "Search entries, notes and tags"))
                .modifier(PhoneSearchToolbar())
            #else
            content.searchable(text: $text, prompt: L("搜索账单、备注、标签", "Search entries, notes and tags"))
            #endif
        } else { content }
    }
}

struct FinanceCSV: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var data: Data
    init(_ text: String) { data = Data(text.utf8) }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

// MARK: - Main pages

struct FinanceHome: View {
    /// Value-sized view trees are copied through several nested builders. Keep each
    /// screen well below the 1 MB stack in the iPhone build 65 crash reports.
    static func checkViewFootprint() throws -> Int {
        func size<V: View>(_: (FinanceHome) -> V) -> Int { MemoryLayout<V>.size }
        let sizes = ["body": size { $0.body }, "entries": size { $0.billsPage },
                     "statistics": size { $0.statisticsPage }, "assets": size { $0.assetsPage },
                     "management": size { $0.managementPage }, "header": size { $0.periodHeader }]
        print("Finance view sizes (bytes): \(sizes)")
        guard sizes.values.allSatisfy({ $0 < 16_384 }) else {
            throw TaskBackup.invalid("Finance view exceeds the 16 KB per-component stack budget: \(sizes)")
        }
        return sizes.count
    }
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compact: Bool { sizeClass == .compact }
    #else
    private var compact: Bool { false }
    #endif
    @Environment(EditorDrafts.self) private var drafts
    @State private var generation = Store.recovery.generation
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var selection: String
    var openTask: (UUID) -> Void
    var settings: () -> Void
    @Environment(\.modelContext) private var context
    @Query private var records: [FinanceLedger]
    @AppStorage("hideMoney") private var hidden = false
    @AppStorage("appLanguage") private var language = "system"
    @AppStorage("moneyBookScope") private var scope = ""
    @AppStorage("moneyAutoRates") private var automaticRates = true
    @State private var data = FinanceData.initial
    @State private var loadedPayload: Data?
    @State private var loadingError: String?
    @State private var error: String?
    @State private var anchor = Date()
    @State private var period = MoneyPeriod.month
    @State private var statsIncome = false
    @State private var dateRange = MoneyDateRange.month
    @State private var showDateRange = false
    @State private var fixedRange: DateInterval?
    @State private var customStart = Date()
    @State private var customEnd = Date()
    @State private var search = ""
    @State private var accountDetailID: UUID?
    @AppStorage("moneyRunningBalances") private var showRunningBalances = false
    @State private var accountFilter: UUID?
    @State private var drilldown: MoneyDrilldown?
    @State private var categoryFilter: UUID?
    @State private var kindFilter: MoneyKind?
    @State private var editor: EntryRequest?
    @State private var entity: EntityRequest?
    @State private var lastDeleted: MoneyEntry?
    @State private var confirmDelete: MoneyEntry?
    @State private var showArchivedAccounts = false
    @State private var rangeBeforeAccount: MoneyDateRange?
    @State private var confirmSamples = false
    @State private var info: String?
    @AppStorage("moneyStatsCurrency") private var statsCurrencyRaw = ""
    @State private var entriesCurrencyRaw = ""
    @AppStorage("moneyStatsCalendar") private var statsCalendar = false
    @State private var rankingExpansion = MoneyRankingExpansion()
    /// Where Statistics was when one of its bars, days or categories opened the entry list.
    private struct StatsPlace { var anchor: Date; var period: MoneyPeriod; var income: Bool; var expanded: MoneyCategoryKey?; var billRange: MoneyDateRange }
    @State private var statsReturn: StatsPlace?
    @State private var rateHistory: RateHistory?
    @State private var loadingRates = false
    @State private var refreshing = false
    @State private var rateRefreshError: String?
    @State private var showAssetRates = false
    @State private var conversionRequest: MoneyConversionRequest?
    @State private var lastAutomaticRateAttempt: Date?
    @State private var automaticRateRetryAfter: Date?
    @State private var lastAutomaticRateKey = ""
    @State private var foreignCurrency = ""
    @State private var document: FinanceCSV?
    @State private var exporting = false

    private var presentationActive: Bool {
        editor != nil || entity != nil || conversionRequest != nil || showAssetRates || exporting || showDateRange
            || error != nil || info != nil || confirmDelete != nil || confirmSamples
    }

    /// Nil means every book.
    private var bookFilterID: UUID? { data.books.first { $0.id.uuidString == scope }?.id }
    private var scopeName: String { data.book(bookFilterID)?.name ?? L("全部账本", "All books") }
    private var range: DateInterval { Dates.calendar.dateInterval(of: period.component, for: anchor)! }
    private var billRange: DateInterval? { drilldown?.range ?? (dateRange == .custom ? fixedRange : dateRange.interval(at: anchor, through: customEnd)) }
    private var selectedAccount: MoneyAccount? { data.account(accountDetailID) }

    private var entryDefaults: (book: MoneyBook?, account: MoneyAccount?) {
        data.entryDefaults(preferredBook: bookFilterID, preferredAccount: accountFilter)
    }
    private var defaultEntriesCurrency: String { data.account(accountFilter)?.currency ?? entryDefaults.account?.currency ?? data.baseCurrency }
    private var entryDefaultsKey: String {
        [scope, accountFilter?.uuidString ?? "", entryDefaults.book?.id.uuidString ?? "", entryDefaults.account?.id.uuidString ?? "", defaultEntriesCurrency].joined(separator: "/")
    }
    private var entriesCurrency: String {
        selectedAccount?.currency ?? (Money.currencies.contains(entriesCurrencyRaw) ? entriesCurrencyRaw : defaultEntriesCurrency)
    }
    private func entryTotals(_ entries: [MoneyEntry], income: Bool) -> MoneyStatisticsTotal {
        data.statisticsTotal(entries, income: income, in: entriesCurrency, history: rateHistory, days: rateHistory?.sortedDays)
    }
    private func totalDisplay(_ total: MoneyStatisticsTotal, currency: String? = nil, subtotal: Bool = false) -> String {
        if hidden { return "••••" }
        if total.missing > 0 && total.convertedCount == 0 { return L("待折算", "Unconverted") }
        return (total.estimateDates.isEmpty ? "" : "≈ ") + display(total.total, currency ?? entriesCurrency)
            + (subtotal && total.missing > 0 ? L(" · 小计", " · subtotal") : "")
    }
    private func totalLabel(_ label: String, _ total: MoneyStatisticsTotal) -> String {
        total.missing > 0 && total.convertedCount > 0 ? label + L(" · 已折算小计", " · converted subtotal") : label
    }
    private func balanceDisplay(spent: MoneyStatisticsTotal, earned: MoneyStatisticsTotal, currency: String) -> String {
        if hidden { return "••••" }
        guard spent.missing + earned.missing == 0 else { return L("待折算", "Unconverted") }
        return ((!spent.estimateDates.isEmpty || !earned.estimateDates.isEmpty) ? "≈ " : "") + display(earned.total - spent.total, currency)
    }
    private var filtered: [MoneyEntry] {
        let trash = selection == "trash"
        let limit = trash ? nil : billRange
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return data.entries.filter { e in
            guard trash ? e.deletedAt != nil : e.deletedAt == nil else { return false }
            if let drilldown, !drilldown.matches(e, data: data) { return false }
            if let limit, e.date < limit.start || e.date >= limit.end { return false }
            // Asset details cover all books; normal entry filters retain the book/account intersection.
            if !e.matches(bookID: accountDetailID == nil ? bookFilterID : nil, accountID: accountDetailID ?? accountFilter) { return false }
            if let categoryFilter, !data.categoryMatches(e.categoryID, filterID: categoryFilter) { return false }
            if let kindFilter, e.kind != kindFilter { return false }
            if !text.isEmpty && !data.searchText(for: e).localizedCaseInsensitiveContains(text) { return false }
            return true
        }.sorted(by: MoneyEntry.newestFirst)
    }

    // Erase only these stable screen boundaries, never individual ledger rows.
    // Otherwise all page/header value types compound through the parent builders
    // and exhaust the 1 MB device stack before SwiftUI can render the first frame.
    private var page: AnyView {
        if let loadingError {
            return AnyView(ContentUnavailableView { Label(L("无法读取账目", "Unable to read ledger"), systemImage: "exclamationmark.triangle") } description: { Text(loadingError) } actions: { Button(L("重试", "Retry"), action: reload) })
        }
        switch selection {
        case "accounts": return AnyView(assetsPage)
        case "manage": return AnyView(managementPage)
        case "stats": return AnyView(statisticsPage)
        default: return AnyView(billsPage)
        }
    }

    var body: some View {
        ZStack {
            page.id(selection).transition(.opacity)
        }
        .animation(compact && !reduceMotion ? .easeInOut(duration: 0.18) : nil, value: selection)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: settings) { Label(L("设置", "Settings"), systemImage: "gearshape") }
            }
            #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button(L("账单", "Entries"), systemImage: "list.bullet.rectangle") { selection = "all" }
                    Button(L("统计", "Statistics"), systemImage: "chart.bar") { selection = "stats" }
                    Button(L("资产", "Assets"), systemImage: "wallet.pass") { selection = "accounts" }
                    Divider()
                    Button(L("记账管理", "Manage finance"), systemImage: "slider.horizontal.3") { selection = "manage" }
                    Button(L("最近删除", "Recently deleted"), systemImage: "trash") { selection = "trash" }
                    Divider()
                    Button(hidden ? L("显示金额", "Show amounts") : L("隐藏金额", "Hide amounts"), systemImage: hidden ? "eye.slash" : "eye") { hidden.toggle() }
                    Button(L("设置与备份", "Settings & backup"), systemImage: "gearshape", action: settings)
                } label: { Label(L("记账页面", "Finance pages"), systemImage: "line.3.horizontal") }
            }
            #endif

            #if os(macOS)
            ToolbarItem {
                Button { hidden.toggle() } label: { Label(hidden ? L("显示金额", "Show amounts") : L("隐藏金额", "Hide amounts"), systemImage: hidden ? "eye.slash" : "eye") }
            }
            #endif
            ToolbarItem(placement: .primaryAction) {
                Button(action: newEntry) { Label(L("记一笔", "New entry"), systemImage: "plus") }
                    #if os(iOS)
                    .labelStyle(.iconOnly)
                    #else
                    .labelStyle(.titleAndIcon)
                    #endif
                    .keyboardShortcut("n", modifiers: .command).disabled(loadingError != nil)
            }
        }
        .modifier(FinanceSearch(enabled: selection == "all" || selection == "trash", text: $search))
        .task(id: records.first?.payload) { reload() }
        .onAppear {
            if let kept = drafts.finance { editor = EntryRequest(entry: kept.entry, expected: kept.expected) }
            else if let kept = drafts.financeEntity { entity = EntityRequest(kind: kept.kind, existingID: kept.id, income: kept.income) }
        }
        .onChange(of: presentationActive, initial: true) { _, active in
            guard generation == Store.recovery.generation else { return }
            drafts.financePresentationGeneration = active ? generation : nil
        }
        .onDisappear {
            if drafts.financePresentationGeneration == generation { drafts.financePresentationGeneration = nil }
        }
        .onChange(of: selection) { old, new in
            if new != "all" { drilldown = nil; accountDetailID = nil; accountFilter = nil; categoryFilter = nil; kindFilter = nil; search = ""; statsReturn = nil }
            if old == "trash" { dateRange = .month }
        }
        .onChange(of: scope) { _, _ in drilldown = nil }
        // A display override belongs to this scope, never to a different book or a changed default account.
        .onChange(of: entryDefaultsKey) { _, _ in entriesCurrencyRaw = "" }
        // The request carries whether this is an existing entry, so the sheet never guesses from other state.
        .sheet(item: $editor, onDismiss: reload) { request in FinanceEntryEditor(entry: request.entry, expected: request.expected) }
        .sheet(item: $entity, onDismiss: reload) { item in FinanceEntityEditor(kind: item.kind, id: item.existingID, income: item.income, parentID: item.parentID, data: data) }
        .sheet(item: $conversionRequest, onDismiss: reload) { request in FinanceConversionPreview(ledger: request.ledger) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && selection == "accounts" { Task { await refreshStaleAssetRates() } }
        }
        .sheet(isPresented: $showAssetRates, onDismiss: { reload(); if automaticRates { refreshRates() } }) { FinanceRateEditor(data: data) }
        .fileExporter(isPresented: $exporting, document: document, contentType: .commaSeparatedText, defaultFilename: "Tally-Ledger") { result in if case .failure(let failure) = result { error = failure.localizedDescription } }
        .alert(L("未完成操作", "Operation not completed"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button(L("知道了", "OK"), role: .cancel) {} } message: { Text(error ?? "") }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
            Button(L("删除账单", "Delete entry"), role: .destructive) { if let entry = confirmDelete { delete(entry) }; confirmDelete = nil }
            Button(L("取消", "Cancel"), role: .cancel) { confirmDelete = nil }
        }
        .confirmationDialog(L("清除示例数据？", "Clear the example data?"), isPresented: $confirmSamples, titleVisibility: .visible) {
            Button(L("清除示例数据", "Clear example data"), role: .destructive, action: clearSamples)
            Button(L("取消", "Cancel"), role: .cancel) {}
        } message: { Text(sampleMessage) }
        .alert(L("已完成", "Done"), isPresented: Binding(get: { info != nil }, set: { if !$0 { info = nil } })) { Button(L("好", "OK"), role: .cancel) {} } message: { Text(info ?? "") }
        .onChange(of: accountDetailID) { old, new in
            // Leaving an account's history returns to the date range used before it.
            if old != nil && new == nil { dateRange = rangeBeforeAccount ?? .month; rangeBeforeAccount = nil }
        }
        .safeAreaInset(edge: .bottom) {
            if let lastDeleted {
                HStack {
                    Text(L("已删除账单", "Entry deleted")); Spacer()
                    Button(L("撤销", "Undo")) { restore(lastDeleted) }
                    Button { self.lastDeleted = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel(L("关闭提示", "Dismiss"))
                }.padding(12).background(.regularMaterial)
            }
        }
    }
    private var deleteTitle: String {
        let refunds = confirmDelete.map { $0.kind == .expense ? data.liveRefunds(of: $0.id).count : 0 } ?? 0
        return refunds > 0
            ? L("这笔消费有 \(refunds) 笔退款，会一起移到最近删除。余额和统计会同步更新。", "This purchase has \(refunds) refunds; they move to Recently deleted with it. Balances and totals will update.")
            : L("将账单移到最近删除？余额和统计会同步更新。", "Move this entry to Recently deleted? Balances and totals will update.")
    }
    private var title: String {
        switch selection {
        case "accounts": return L("资产", "Assets")
        case "stats": return L("统计", "Statistics")
        case "manage": return L("记账管理", "Manage finance")
        case "trash": return L("最近删除", "Recently deleted")
        default: return selectedAccount?.name ?? L("账单", "Entries")
        }
    }
    private func display(_ value: Decimal, _ currency: String? = nil) -> String { hidden ? "••••" : Money.format(value, currency ?? data.baseCurrency) }

    // MARK: Header and filters

    private var isCurrentPeriod: Bool {
        let component = selection == "stats" ? period.component : dateRange.component
        return component.map { Dates.calendar.isDate(anchor, equalTo: Date(), toGranularity: $0) } ?? true
    }
    private func intervalTitle(_ interval: DateInterval) -> String {
        let end = interval.end.addingTimeInterval(-1)
        let sameYear = Dates.calendar.component(.year, from: interval.start) == Dates.calendar.component(.year, from: end)
        return Dates.label(interval.start, pattern: "yyyy年M月d日") + " – " + Dates.label(end, pattern: sameYear ? "M月d日" : "yyyy年M月d日")
    }
    private var periodTitle: String {
        if let drilldown { return intervalTitle(drilldown.range) }
        if selection == "stats" {
            switch period {
            case .week: return intervalTitle(range)
            case .month: return Dates.label(anchor, pattern: "yyyy年M月")
            case .year: return Dates.label(anchor, pattern: "yyyy年")
            }
        }
        switch dateRange {
        case .all: return L("全部日期", "All dates")
        case .day: return Dates.label(anchor, pattern: "yyyy年M月d日")
        case .month: return Dates.label(anchor, pattern: "yyyy年M月")
        case .year: return Dates.label(anchor, pattern: "yyyy年")
        case .week, .custom: return billRange.map(intervalTitle) ?? ""
        }
    }
    private var periodHeader: AnyView {
        let stats = selection == "stats"
        let canShift = drilldown == nil && (stats || dateRange.component != nil)
        return AnyView(VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
            if !compact && accountDetailID == nil { bookSelector; Divider().frame(height: 18) }
            if canShift {
                Button { shift(-1) } label: { Image(systemName: "chevron.left").frame(width: compact ? 44 : 24, height: compact ? 44 : 24).contentShape(Rectangle()) }.help(L("上一段", "Previous"))
            }
            if canShift {
                DateChoiceButton(label: periodTitle, date: $anchor) { drilldown = nil }
                    .font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            } else {
                Text(periodTitle).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(compact ? 2 : 1).minimumScaleFactor(0.8)
            }
            if canShift {
                Button { shift(1) } label: { Image(systemName: "chevron.right").frame(width: compact ? 44 : 24, height: compact ? 44 : 24).contentShape(Rectangle()) }.help(L("下一段", "Next"))
            }
            if canShift && !isCurrentPeriod && !compact {
                Button(stats ? period.current : dateRange.current) { anchor = Date() }.controlSize(.small)
            }
            Spacer(minLength: 4)
            if !compact {
            if stats {
                statsCurrencyMenu
                Picker(L("周期", "Period"), selection: $period) { ForEach(MoneyPeriod.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 150)
            } else {
                if accountDetailID == nil { entriesCurrencyMenu }
                dateRangeMenu
                filterMenu
            }
            }
        }
        if compact {
            if canShift && !isCurrentPeriod {
                Button(stats ? period.current : dateRange.current) { anchor = Date() }.frame(minHeight: 44)
            }
            if accountDetailID == nil {
            ViewThatFits(in: .horizontal) {
                HStack {
                    bookSelector
                    Spacer(minLength: 8)
                    if stats { statsCurrencyMenu } else if accountDetailID == nil { entriesCurrencyMenu }
                }
                VStack(alignment: .leading, spacing: 4) {
                    if accountDetailID == nil { bookSelector }
                    if stats { statsCurrencyMenu } else if accountDetailID == nil { entriesCurrencyMenu }
                }
            }.frame(minHeight: 44)
            }
            if !stats {
                ViewThatFits(in: .horizontal) {
                    HStack { dateRangeMenu; Spacer(minLength: 12); filterMenu }
                    VStack(alignment: .leading, spacing: 6) {
                        dateRangeMenu.frame(minHeight: 44)
                        filterMenu.frame(minHeight: 44)
                    }
                }.frame(minHeight: 44)
            }
            if stats {
                Picker(L("周期", "Period"), selection: $period) { ForEach(MoneyPeriod.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
            }
        }
        }.buttonStyle(.borderless))
    }
    private var dateRangeMenu: some View {
                Menu {
                    ForEach(MoneyDateRange.allCases) { choice in
                        Button(choice.label) {
                            if choice == .custom {
                                customStart = billRange?.start ?? anchor
                                customEnd = billRange?.end.addingTimeInterval(-1) ?? Date()
                                showDateRange = true
                            } else { drilldown = nil; dateRange = choice }
                        }
                    }
                } label: { Label(L("日期范围", "Date range"), systemImage: "calendar") }
                .fixedSize().popover(isPresented: $showDateRange) { customRangePicker }
    }
    private var customRangePicker: some View {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(L("日期范围", "Date range")).font(.headline)
                        DatePicker(L("开始", "From"), selection: $customStart, displayedComponents: .date)
                        DatePicker(L("结束", "Through"), selection: $customEnd, in: customStart..., displayedComponents: .date)
                        HStack {
                            Button(L("取消", "Cancel")) { showDateRange = false }
                            Spacer()
                            Button(L("应用", "Apply")) { fixedRange = MoneyDateRange.custom.interval(at: customStart, through: customEnd); anchor = customStart; dateRange = .custom; drilldown = nil; showDateRange = false }.buttonStyle(.borderedProminent)
                        }
                    }.padding(18).frame(width: 290)
                    .onChange(of: customStart) { _, value in if customEnd < value { customEnd = value } }
    }
    private var bookSelector: some View {
        Menu {
            Button(L("全部账本", "All books")) { scope = "" }
            ForEach(data.books.filter { !$0.archived }) { book in
                Button { scope = book.id.uuidString } label: {
                    MoneyMenuLabel(title: book.name, symbol: book.iconSymbol, emoji: book.emoji)
                }
            }
            if data.books.contains(where: \.archived) {
                Menu(L("已归档", "Archived")) {
                    ForEach(data.books.filter(\.archived)) { book in Button(book.name) { scope = book.id.uuidString } }
                }
            }
            Divider()
            Button(L("新建账本…", "New book…")) { entity = EntityRequest(kind: .book) }
            if let bookFilterID { Button(L("编辑账本…", "Edit book…")) { entity = EntityRequest(kind: .book, existingID: bookFilterID) } }
        } label: {
            MoneyMenuLabel(title: scopeName, symbol: data.book(bookFilterID)?.iconSymbol ?? "books.vertical", emoji: data.book(bookFilterID)?.emoji).lineLimit(1)
        }.menuStyle(.borderlessButton).frame(maxWidth: 170, alignment: .leading).help(L("切换账本", "Switch book"))
    }
    private func shift(_ n: Int) {
        guard let unit = selection == "stats" ? period.component : dateRange.component else { return }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { drilldown = nil; anchor = Dates.calendar.date(byAdding: unit, value: n, to: anchor) ?? anchor }
    }
    private var filterMenu: some View {
        Menu {
            if accountDetailID == nil {
                Picker(L("账户", "Account"), selection: $accountFilter) {
                    Text(L("全部账户", "All accounts")).tag(nil as UUID?)
                    ForEach(data.accounts) { Text($0.name).tag(Optional($0.id)) }
                }
            } else {
                Toggle(L("显示逐笔余额", "Show running balances"), isOn: $showRunningBalances)
                Divider()
            }
            Picker(L("分类", "Category"), selection: $categoryFilter) {
                Text(L("全部分类", "All categories")).tag(nil as UUID?)
                ForEach(data.orderedCategories) { Text(data.categoryPath($0.id)).tag(Optional($0.id)) }
            }
            Picker(L("类型", "Type"), selection: $kindFilter) {
                Text(L("全部类型", "All types")).tag(nil as MoneyKind?)
                ForEach(MoneyKind.allCases) { Text($0.label).tag(Optional($0)) }
            }
            Button(L("清除筛选", "Clear filters")) { drilldown = nil; accountFilter = nil; categoryFilter = nil; kindFilter = nil; search = "" }
            Divider()
            Button(L("导出筛选结果 CSV…", "Export filtered entries as CSV…")) { document = FinanceCSV(data.csv(filtered)); exporting = true }
        } label: {
            Label(L("筛选", "Filter"), systemImage: accountFilter != nil || categoryFilter != nil || kindFilter != nil ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }.fixedSize()
    }
    @ViewBuilder private var filterChips: some View {
        if drilldown != nil || accountFilter != nil || categoryFilter != nil || kindFilter != nil {
            ScrollView(.horizontal) {
            HStack(spacing: 6) {
                if let drilldown { chip(breakdownLabel(drilldown.key)) { self.drilldown = nil } }
                if let accountFilter { chip(L("账户：", "Account: ") + (data.account(accountFilter)?.name ?? "")) { self.accountFilter = nil } }
                
                if let categoryFilter { chip(L("分类：", "Category: ") + data.categoryPath(categoryFilter)) { self.categoryFilter = nil } }
                if let kindFilter { chip(kindFilter.label) { self.kindFilter = nil } }
            }
            }.scrollIndicators(.hidden)
        }
    }
    private func chip(_ text: String, clear: @escaping () -> Void) -> some View {
        Button(action: clear) {
            HStack(spacing: 5) { Text(text).lineLimit(1); Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                .font(.caption).padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(Color.accentColor.opacity(0.13))).foregroundStyle(Color.accentColor)
            .frame(minHeight: compact ? 44 : nil).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(L("清除筛选：", "Clear filter: ") + text).help(L("清除这个筛选", "Clear this filter"))
    }
    private func metric(_ label: String, _ value: String, size: CGFloat = 20) -> some View {
        let amount = Text(value)
            .font(compact ? (size >= 24 ? .title2.weight(.semibold) : .title3.weight(.semibold)) : .system(size: size, weight: .semibold))
            .monospacedDigit().fixedSize()
        return VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                amount
                ScrollView(.horizontal) { amount }
                    .scrollIndicators(.visible)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: compact ? .infinity : nil, alignment: .leading)
            .accessibilityElement(children: .ignore).accessibilityLabel(label).accessibilityValue(value)
    }

    private func metricPair(_ first: (String, String), _ second: (String, String)) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) {
                metric(first.0, first.1, size: 18).fixedSize(horizontal: true, vertical: false)
                metric(second.0, second.1, size: 18).fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 14) {
                metric(first.0, first.1, size: 18)
                metric(second.0, second.1, size: 18)
            }
        }.frame(maxWidth: compact ? .infinity : nil, alignment: .leading)
    }

    // MARK: Entries

    private var billsPage: some View {
        let entries = filtered
        let trash = selection == "trash"
        let days = Dictionary(grouping: entries) { Dates.calendar.startOfDay(for: $0.date) }
        let keys = days.keys.sorted(by: >)
        let showBook = accountDetailID != nil || (bookFilterID == nil && data.books.count > 1)
        let balances: [UUID: Decimal] = !trash && showRunningBalances ? accountDetailID.map { data.runningBalances($0) } ?? [:] : [:]
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                VStack(alignment: .leading, spacing: 14) {
                    if trash {
                        bookSelector
                        Text(L("删除的账单不计入余额和统计，可随时恢复。", "Deleted entries are excluded from balances and totals, and can be restored.")).font(.callout).foregroundStyle(.secondary)
                    } else {
                        if let place = statsReturn, accountDetailID == nil {
                            Button { backToStats(place) } label: { Label(L("返回统计", "Back to Statistics"), systemImage: "chevron.left") }
                                .buttonStyle(.borderless).keyboardShortcut("[", modifiers: .command).help(L("回到刚才的统计（⌘[）", "Back to where you were in Statistics (⌘[)"))
                        }
                        if let account = selectedAccount { accountHeading(account) }
                        periodHeader
                    }
                    filterChips
                    if !trash {
                        if let account = selectedAccount { accountOverview(account, entries: entries) }
                        else { overview(entries) }
                    }
                }.padding(.horizontal, compact ? 4 : 24).padding(.top, 18).padding(.bottom, 6)
                if entries.isEmpty { emptyState.padding(.top, 40).frame(maxWidth: .infinity) }
                ForEach(keys, id: \.self) { day in
                    Section {
                        ForEach(days[day] ?? []) { entry in
                            FinanceEntryRow(entry: entry, data: data, showBook: showBook, hidden: hidden, accountID: trash ? nil : accountDetailID, balanceAfter: balances[entry.id],
                                            restore: trash ? { restore(entry) } : nil,
                                            open: { if !trash { editor = EntryRequest(entry: entry, expected: entry) } }) { actions(entry) }
                        }
                    } header: { dayHeader(day, days[day] ?? []) }
                }
            }.padding(.horizontal, compact ? 12 : 14).padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .task(id: "\(entriesCurrency)-\(data.entries.map(\.date).min()?.timeIntervalSince1970 ?? 0)") {
            await loadRates(since: data.entries.map(\.date).min() ?? Date(), currency: entriesCurrency)
        }
    }
    @ViewBuilder private func actions(_ entry: MoneyEntry) -> some View {
        if entry.deletedAt == nil {
            Button(L("编辑", "Edit")) { editor = EntryRequest(entry: entry, expected: entry) }
            if entry.kind == .expense || entry.kind == .income || entry.kind == .transfer { Button(L("再记一笔同样的", "Record another like this")) { duplicate(entry) } }
            if entry.kind == .expense {
                Button(data.remainingRefund(for: entry.id) > 0 ? L("记录退款", "Record refund") : L("已全额退款", "Fully refunded")) { newRefund(entry) }
                    .disabled(data.remainingRefund(for: entry.id) <= 0)
            }
            if let id = entry.taskID { Button(L("查看关联任务", "Open linked task")) { openTask(id) } }
            if let account = data.account(entry.accountID) { Button(L("查看 \(account.name) 的账单", "Show \(account.name) entries")) { showAccount(account.id) } }
            Divider()
            Button(L("删除", "Delete"), role: .destructive) { confirmDelete = entry }
        } else { Button(L("恢复账单", "Restore entry")) { restore(entry) } }
    }
    @ViewBuilder private var emptyState: some View {
        if selection == "trash" {
            ContentUnavailableView(L("没有删除的账单", "No deleted entries"), systemImage: "trash")
        } else if drilldown != nil || accountFilter != nil || categoryFilter != nil || kindFilter != nil || !search.isEmpty {
            ContentUnavailableView { Label(L("没有符合条件的账单", "No matching entries"), systemImage: "line.3.horizontal.decrease.circle") } actions: {
                Button(L("清除筛选", "Clear filters")) { drilldown = nil; accountFilter = nil; categoryFilter = nil; kindFilter = nil; search = "" }
            }
        } else {
            ContentUnavailableView { Label(L("这段时间还没有账单", "No entries yet"), systemImage: "tray") } description: {
                Text(compact ? L("点右上角 ＋ 记一笔，选分类、输金额就好。", "Tap +, pick a category and type the amount.") : L("点右上角 ＋ 或按 ⌘N 记一笔，选分类、输金额就好。", "Press + or ⌘N, pick a category and type the amount."))
            } actions: { Button(L("记一笔", "New entry"), action: newEntry).buttonStyle(.borderedProminent) }
        }
    }
    private func dayHeader(_ day: Date, _ items: [MoneyEntry]) -> some View {
        let spent = entryTotals(items, income: false)
        let earned = entryTotals(items, income: true)
        let flow = accountDetailID.map { data.accountFlow($0, in: items) }
        return (compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 5)) : AnyLayout(HStackLayout(spacing: 12))) {
            Text(Dates.label(day, pattern: "M月d日 EEEE") + (Dates.calendar.isDateInToday(day) ? L(" · 今天", " · Today") : ""))
            if !compact { Spacer() }
            HStack(spacing: 12) {
            if let flow, let account = selectedAccount {
                if flow.outgoing != 0 { Text(L("出 ", "Out ") + display(flow.outgoing, account.currency)) }
                if flow.incoming != 0 { Text(L("入 ", "In ") + display(flow.incoming, account.currency)) }
            } else {
                if spent.total != 0 || spent.missing > 0 { Text((spent.missing > 0 && spent.convertedCount > 0 ? L("支出小计 ", "Out subtotal ") : L("支 ", "Out ")) + totalDisplay(spent)) }
                if earned.total != 0 || earned.missing > 0 { Text((earned.missing > 0 && earned.convertedCount > 0 ? L("收入小计 ", "In subtotal ") : L("收 ", "In ")) + totalDisplay(earned)) }
            }
            }
        }
        .font(.caption.weight(.medium)).foregroundStyle(.secondary).monospacedDigit()
        .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 5)
        .frame(maxWidth: .infinity)
        .background(Color.appBackground)
    }
    private func accountHeading(_ account: MoneyAccount) -> some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 0) {
            HStack(spacing: 12) {
                Button { selection = "accounts" } label: {
                    Label(L("资产", "Assets"), systemImage: "chevron.left").fixedSize()
                        .frame(minHeight: compact ? 44 : nil)
                }.buttonStyle(.borderless)
                if !compact { Divider().frame(height: 18); accountIdentity(account) }
                Spacer(minLength: 8)
                Menu {
                    Button(L("全部账单", "All entries")) { accountDetailID = nil; accountFilter = nil; scope = ""; search = ""; categoryFilter = nil; kindFilter = nil; drilldown = nil }
                    Button(L("编辑账户", "Edit account")) { entity = EntityRequest(kind: .account, existingID: account.id) }
                    Button(L("核对余额", "Check balance")) { reconcile(account) }
                } label: {
                    if compact {
                        Image(systemName: "ellipsis.circle").font(.title3).frame(width: 44, height: 44)
                            .accessibilityLabel(L("账户设置", "Account settings"))
                    } else { Label(L("账户设置", "Account settings"), systemImage: "ellipsis.circle") }
                }.menuStyle(.borderlessButton).fixedSize()
            }
            if compact { accountIdentity(account) }
        }
    }
    private func accountIdentity(_ account: MoneyAccount) -> some View {
        HStack(alignment: .top, spacing: 10) {
            MoneyIcon(symbol: account.iconSymbol, emoji: account.emoji, tint: .accentColor, size: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(account.name).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text([account.currency, account.archived ? L("已归档", "Archived") : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func accountOverview(_ account: MoneyAccount, entries: [MoneyEntry]) -> some View {
        let flow = data.accountFlow(account.id, in: entries)
        let narrowed = !search.isEmpty || categoryFilter != nil || kindFilter != nil || drilldown != nil
        let span = billRange
        let opening: Decimal = span.map { data.balance(account.id, before: $0.start) } ?? account.opening
        let openingLabel = span == nil ? L("期初余额 ", "Opening balance ") : L("期初 ", "Start ")
        return VStack(alignment: .leading, spacing: 12) {
            (compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16)) : AnyLayout(HStackLayout(spacing: 24))) {
                metric(L("账户余额", "Account balance"), display(data.balance(account.id), account.currency), size: 30)
                    .help(L("全部账本、全部日期的账面余额，含期初余额；不随下面的日期或筛选变化。", "Book balance across all books and dates, including the opening balance. It does not change with filters."))
                if !compact { Spacer() }
                metricPair((narrowed ? L("筛选流入", "Filtered in") : L("资金流入", "Money in"), display(flow.incoming, account.currency)),
                           (narrowed ? L("筛选流出", "Filtered out") : L("资金流出", "Money out"), display(flow.outgoing, account.currency)))
            }
            (compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout())) {
                if !narrowed {
                    Text(openingLabel + display(opening, account.currency))
                    if let span = billRange { Text(L("期末 ", "End ") + display(data.balance(account.id, before: span.end), account.currency)) }
                }
                if !compact { Spacer() }
                Text(L("净变动 ", "Net change ") + display(flow.incoming - flow.outgoing, account.currency))
            }.font(.caption).foregroundStyle(.secondary)
            Text(L("全部账本 · 流入含转入、退款，流出含转出、手续费，余额调整按增减计入。", "All books · Includes transfers, refunds, fees and balance adjustments."))
                .font(.caption).foregroundStyle(.secondary)
        }.monospacedDigit().padding(18).background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.045)))
    }
    private func overview(_ entries: [MoneyEntry]) -> some View {
        let spent = entryTotals(entries, income: false)
        let earned = entryTotals(entries, income: true)
        let balance = MoneyStatisticsTotal(total: earned.total - spent.total, missing: earned.missing + spent.missing, estimateDates: earned.estimateDates.union(spent.estimateDates))
        let isMonth = selection == "stats" ? period == .month : dateRange == .month
        let hasFilters = accountFilter != nil || categoryFilter != nil || kindFilter != nil || drilldown != nil || !search.isEmpty
        let budget: Decimal? = isMonth && !hasFilters ? data.budget(for: bookFilterID, in: entries) : nil
        return VStack(alignment: .leading, spacing: 10) {
            (compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16)) : AnyLayout(HStackLayout(spacing: 32))) {
                metric(totalLabel(L("支出", "Spending"), spent), totalDisplay(spent), size: compact ? 24 : 30)
                if !compact { Spacer(minLength: 0) }
                metricPair((totalLabel(L("收入", "Income"), earned), totalDisplay(earned)),
                           (L("结余", "Balance"), balanceDisplay(spent: spent, earned: earned, currency: entriesCurrency)))
            }
            if let budget {
                budgetBar(spent: data.budgetSpending(entries, for: bookFilterID), budget: budget,
                          books: data.budgetBooks(for: bookFilterID, in: entries), entries: entries)
            }
            VStack(alignment: .leading, spacing: 6) {
                if let account = data.account(accountFilter) {
                    Label(L("筛选账户：", "Filtered account: ") + account.name + " · " + account.currency, systemImage: "creditcard")
                } else if let book = entryDefaults.book {
                    Button { entity = EntityRequest(kind: .book, existingID: book.id) } label: {
                        Label(L("默认账户：", "Default account: ") + (entryDefaults.account.map { $0.name + " · " + $0.currency } ?? L("未设置", "Not set")), systemImage: "creditcard")
                    }.buttonStyle(.borderless).help(L("修改此账本的默认账户；新账单和合计会跟随它的币种", "Change the book's default account; new entries and totals follow its currency"))
                }
                HStack(spacing: 8) {
                    Text(entriesCurrencyRaw.isEmpty
                         ? L("合计跟随默认账户 · ", "Totals follow default account · ") + entriesCurrency
                         : L("合计暂以 ", "Totals temporarily in ") + entriesCurrency)
                    if !entriesCurrencyRaw.isEmpty { Button(L("恢复跟随", "Follow default")) { entriesCurrencyRaw = "" }.buttonStyle(.borderless) }
                }.foregroundStyle(.secondary)
            }.font(.caption)
            if !balance.estimateDates.isEmpty {
                Text(L("部分换算使用缓存参考汇率：", "Some conversions use cached reference rates: ") + balance.estimateDates.sorted().joined(separator: ", "))
                    .font(.caption).foregroundStyle(.orange)
            }
            missingAmounts(balance.missing)
        }
        .padding(18).background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.045)))
    }
    private var sampleMessage: String {
        guard let c = data.sampleCleanup else { return "" }
        var parts = [L("将删除 \(c.entries) 笔示例账单、\(c.accounts) 个示例账户和 \(c.books) 个示例账本。", "Deletes \(c.entries) example entries, \(c.accounts) example accounts and \(c.books) example books.")]
        if c.ownEntries > 0 { parts.append(L("其中 \(c.ownEntries) 笔是你记在示例账户上的账单，账户删除后无法保留，也会一起删除。", "\(c.ownEntries) of them are your own entries on example accounts and go with those accounts.")) }
        if c.moved > 0 {
            var after = data; after.removeSamples()
            let home = after.books.first { !$0.archived }?.name ?? ""
            parts.append(L("你记在示例账本里的 \(c.moved) 笔会移到“\(home)”。", "\(c.moved) of your entries in example books move to “\(home)”."))
        }
        parts.append(L("清除前会先保存一份完整备份。", "A full backup is saved first."))
        return parts.joined(separator: "\n")
    }
    @ViewBuilder private func missingAmounts(_ count: Int) -> some View {
        if count > 0 {
            VStack(alignment: .leading, spacing: 6) {
                Label(L("\(count) 笔金额尚未折算，合计不完整。", "\(count) amounts are unconverted; totals are incomplete."), systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
                if !conversionScope.missingConversionEntries.isEmpty {
                    Button { conversionRequest = MoneyConversionRequest(ledger: conversionScope) } label: {
                        Label(L("补全折算…", "Complete conversions…"), systemImage: "arrow.triangle.2.circlepath")
                            .frame(minHeight: compact ? 44 : nil)
                    }.buttonStyle(.borderless).font(.callout)
                } else {
                    Text(L("所选显示币种缺少可用报价，可切换币种或稍后重试。账单已有的折算金额保持不变。", "Quotes for this display currency are unavailable. Choose another currency or retry later; recorded conversions stay unchanged."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
    private var conversionScope: FinanceData {
        var snapshot = data
        snapshot.entries = selection == "stats" ? statsEntries(range) : filtered
        return snapshot
    }
    private func prepareConversion(_ entries: [MoneyEntry]) {
        var snapshot = data; snapshot.entries = entries
        conversionRequest = MoneyConversionRequest(ledger: snapshot)
    }
    private func budgetBar(spent: MoneyStatisticsTotal, budget: Decimal, books: [MoneyBook], entries: [MoneyEntry]) -> some View {
        let ratio = budget > 0 ? min(1, max(0, double(spent.total / budget))) : 0
        let over = spent.total > budget
        return VStack(alignment: .leading, spacing: 7) {
            Button {
                if books.count == 1 { entity = EntityRequest(kind: .book, existingID: books[0].id) }
                else { selection = "manage" }
            } label: {
                Label(L("月预算 · ", "Monthly budget · ") + books.map(\.name).joined(separator: "、"), systemImage: "pencil")
                    .font(.caption.weight(.medium)).multilineTextAlignment(.leading)
                    .frame(minHeight: compact ? 44 : nil, alignment: .leading)
            }.buttonStyle(.borderless).help(L("修改这些账本的预算", "Edit these books’ budgets"))
            if spent.complete { MoneyBar(value: ratio, tint: over ? .red : ratio > 0.8 ? .orange : .accentColor) }
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(L("预算 ", "Budget ") + display(budget) + " · " + data.baseCurrency).fixedSize()
                    Spacer(minLength: 12)
                    budgetRemaining(spent, budget: budget).fixedSize()
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("预算 ", "Budget ") + display(budget) + " · " + data.baseCurrency)
                    budgetRemaining(spent, budget: budget)
                }
            }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if spent.missing > 0 {
                Text(L("预算范围内 \(spent.missing) 笔金额待折算，补全后显示进度和剩余额度。", "\(spent.missing) amounts in these books need conversion before budget progress and remaining amounts are shown."))
                    .font(.caption).foregroundStyle(.orange)
                Button(L("补全预算折算…", "Complete budget conversions…")) {
                    let ids = Set(books.map(\.id))
                    prepareConversion(entries.filter { $0.deletedAt == nil && $0.bookID.map(ids.contains) == true
                        && $0.originalStatistics(income: false, feeCurrency: nil) != nil })
                }.buttonStyle(.borderless).font(.callout).frame(minHeight: compact ? 44 : nil)
            }
            if bookFilterID == nil {
                Text(L("预算仅包含以上账本；上方收支包含全部账本。", "The budget covers the books above; totals include all books."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func budgetRemaining(_ spent: MoneyStatisticsTotal, budget: Decimal) -> some View {
        Text(!spent.complete ? L("剩余额度待折算", "Remaining amount pending conversion") : spent.total > budget
             ? L("超出 ", "Over by ") + display(spent.total - budget) : L("剩余 ", "Left ") + display(budget - spent.total))
            .foregroundStyle(!spent.complete ? Color.orange : spent.total > budget ? .red : .secondary)
    }

    // MARK: Statistics

    /// The currency statistics are shown in; defaults to the ledger's base currency.
    private var statsCurrency: String { Money.currencies.contains(statsCurrencyRaw) ? statsCurrencyRaw : data.baseCurrency }
    private func statsEntries(_ span: DateInterval) -> [MoneyEntry] {
        data.entries.filter { $0.deletedAt == nil && $0.date >= span.start && $0.date < span.end && (bookFilterID == nil || $0.bookID == bookFilterID) }
    }
    private func statsValue(_ entry: MoneyEntry, income: Bool, days: [String]?) -> Decimal? {
        data.statisticsAmount(entry, income: income, in: statsCurrency, history: rateHistory, days: days)
    }
    private func statsSum(_ entries: [MoneyEntry], income: Bool, days: [String]?) -> MoneyStatisticsTotal {
        data.statisticsTotal(entries, income: income, in: statsCurrency, history: rateHistory, days: days)
    }
    private var statisticsPage: some View {
        let span = range, days = rateHistory?.sortedDays
        let entries = statsEntries(span)
        let spent = statsSum(entries, income: false, days: days), earned = statsSum(entries, income: true, days: days)
        let previousAnchor = Dates.calendar.date(byAdding: period.component, value: -1, to: anchor) ?? anchor
        let before = statsSum(statsEntries(Dates.calendar.dateInterval(of: period.component, for: previousAnchor)!), income: false, days: days)
        let value: (MoneyEntry) -> Decimal? = { statsValue($0, income: statsIncome, days: days) }
        let rows = categoryRows(entries)
        let earliest = data.entries.filter { $0.deletedAt == nil }.map(\.date).min() ?? Date()
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                periodHeader
                VStack(alignment: .leading, spacing: 12) {
                    (compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16)) : AnyLayout(HStackLayout(spacing: 32))) {
                        VStack(alignment: .leading, spacing: 6) {
                            metric(totalLabel(L("支出", "Spending"), spent), totalDisplay(spent, currency: statsCurrency), size: compact ? 24 : 30)
                            change(now: spent, before: before)
                        }
                        if !compact { Spacer(minLength: 0) }
                        metricPair((totalLabel(L("收入", "Income"), earned), totalDisplay(earned, currency: statsCurrency)),
                                   (L("结余", "Balance"), balanceDisplay(spent: spent, earned: earned, currency: statsCurrency)))
                    }
                    originalSplit(entries)
                    rateNote(entries, estimates: spent.estimateDates.union(earned.estimateDates))
                }.padding(18).background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.045)))
                missingAmounts(spent.missing + earned.missing)
                (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))) {
                    Picker(L("方向", "Direction"), selection: $statsIncome) {
                        Text(L("支出", "Spending")).tag(false)
                        Text(L("收入", "Income")).tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: compact ? .infinity : 150)
                    Picker(L("视图", "View"), selection: $statsCalendar) {
                        Text(L("趋势", "Trend")).tag(false)
                        Text(L("日历", "Calendar")).tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: compact ? .infinity : 130)
                    if !compact { Spacer() }
                }
                let selectedTotal = statsIncome ? earned : spent
                if selectedTotal.missing > 0 {
                    Text(L("图表和分类仅显示已折算部分，空白不代表零收支。", "Charts and categories show converted amounts only; gaps do not mean zero activity."))
                        .font(.caption).foregroundStyle(.orange)
                }
                if rows.isEmpty {
                    Text(selectedTotal.missing > 0 ? L("本期账单尚待折算，补全后显示图表。", "Complete the pending conversions to see this period’s charts.") : statsIncome ? L("这段时间没有可统计的收入。", "No income in this period.") : L("这段时间没有可统计的支出或退款。", "No spending or refunds in this period."))
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    let points = buckets(entries, span: span, value: value)
                    MoneyChartHover { hovered in
                        if statsCalendar { calendarGrid(points, hovered: hovered) } else { trend(points, hovered: hovered) }
                    }.id(span.start)
                    ranking(rows)
                }
                if !statsIncome {
                    Text(L("支出包含手续费，并扣除退款；负数表示本期退款多于消费。", "Spending includes fees minus refunds. Negative amounts mean refunds exceeded spending in this period."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(compact ? 16 : 24)
        }
        .task(id: "\(statsCurrency)-\(data.baseCurrency)-\(Int(earliest.timeIntervalSince1970 / 86400))") { await loadRates(since: earliest) }
    }
    private func loadRates(since: Date, currency: String? = nil) async {
        guard (currency ?? statsCurrency) != data.baseCurrency else { return }
        if rateHistory == nil { rateHistory = await RateHistoryStore.cached }
        loadingRates = true
        if let history = try? await RateHistoryStore.load(since: since) { rateHistory = history }
        loadingRates = false
    }
    private var entriesCurrencyMenu: some View {
        Menu {
            Button(L("跟随常用账户：", "Follow default account: ") + defaultEntriesCurrency) { entriesCurrencyRaw = "" }
            Divider()
            CurrencyChoices { entriesCurrencyRaw = $0 }
        } label: { Label(entriesCurrency + (entriesCurrencyRaw.isEmpty ? L(" · 自动", " · Auto") : ""), systemImage: "banknote") }
            .fixedSize().help(L("默认跟随账户币种；临时切换只改变合计显示，不改变原始金额", "Follows the default account; a temporary override changes totals, never original amounts"))
    }
    private var statsCurrencyMenu: some View {
        Menu {
            Button(L("本位币：", "Base currency: ") + Money.name(data.baseCurrency)) { statsCurrencyRaw = "" }
            Divider()
            CurrencyChoices { statsCurrencyRaw = $0 == data.baseCurrency ? "" : $0 }
        } label: { Label(Money.name(statsCurrency), systemImage: "banknote") }
            .fixedSize().help(L("统计币种：所有合计换算成这种货币显示", "Show every total in this currency"))
    }
    /// “¥1,860 + A$1,250”: what was actually spent in each currency, before any conversion.
    @ViewBuilder private func originalSplit(_ entries: [MoneyEntry]) -> some View {
        let sums = entries.reduce(into: [String: Decimal]()) { result, e in
            if let o = e.originalStatistics(income: statsIncome, feeCurrency: data.account(e.accountID)?.currency) { result[o.currency, default: 0] += o.amount }
        }.filter { $0.value != 0 }.sorted { $0.key == statsCurrency ? true : $1.key == statsCurrency ? false : $0.key < $1.key }
        if sums.count > 1 || sums.first.map({ $0.key != statsCurrency }) == true {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text(statsIncome ? L("各币种实际收入", "Received in each currency") : L("各币种实际支出", "Spent in each currency"))
                    .font(.caption).foregroundStyle(.secondary)
                (compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))) {
                    ForEach(sums, id: \.key) { item in
                        HStack(spacing: 6) {
                            Text(display(item.value, item.key)).font(.body.weight(.semibold)).monospacedDigit()
                            Text(Money.name(item.key)).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
                    }
                }
            }
        }
    }
    @ViewBuilder private func rateNote(_ entries: [MoneyEntry], estimates: Set<String>) -> some View {
        let foreign = entries.contains { $0.currency != statsCurrency || ($0.fee > 0 && data.account($0.accountID)?.currency != statsCurrency) }
        if !estimates.isEmpty {
            let dates = estimates.sorted()
            let range = dates.count == 1 ? dates[0] : dates.first! + " – " + dates.last!
            Text(L("部分金额为估算，参考汇率日期：\(range)。", "Some amounts are estimates. Reference rate date: \(range)."))
                .font(.caption).foregroundStyle(.orange)
        } else if statsCurrency != data.baseCurrency && foreign {
            Text(loadingRates && rateHistory == nil ? L("正在下载每日参考汇率…", "Downloading daily reference rates…")
                 : L("可折算的金额按账单日期的参考汇率计算，原始金额不变。", "Convertible amounts use reference rates for each entry's date; original amounts don't change."))
                .font(.caption).foregroundStyle(.secondary)
        } else if foreign {
            Text(L("外币按记账时的折算金额计入。可在右上角切换统计币种。", "Foreign amounts count at the value recorded with each entry. Switch the currency at the top right."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    /// "比上月 ↑12%": spending up reads as a warning, down as good news.
    @ViewBuilder private func change(now: MoneyStatisticsTotal, before: MoneyStatisticsTotal) -> some View {
        if let value = now.change(from: before), !hidden {
            let ratio = double(value)
            let name: String = { switch period { case .week: L("比上周", "vs last week"); case .month: L("比上月", "vs last month"); case .year: L("比去年", "vs last year") } }()
            let text = abs(ratio) < 0.005 ? L("持平", "flat") : (ratio > 0 ? "↑" : "↓") + "\(Int((abs(ratio) * 100).rounded()))%"
            Text(name + " " + text).font(.caption).foregroundStyle(abs(ratio) < 0.005 ? Color.secondary : ratio > 0 ? Color.orange : Color.green)
                .help(L("上一段支出 ", "Previous period ") + display(before.total, statsCurrency))
        } else if !hidden && (!now.complete || !before.complete) {
            Text(L("数据未完整折算，暂不比较涨跌", "Comparison unavailable: some amounts are missing or estimated"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var statsUnit: Calendar.Component { period == .year ? .month : .day }
    private func buckets(_ entries: [MoneyEntry], span: DateInterval, value: (MoneyEntry) -> Decimal?) -> [TrendPoint] {
        let unit = statsUnit
        var result: [Date: (amount: Decimal, count: Int, missing: Int)] = [:]
        var cursor = span.start
        while cursor < span.end { result[cursor] = (0, 0, 0); cursor = Dates.calendar.date(byAdding: unit, value: 1, to: cursor) ?? span.end }
        for e in entries {
            guard e.originalStatistics(income: statsIncome, feeCurrency: data.account(e.accountID)?.currency) != nil else { continue }
            let key = Dates.calendar.dateInterval(of: unit, for: e.date)?.start ?? e.date
            var bucket = result[key] ?? (0, 0, 0)
            if let amount = value(e) { bucket.amount += amount; bucket.count += 1 }
            else { bucket.missing += 1 }
            result[key] = bucket
        }
        return result.map { TrendPoint(date: $0.key, amount: $0.value.amount, count: $0.value.count, missing: $0.value.missing) }.sorted { $0.date < $1.date }
    }
    /// Bars per day (per month for a year). Hovering shows the exact amount; clicking opens that day's or month's entries.
    private func trend(_ points: [TrendPoint], hovered: Binding<Date?>) -> some View {
        let unit = statsUnit
        let elapsed = points.filter { $0.date <= Date() }
        let average = elapsed.isEmpty ? 0 : elapsed.map(\.amount).reduce(0, +) / Decimal(elapsed.count)
        let selected = hovered.wrappedValue.flatMap { date in points.first { $0.date == date } }
        return Chart {
            ForEach(points) { point in
                BarMark(x: .value(L("日期", "Date"), point.date, unit: unit), y: .value(L("金额", "Amount"), point.value))
                    .foregroundStyle(point.value < 0 || statsIncome ? Color.green.gradient : Color.accentColor.gradient)
                    .opacity(selected == nil || selected?.date == point.date ? 1 : 0.35)
                    .cornerRadius(2)
                    .accessibilityLabel(Dates.label(point.date, pattern: unit == .month ? "yyyy年M月" : "M月d日"))
                    .accessibilityValue(pointDisplay(point))
            }
            if average > 0 && !hidden && !points.contains(where: { $0.missing > 0 }) {
                RuleMark(y: .value(L("平均", "Average"), double(average)))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(Color.secondary.opacity(0.7))
                    .annotation(position: .top, alignment: .trailing) {
                        Text((unit == .month ? L("月均 ", "Monthly avg ") : L("日均 ", "Daily avg ")) + display(Money.round(average, currency: statsCurrency), statsCurrency))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
            }
        }
        .chartYAxis(hidden ? .hidden : .automatic)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                let plot = proxy.plotFrame.map { geometry[$0] } ?? .zero
                ZStack(alignment: .topLeading) {
                    // One invisible column per day (per month in a year), laid out side by side under the bars:
                    // hover areas follow layout, so they must be placed by layout rather than moved by an offset.
                    let columns = trendColumns(points, unit: unit, proxy: proxy)
                    HStack(spacing: 0) {
                        Color.clear.frame(width: columns.lead)
                        ForEach(points) { point in
                            Rectangle().fill(Color.primary.opacity(hovered.wrappedValue == point.date ? 0.06 : 0)).contentShape(Rectangle())
                                .frame(width: columns.widths[point.date] ?? 0)
                                .onHover { inside in
                                    if inside { hovered.wrappedValue = point.date } else if hovered.wrappedValue == point.date { hovered.wrappedValue = nil }
                                }
                                .onTapGesture { openBucket(point.date, unit: unit) }
                        }
                    }
                    .frame(height: max(1, plot.height))
                    .padding(.leading, plot.minX).padding(.top, plot.minY)
                    if let selected, let end = Dates.calendar.date(byAdding: unit, value: 1, to: selected.date),
                       let x = proxy.position(forX: selected.date.addingTimeInterval(end.timeIntervalSince(selected.date) / 2)) {
                        trendTip(selected, unit: unit)
                            .position(x: min(max(plot.minX + x, plot.minX + 70), plot.maxX - 70), y: plot.minY + 24)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .frame(height: 200)
        .onChange(of: period) { _, _ in hovered.wrappedValue = nil }
    }
    private func trendColumns(_ points: [TrendPoint], unit: Calendar.Component, proxy: ChartProxy) -> (lead: CGFloat, widths: [Date: CGFloat]) {
        var widths: [Date: CGFloat] = [:], lead: CGFloat = 0
        for (i, point) in points.enumerated() {
            guard let x0 = proxy.position(forX: point.date), let next = Dates.calendar.date(byAdding: unit, value: 1, to: point.date),
                  let x1 = proxy.position(forX: next) else { continue }
            if i == 0 { lead = max(0, x0) }
            widths[point.date] = max(0, x1 - x0)
        }
        return (lead, widths)
    }
    private func trendTip(_ point: TrendPoint, unit: Calendar.Component) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Dates.label(point.date, pattern: unit == .month ? "yyyy年M月" : "M月d日 EEEE")).font(.caption).foregroundStyle(.secondary)
            Text(pointDisplay(point)).font(.headline).monospacedDigit()
            if point.missing > 0 { Text(L("\(point.missing) 笔待折算", "\(point.missing) unconverted")).font(.caption2).foregroundStyle(.orange) }
            Text(point.count + point.missing == 0 ? L("没有账单", "No entries") : L("\(point.count + point.missing) 笔 · 点击查看", "\(point.count + point.missing) entries · click to open")).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
        .fixedSize()
    }
    private func pointDisplay(_ point: TrendPoint) -> String {
        if hidden { return "••••" }
        if point.missing > 0 && point.count == 0 { return L("待折算", "Unconverted") }
        return display(point.amount, statsCurrency) + (point.missing > 0 ? L(" · 小计", " · subtotal") : "")
    }
    /// Days of the month as a calendar (months of the year as a grid), shaded by amount.
    private func calendarGrid(_ points: [TrendPoint], hovered: Binding<Date?>) -> some View {
        let unit = statsUnit
        let top = points.map { abs($0.value) }.max() ?? 0
        let lead = unit == .day ? (Dates.calendar.component(.weekday, from: points.first?.date ?? Date()) + 5) % 7 : 0
        let selected = hovered.wrappedValue.flatMap { date in points.first { $0.date == date } }
        let tint = statsIncome ? Color.green : Color.accentColor
        return VStack(alignment: .leading, spacing: 8) {
            Group {
                if let selected {
                    Text(Dates.label(selected.date, pattern: unit == .month ? "yyyy年M月" : "M月d日 EEEE") + " · " + pointDisplay(selected)
                         + " · " + (selected.count + selected.missing == 0 ? L("没有账单", "No entries") : L("\(selected.count + selected.missing) 笔，点击查看", "\(selected.count + selected.missing) entries, click to open")))
                } else {
                    Text(compact ? L("颜色越深金额越大，点按日期查看账单。", "Darker means more. Tap a date to view entries.") : L("颜色越深金额越大，鼠标放上去看具体数字。", "Darker means more. Hover to see the amount."))
                }
            }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: compact ? 4 : 6), count: unit == .day ? 7 : 4), spacing: compact ? 4 : 6) {
                if unit == .day {
                    ForEach([L("一", "Mon"), L("二", "Tue"), L("三", "Wed"), L("四", "Thu"), L("五", "Fri"), L("六", "Sat"), L("日", "Sun")], id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
                    ForEach(0..<lead, id: \.self) { _ in Color.clear.frame(height: 40) }
                }
                ForEach(points) { point in
                    let strength = top > 0 ? min(1, abs(point.value) / top) : 0
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Dates.label(point.date, pattern: unit == .month ? "M月" : "d日")).font(.caption)
                        if point.missing > 0 {
                            Image(systemName: "exclamationmark.circle").font(.caption2).foregroundStyle(.orange)
                        } else if point.count > 0 && !hidden {
                            Text(display(point.amount, statsCurrency)).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                        }
                    }
                    .padding(5).frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 7).fill(tint.opacity(point.count > 0 ? 0.12 + 0.6 * strength : 0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(hovered.wrappedValue == point.date ? 0.4 : 0), lineWidth: 1.5))
                    .opacity(point.date > Date() ? 0.4 : 1)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { hovered.wrappedValue = point.date } else if hovered.wrappedValue == point.date { hovered.wrappedValue = nil }
                    }
                    .onTapGesture { openBucket(point.date, unit: unit) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Dates.label(point.date, pattern: unit == .month ? "yyyy年M月" : "M月d日"))
                    .accessibilityValue(pointDisplay(point))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { openBucket(point.date, unit: unit) }
                }
            }
        }
    }
    private func rememberStats() {
        statsReturn = StatsPlace(anchor: anchor, period: period, income: statsIncome, expanded: rankingExpansion.key, billRange: dateRange)
    }
    private func backToStats(_ place: StatsPlace) {
        drilldown = nil; dateRange = place.billRange
        anchor = place.anchor; period = place.period; statsIncome = place.income; rankingExpansion.key = place.expanded
        selection = "stats"
    }
    private func openBucket(_ date: Date, unit: Calendar.Component) {
        rememberStats()
        drilldown = nil; categoryFilter = nil; kindFilter = nil; accountFilter = nil; accountDetailID = nil; search = ""
        anchor = date; dateRange = unit == .month ? .month : .day
        selection = "all"
    }
    private func breakdownLabel(_ key: MoneyCategoryKey) -> String {
        switch key {
        case .fees: return L("转账手续费", "Transfer fees")
        case .category(let id): return data.categoryPath(id)
        }
    }
    private func categoryRows(_ entries: [MoneyEntry]) -> [MoneyCategoryTotal] {
        let grouped = Dictionary(grouping: entries.filter { $0.originalStatistics(income: statsIncome, feeCurrency: nil) != nil }) {
            $0.kind == .transfer ? MoneyCategoryKey.fees : .category(data.rootCategoryID($0.categoryID))
        }
        let days = rateHistory?.sortedDays
        return grouped.map { key, entries in
            let total = statsSum(entries, income: statsIncome, days: days)
            return MoneyCategoryTotal(id: key, total: total.total, count: total.convertedCount, missing: total.missing, estimateDates: total.estimateDates)
        }.sorted { abs($0.total) > abs($1.total) }
    }
    private func ranking(_ rows: [MoneyCategoryTotal]) -> some View {
        let top = rows.map { abs($0.total) }.max() ?? 1
        let sum = rows.map(\.total).filter { $0 > 0 }.reduce(0, +)
        let complete = rows.allSatisfy { $0.summary.complete }
        return MoneyRanking(rows: rows, expansion: rankingExpansion) { row in
            let category: MoneyCategory? = { if case .category(let id) = row.id { return data.category(id) }; return nil }()
            let tint = data.tint(category)
            HStack(spacing: 12) {
                MoneyIcon(symbol: category?.symbol ?? (row.id == .fees ? "arrow.left.arrow.right" : "tag"), emoji: category?.emoji, tint: tint, size: 32)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(breakdownLabel(row.id))
                        if complete && sum > 0 && row.total > 0 && !hidden { Text("\(Int((double(row.total / sum) * 100).rounded()))%").font(.caption).foregroundStyle(.secondary) }
                        Text(L("\(row.count + row.missing) 笔", "\(row.count + row.missing)")).font(.caption).foregroundStyle(.tertiary)
                        Spacer()
                        Text(totalDisplay(row.summary, currency: statsCurrency, subtotal: true)).monospacedDigit().foregroundStyle(row.missing > 0 ? Color.orange : row.total < 0 ? .green : .primary)
                    }
                    if row.missing > 0 {
                        Text(L("\(row.missing) 笔待折算", "\(row.missing) unconverted")).font(.caption).foregroundStyle(.orange)
                    } else {
                        MoneyBar(value: top > 0 ? double(abs(row.total) / top) : 0, tint: row.total < 0 ? .green : tint)
                    }
                }
            }
        } detail: { row in
            let category: MoneyCategory? = { if case .category(let id) = row.id { return data.category(id) }; return nil }()
            subcategoryRanking(row.id)
            categoryHistory(row.id, tint: data.tint(category))
        }
    }
    @ViewBuilder private func subcategoryRanking(_ key: MoneyCategoryKey) -> some View {
        if case .category(let id) = key, let id {
            let children = data.categories.filter { $0.parentID == id }
            if !children.isEmpty {
                let periodEntries = statsEntries(range)
                let days = rateHistory?.sortedDays
                VStack(spacing: 0) {
                    ForEach([data.category(id)].compactMap { $0 } + children) { category in
                        let entries = periodEntries.filter { MoneyCategoryKey.category(category.id).includes($0, income: statsIncome) }
                        let total = statsSum(entries, income: statsIncome, days: days)
                        if !entries.isEmpty {
                            Button { drill(.category(category.id), includeSubcategories: category.id != id) } label: {
                                HStack {
                                    Text(category.id == id ? L("未细分", "No subcategory") : category.label)
                                    Spacer()
                                    Text(totalDisplay(total, currency: statsCurrency, subtotal: true)).monospacedDigit()
                                        .foregroundStyle(total.missing > 0 ? Color.orange : .primary)
                                }.font(.callout).padding(.vertical, 12).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }.padding(.leading, compact ? 16 : 54).padding(.trailing, 12)
            }
        }
    }
    /// Missing conversions remain gaps; an average is only meaningful when every month is complete.
    private func categoryHistory(_ key: MoneyCategoryKey, tint: Color) -> some View {
        let months = data.categoryMonthlyTotals(key, income: statsIncome, endingAt: anchor, bookID: bookFilterID, in: statsCurrency, history: rateHistory)
        let summaries = months.map(\.summary)
        let top = summaries.map { abs($0.total) }.max() ?? 0
        let average = MoneyStatisticsTotal.average(summaries)
        let missing = summaries.reduce(0) { $0 + $1.missing }
        let estimates = summaries.reduce(into: Set<String>()) { $0.formUnion($1.estimateDates) }
        return VStack(alignment: .leading, spacing: 10) {
            (compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout())) {
                Text(breakdownLabel(key) + L(" · 近 6 个月", " · last 6 months"))
                    .font(.caption).foregroundStyle(.secondary)
                if !compact { Spacer() }
                Button(L("查看本期账单", "Show this period’s entries")) { drill(key) }
                    .controlSize(.small).frame(minHeight: compact ? 44 : nil)
            }
            Text(L("月均：", "Monthly average: ") + (average.map { display(Money.round($0, currency: statsCurrency), statsCurrency) }
                ?? (missing > 0 ? L("待补全折算", "Pending conversions") : L("待历史汇率确认", "Pending historical rates"))))
                .font(.caption).foregroundStyle(average == nil ? Color.orange : .secondary)
            if dynamicTypeSize.isAccessibilitySize {
                ForEach(months, id: \.start) { month in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Dates.label(month.start, pattern: "yyyy年M月")).font(.caption)
                        Text(totalDisplay(month.summary, currency: statsCurrency, subtotal: true)).monospacedDigit()
                        if month.summary.missing > 0 { Text(L("\(month.summary.missing) 笔待折算", "\(month.summary.missing) unconverted")).font(.caption).foregroundStyle(.orange) }
                    }
                }
            } else {
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(months, id: \.start) { month in
                        MoneyHover { hovering in
                            VStack(spacing: 4) {
                                Text(hovering || month.start == months.last?.start ? totalDisplay(month.summary, currency: statsCurrency, subtotal: true) : " ")
                                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                                if month.summary.missing > 0 {
                                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).frame(height: 64)
                                } else {
                                    RoundedRectangle(cornerRadius: 3).fill(tint.opacity(month.start == months.last?.start ? 1 : hovering ? 0.8 : 0.5))
                                        .frame(height: max(2, top > 0 ? 64 * CGFloat(double(abs(month.summary.total) / top)) : 2))
                                }
                                Text(Dates.label(month.start, pattern: "M月")).font(.caption2).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity).contentShape(Rectangle())
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(Dates.label(month.start, pattern: "yyyy年M月") + " · " + totalDisplay(month.summary, currency: statsCurrency, subtotal: true))
                        }
                    }
                }.frame(minHeight: 100, alignment: .bottom)
            }
            if missing > 0 {
                Text(L("近 6 个月有 \(missing) 笔金额待折算，暂不计算月均；标记月份并非零支出。", "\(missing) amounts in these six months need conversion. The average is withheld; marked months do not mean zero activity."))
                    .font(.caption).foregroundStyle(.orange)
                Button(L("补全这 6 个月的折算…", "Complete these six months’ conversions…")) {
                    guard let first = months.first?.start, let end = Dates.calendar.dateInterval(of: .month, for: anchor)?.end else { return }
                    prepareConversion(data.entries.filter {
                        $0.deletedAt == nil && $0.date >= first && $0.date < end && (bookFilterID == nil || $0.bookID == bookFilterID)
                            && key.includes($0, income: statsIncome, data: data)
                    })
                }.buttonStyle(.borderless).font(.callout).frame(minHeight: compact ? 44 : nil)
            }
            if !estimates.isEmpty {
                Text(L("部分月份使用缓存参考汇率，月均暂不显示。参考日期：", "Some months use cached reference rates, so the average is withheld. Rate dates: ") + estimates.sorted().joined(separator: ", "))
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        .padding(.leading, compact ? 12 : 54).padding(.trailing, 10).padding(.bottom, 8)
    }
    private func drill(_ key: MoneyCategoryKey, includeSubcategories: Bool = true) {
        rememberStats()
        drilldown = MoneyDrilldown(range: range, key: key, income: statsIncome, includeSubcategories: includeSubcategories)
        categoryFilter = nil; kindFilter = nil; accountFilter = nil; accountDetailID = nil; search = ""; dateRange = .month
        selection = "all"
    }

    // MARK: Assets

    private struct AccountGroup: Identifiable { var type: MoneyAccountType; var accounts: [MoneyAccount]; var id: String { type.rawValue } }
    private struct TrendPoint: Identifiable { var date: Date; var amount: Decimal; var count: Int; var missing: Int; var value: Double { double(amount) }; var id: Date { date } }
    private var assetCurrencies: [String] { Set(data.accounts.map(\.currency)).filter { $0 != "CNY" }.sorted() }
    private var selectedForeignCurrency: String? { assetCurrencies.contains(foreignCurrency) ? foreignCurrency : assetCurrencies.first }
    private var assetsPage: some View {
        let balances = data.accountBalances()
        let summary = data.assetSummary(in: "CNY", accountBalances: balances)
        let groups = MoneyAccountType.allCases.map { type in AccountGroup(type: type, accounts: data.accounts.filter { $0.resolvedType == type && !$0.archived }) }.filter { !$0.accounts.isEmpty }
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(L("账户总览", "Accounts overview")).font(.headline)
                    Spacer()
                    Button { entity = EntityRequest(kind: .account) } label: { Label(L("新增账户", "New account"), systemImage: "plus") }
                        .frame(minHeight: compact ? 44 : 24)
                }
                VStack(alignment: .leading, spacing: 16) {
                    Text(L("净资产 · 折合人民币", "Net worth · CNY equivalent")).font(.subheadline).foregroundStyle(.secondary)
                    Text(hidden ? "••••" : summary.total.map { display($0, "CNY") } ?? L("待补充汇率", "Rates needed"))
                        .font(.system(size: compact ? 30 : 36, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                    if summary.total == nil {
                        Label(L("缺少 \(summary.missingCurrencies.joined(separator: "、")) 汇率，总额尚不完整。", "Missing \(summary.missingCurrencies.joined(separator: ", ")) rates. The total is incomplete."), systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Divider()
                    (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16)) : AnyLayout(HStackLayout(alignment: .top, spacing: 16))) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("人民币账户 · CNY", "CNY accounts")).font(.caption).foregroundStyle(.secondary)
                                .frame(minHeight: compact && assetCurrencies.count > 1 ? 44 : nil, alignment: .leading)
                            Text(display(summary.balances["CNY", default: 0], "CNY"))
                                .font(.system(size: compact ? 19 : 22, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 6) {
                            if let currency = selectedForeignCurrency {
                                if assetCurrencies.count > 1 {
                                    Menu {
                                        ForEach(assetCurrencies, id: \.self) { code in Button(Money.name(code) + " · " + code) { foreignCurrency = code } }
                                    } label: { Label(L("外币账户 · ", "Foreign accounts · ") + currency, systemImage: "chevron.down").frame(minHeight: compact ? 44 : nil) }
                                        .font(.caption).menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
                                } else {
                                    Text(L("外币账户 · ", "Foreign accounts · ") + currency).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(display(summary.balances[currency, default: 0], currency))
                                    .font(.system(size: compact ? 19 : 22, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                            } else {
                                Text(L("外币账户", "Foreign accounts")).font(.caption).foregroundStyle(.secondary)
                                Text(L("暂无", "None")).font(.title3.weight(.semibold))
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let currency = selectedForeignCurrency {
                        HStack(spacing: 8) {
                            if let rate = data.storedRate(from: currency, to: "CNY") {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("1 " + currency + " = " + assetRateText(rate.rate) + " CNY")
                                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                                    Text((rate.isManual ? L("手动汇率 · ", "Manual rate · ") : L("参考价日期 · ", "Reference date · ")) + rate.date)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if !rate.isManual { Text("ECB").foregroundStyle(.tertiary) }
                                }
                            } else {
                                Text(currency + L(" 尚未填写汇率", " needs an exchange rate"))
                            }
                            Spacer(minLength: 0)
                            Button(L("修改汇率", "Edit rate")) { showAssetRates = true }
                                .frame(minHeight: compact ? 44 : nil)
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Text(L("含期初余额、负债和归档账户；外币折算仅用于当前估值。", "Includes opening balances, debts and archived accounts. Conversion estimates current value only."))
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(18).background(RoundedRectangle(cornerRadius: 14).fill(Color.accentColor.opacity(0.08)))
                if !assetCurrencies.isEmpty { rateLine(summary) }
                if data.accounts.isEmpty {
                    ContentUnavailableView {
                        Label(L("添加你的第一个账户", "Add your first account"), systemImage: "wallet.pass")
                    } description: {
                        Text(L("银行卡、支付宝、现金都可以是账户。所有账本共用同一套账户，在哪个账本花钱，都从同一个余额里扣。", "Cards, wallets and cash are accounts. Every book shares them, so spending in any book comes out of the same balance."))
                    } actions: { Button(L("新增账户", "New account")) { entity = EntityRequest(kind: .account) }.buttonStyle(.borderedProminent) }
                }
                ForEach(groups) { group in
                    let accounts = group.accounts
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(group.type.label).font(.subheadline.weight(.semibold))
                            Text("\(accounts.count)").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if let subtotal = data.assetSummary(in: "CNY", accountBalances: balances, accounts: accounts).total { Text(display(subtotal, "CNY")).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                        }.padding(.horizontal, 4)
                        VStack(spacing: 0) {
                            ForEach(accounts) { account in
                                accountRow(account, balance: balances[account.id, default: 0])
                                if account.id != accounts.last?.id { Divider().padding(.leading, 58) }
                            }
                        }.background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
                    }
                }
                if data.accounts.contains(where: \.archived) {
                    DisclosureGroup(L("已归档账户", "Archived accounts"), isExpanded: $showArchivedAccounts) {
                        VStack(spacing: 0) { ForEach(data.accounts.filter(\.archived)) { accountRow($0, balance: balances[$0.id, default: 0]) } }
                        Text(L("归档只隐藏入口，余额仍计入总资产。", "Archiving hides these accounts; their balances remain in net worth."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(compact ? 16 : 24)
        }
        .task(id: assetCurrencies.joined(separator: "-") + "-\(automaticRates)") { await refreshStaleAssetRates() }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            if scenePhase == .active { Task { await refreshStaleAssetRates() } }
        }
        #if os(iOS)
        .refreshable { await updateAssetRates() }
        #endif
    }
    private func refreshStaleAssetRates() async {
        guard automaticRates, !assetCurrencies.isEmpty else { return }
        let key = assetCurrencies.joined(separator: "-")
        let now = Date()
        if let automaticRateRetryAfter, now < automaticRateRetryAfter { return }
        if automaticRateRetryAfter == nil, lastAutomaticRateKey == key, let lastAutomaticRateAttempt,
           now.timeIntervalSince(lastAutomaticRateAttempt) < 6 * 3600,
           Dates.calendar.isDate(lastAutomaticRateAttempt, inSameDayAs: now) { return }
        let stale = assetCurrencies.contains { currency in
            guard let rate = data.storedRate(from: currency, to: "CNY") else { return true }
            return !rate.isManual && (now.timeIntervalSince(rate.fetchedAt) > 6 * 3600 || !Dates.calendar.isDate(rate.fetchedAt, inSameDayAs: now))
        }
        if stale {
            lastAutomaticRateKey = key; lastAutomaticRateAttempt = now
            await updateAssetRates()
        }
    }
    private func rateLine(_ summary: MoneyAssetSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !summary.rateDates.isEmpty {
                Text(L("欧洲央行参考汇率日期：", "ECB reference rate dates: ") + summary.rateDates.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !summary.manualCurrencies.isEmpty {
                Text(L("使用手动汇率：", "Manual rates: ") + summary.manualCurrencies.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(L("参考汇率按工作日更新，并非实时成交价。可填银行实际汇率；不会改写历史账单。", "Reference rates update on working days, not in real time. You can enter bank rates without changing historical entries."))
                .font(.caption).foregroundStyle(.secondary)
            if let rateRefreshError {
                Label(rateRefreshError, systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(.orange)
            }
            Toggle(L("自动更新参考汇率", "Update reference rates automatically"), isOn: $automaticRates)
                .font(.caption)
            ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                Button(action: refreshRates) { Text(refreshing ? L("更新中…", "Updating…") : L("更新汇率", "Update rates")).frame(minHeight: compact ? 44 : nil) }.disabled(refreshing)
                Button { showAssetRates = true } label: { Text(L("填写 / 管理汇率", "Edit exchange rates")).frame(minHeight: compact ? 44 : nil) }
            }
            VStack(alignment: .leading, spacing: 6) {
                Button(refreshing ? L("更新中…", "Updating…") : L("更新汇率", "Update rates"), action: refreshRates).disabled(refreshing).frame(minHeight: 44)
                Button(L("填写 / 管理汇率", "Edit exchange rates")) { showAssetRates = true }.frame(minHeight: 44)
            }
            }.font(.callout).frame(minHeight: compact ? 44 : 24)
        }
    }
    private func accountRow(_ account: MoneyAccount, balance: Decimal) -> some View {
        let foreign = account.currency != "CNY"
        return Button { showAccount(account.id) } label: {
            HStack(spacing: 12) {
                MoneyIcon(symbol: account.iconSymbol, emoji: account.emoji, tint: .accentColor, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.name).lineLimit(2)
                    Text([account.bankName, account.currency, account.archived ? L("已归档", "Archived") : nil].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(display(balance, account.currency)).font(.body.weight(.medium)).monospacedDigit().foregroundStyle(balance < 0 ? Color.red : .primary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    if foreign {
                        if let base = data.converted(balance, from: account.currency, to: "CNY") {
                            Text("≈ " + display(base, "CNY")).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        } else {
                            Text(L("缺少汇率", "Rate needed")).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }.padding(.horizontal, 12).padding(.vertical, 12).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("查看这个账户的全部账单", "Show every entry for this account"))
        .contextMenu {
            Button(L("查看账单", "Show entries")) { showAccount(account.id) }
            Button(L("编辑账户", "Edit account")) { entity = EntityRequest(kind: .account, existingID: account.id) }
            Button(L("核对余额", "Check balance")) { reconcile(account) }
        }
    }
    private func showAccount(_ id: UUID) {
        if accountDetailID == nil { rangeBeforeAccount = dateRange }
        drilldown = nil; accountDetailID = id; accountFilter = nil; categoryFilter = nil; kindFilter = nil; search = ""; dateRange = .all
        selection = "all"
    }

    // MARK: Categories and settings

    private var managementPage: some View {
        Form {
            Section {
                ForEach(data.books.filter { !$0.archived }) { book in managedBookRow(book) }
                if data.books.contains(where: \.archived) {
                    DisclosureGroup(L("已归档账本", "Archived books")) {
                        ForEach(data.books.filter(\.archived)) { book in managedBookRow(book) }
                    }
                }
                Button(L("新增账本", "New book")) { entity = EntityRequest(kind: .book) }
            } header: { Text(L("账本与预算", "Books & budgets")) } footer: {
                Text(L("账本用来分开日常、旅行等开支；账户由所有账本共用，任何账本里的消费都会从同一个账户余额扣除。", "Books separate daily and travel spending; accounts are shared, so any book's spending comes out of the same balance.")).font(.caption).foregroundStyle(.secondary)
            }
            Section { categoryGrid(income: false) } header: { Text(L("支出分类", "Spending categories")) }
            Section { categoryGrid(income: true) } header: { Text(L("收入分类", "Income categories")) }
            Section {
                Picker(L("统计币种", "Reporting currency"), selection: Binding(get: { data.baseCurrency }, set: { currency in mutate { try $0.changeBaseCurrency(to: currency, expected: data.baseCurrency) } })) {
                    CurrencyPickerItems()
                }.disabled(!data.canChangeBaseCurrency)
                if !data.canChangeBaseCurrency {
                    Text(L("已有账单或预算，统计币种已锁定。预算可清空后重设；查看其他币种请使用统计页面的显示币种。", "Entries or budgets lock the reporting currency. Clear budgets before changing it, or choose a display currency in Statistics."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(L("历史折算金额与预算使用此本位币。账单显示可跟随常用账户；资产总额折合人民币。", "Recorded conversions and budgets use this base currency. Entries can follow the default account; net worth is shown in CNY.")).font(.caption).foregroundStyle(.secondary)
            } header: { Text(L("统计币种", "Reporting currency")) }
            Section {
                Toggle(L("自动更新参考汇率", "Update reference rates automatically"), isOn: $automaticRates)
                HStack {
                    Text(L("资产页外币账户估值", "Foreign account estimates"))
                    Spacer()
                    Button(refreshing ? L("更新中…", "Updating…") : L("更新汇率", "Update rates"), action: refreshRates).disabled(refreshing)
                }
                Button(L("填写 / 管理资产汇率", "Edit asset exchange rates")) { showAssetRates = true }
                if !data.missingConversionEntries.isEmpty {
                    Button(L("补全历史账单折算…", "Complete past conversions…")) { prepareConversion(data.entries) }
                }
                if let rateRefreshError { Text(rateRefreshError).font(.caption).foregroundStyle(.orange) }
                Text(L("使用欧洲央行公开参考汇率，只下载汇率，不上传金额、账户、备注或任务。记账时可改成银行实际扣款金额，已填写的不会被覆盖。", "Uses public ECB reference rates. Only rates are downloaded; nothing about your ledger is uploaded. Actual bank amounts you enter are never overwritten.")).font(.caption).foregroundStyle(.secondary)
                Link(L("汇率来源说明", "About the rate source"), destination: URL(string: "https://www.ecb.europa.eu/stats/policy_and_exchange_rates/euro_reference_exchange_rates/html/index.en.html")!)
            } header: { Text(L("汇率", "Exchange rates")) }
            Section {
                if !data.hasSamples {
                    Button(L("添加示例账本", "Add example book"), action: addSamples)
                    Text(L("2 个示例账户、3 笔账单和一个子分类，可随时清理。示例会计入资产总额。", "Two example accounts, three entries and a subcategory. Clear them at any time. Examples count in asset totals."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if data.hasSamples { Button(L("清除示例数据…", "Clear example data…"), role: .destructive) { confirmSamples = true } }
                Button(L("导出全部账单 CSV…", "Export all entries as CSV…")) { document = FinanceCSV(data.csv(data.entries.filter { $0.deletedAt == nil }.sorted { $0.date > $1.date })); exporting = true }
                Button(L("完整备份与恢复…", "Full backup and restore…"), action: settings)
                Button(L("应用设置…", "App settings…"), action: settings)
            } header: { Text(L("数据与设置", "Data & settings")) }
        }.formStyle(.grouped)
    }
    private func managedBookRow(_ book: MoneyBook) -> some View {
        HStack {
            Label { Text(book.name) } icon: { MoneyGlyph(symbol: book.iconSymbol, emoji: book.emoji) }
            Spacer()
            Text(book.budget.map { L("预算 ", "Budget ") + display($0) + L(" / 月", " / month") } ?? L("未设预算", "No budget")).foregroundStyle(.secondary).monospacedDigit()
            Button(L("编辑", "Edit")) { entity = EntityRequest(kind: .book, existingID: book.id) }
        }
    }
    private func categoryGrid(income: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            categoryItems(income: income, archived: false)
            if data.categories.contains(where: { $0.isIncome == income && $0.archived }) {
                DisclosureGroup(L("已归档分类", "Archived categories")) { categoryItems(income: income, archived: true) }
            }
        }
    }
    private func categoryItems(income: Bool, archived: Bool) -> some View {
        let items = data.orderedCategories.filter { $0.isIncome == income && $0.archived == archived }
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(items) { category in
                HStack(spacing: 10) {
                    if category.parentID != nil { Image(systemName: "arrow.turn.down.right").font(.caption).foregroundStyle(.secondary).padding(.leading, 12) }
                    Button { entity = EntityRequest(kind: .category, existingID: category.id, income: income) } label: {
                        HStack(spacing: 10) {
                            MoneyIcon(symbol: category.symbol, emoji: category.emoji, tint: MoneyColor.color(category.resolvedColor), size: 32)
                            Text(category.parentID == nil ? category.label : data.categoryPath(category.id)).lineLimit(2)
                            Spacer(minLength: 0)
                        }.frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if category.parentID == nil && !archived {
                        Button { entity = EntityRequest(kind: .category, income: income, parentID: category.id) } label: {
                            Label(L("添加子分类", "Add subcategory"), systemImage: "plus")
                        }.buttonStyle(.borderless).frame(minWidth: compact ? 44 : nil, minHeight: 44)
                            .labelStyle(.iconOnly).accessibilityLabel(L("为", "Add a subcategory to ") + category.label + L("添加子分类", ""))
                    }
                }
            }
            if !archived {
                Button { entity = EntityRequest(kind: .category, income: income) } label: { Label(L("新增大类", "New main category"), systemImage: "plus") }
                    .frame(minHeight: 44)
            }
        }.padding(.vertical, 4)
    }

    // MARK: Actions

    private func reload() {
        do {
            let payload = try FinanceStore.payload(context)
            if let payload, payload == loadedPayload, loadingError == nil { return }
            data = try payload.map(FinanceStore.decode) ?? .initial
            loadedPayload = payload; loadingError = nil
            if let id = accountDetailID, data.account(id) == nil { accountDetailID = nil }
            if let id = accountFilter, data.account(id) == nil { accountFilter = nil }
            if let id = categoryFilter, data.category(id) == nil { categoryFilter = nil }
            if !scope.isEmpty && bookFilterID == nil { scope = "" }
            upgradeDefaultsOnce()
        } catch { loadingError = error.localizedDescription }
    }
    /// 0.2.1 adds income categories and more spending ones to an existing ledger, once.
    private func upgradeDefaultsOnce() {
        guard !UserDefaults.standard.bool(forKey: "moneyDefaults021") else { return }
        var upgraded = data; upgraded.addMissingDefaults()
        guard upgraded.categories != data.categories else { UserDefaults.standard.set(true, forKey: "moneyDefaults021"); return }
        guard (try? FinanceStore.payload(context)) != nil else { data = upgraded; return }
        do {
            try FinanceStore.update(context) { $0.addMissingDefaults() }
            UserDefaults.standard.set(true, forKey: "moneyDefaults021")
            data = try FinanceStore.read(context) ?? upgraded
        } catch {}
    }
    private func mutate(_ change: (inout FinanceData) throws -> Void) {
        do { try FinanceStore.update(context, change); reload() } catch { self.error = error.localizedDescription }
    }
    private func newEntry() {
        editor = EntryRequest(entry: data.newEntry(preferredBook: bookFilterID, preferredAccount: accountDetailID ?? accountFilter), expected: nil)
    }
    private func duplicate(_ original: MoneyEntry) {
        editor = EntryRequest(entry: data.copyEntry(original, preferredBookID: bookFilterID), expected: nil)
    }
    private func newRefund(_ original: MoneyEntry) {
        guard data.remainingRefund(for: original.id) > 0 else { return }
        var entry = MoneyEntry(); entry.kind = .refund; entry.title = String((L("退款：", "Refund: ") + original.title).prefix(80))
        entry.currency = original.currency; entry.accountID = original.accountID; entry.bookID = original.bookID; entry.categoryID = original.categoryID; entry.refundOf = original.id
        entry.amount = data.remainingRefund(for: original.id)
        editor = EntryRequest(entry: entry, expected: nil)
    }
    private func reconcile(_ account: MoneyAccount) {
        editor = EntryRequest(entry: data.reconciliationEntry(for: account.id, bookID: bookFilterID), expected: nil)
    }
    private func delete(_ entry: MoneyEntry) {
        do {
            try FinanceStore.update(context) { try $0.trash(entry) }
            reload(); lastDeleted = data.entries.first { $0.id == entry.id }
        } catch { self.error = error.localizedDescription }
    }
    private func restore(_ entry: MoneyEntry) {
        do { try FinanceStore.update(context) { try $0.restore(entry) }; lastDeleted = nil; reload() } catch { self.error = error.localizedDescription }
    }
    private func addSamples() {
        do {
            var bookID: UUID?
            try FinanceStore.update(context) { bookID = try $0.addSamples() }
            reload(); scope = bookID?.uuidString ?? ""; selection = "all"
            entriesCurrencyRaw = ""; anchor = Date(); dateRange = .month
        } catch { self.error = error.localizedDescription }
    }
    /// Saves a complete backup file first, then removes the example accounts, books and entries in one save.
    private func clearSamples() {
        do {
            let backup = try TaskBackup.capture(context).encoded()
            let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("JianshiBackups", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let stamp = ExchangeRates.dayString(Date()) + "-" + String(Int(Date().timeIntervalSince1970))
            let file = folder.appendingPathComponent("before-clearing-examples-\(stamp).json")
            try backup.write(to: file, options: .atomic)
            var result = FinanceData.SampleCleanup()
            try FinanceStore.update(context) { result = $0.removeSamples() }
            reload()
            for key in ["lastMoneyAccount", "lastMoneyBook"] {
                if let raw = UserDefaults.standard.string(forKey: key), raw != "none",
                   !data.accounts.contains(where: { $0.id.uuidString == raw }) && !data.books.contains(where: { $0.id.uuidString == raw }) {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
            info = L("已清除 \(result.entries) 笔示例账单、\(result.accounts) 个账户、\(result.books) 个账本。清除前的完整备份：\(file.path)",
                     "Removed \(result.entries) entries, \(result.accounts) accounts and \(result.books) books. Backup saved at \(file.path)")
        } catch { self.error = error.localizedDescription }
    }
    private func refreshRates() { Task { await updateAssetRates() } }
    @MainActor private func updateAssetRates() async {
        guard !refreshing else { return }
        refreshing = true; rateRefreshError = nil
        defer { refreshing = false }
        do {
            let quotes = Array(Set(data.accounts.map(\.currency) + [data.baseCurrency]))
            let result = try await ExchangeRates.fetchAvailable(base: "CNY", quotes: quotes)
            guard !Task.isCancelled else { return }
            automaticRateRetryAfter = nil
            let reference = result.rates
            var rates = reference + reference.map { MoneyRate(base: $0.quote, quote: $0.base, rate: 1 / $0.rate, date: $0.date, source: $0.source) }
            if let base = reference.first(where: { $0.quote == data.baseCurrency }) {
                rates += reference.filter { $0.quote != data.baseCurrency }.map {
                    MoneyRate(base: $0.quote, quote: data.baseCurrency, rate: base.rate / $0.rate, date: $0.date, source: $0.source)
                }
            }
            if !rates.isEmpty {
                try FinanceStore.update(context) { try $0.mergeReferenceRates(rates) }
                reload()
            }
            if !result.missingCurrencies.isEmpty {
                let names = result.missingCurrencies.joined(separator: ", ")
                rateRefreshError = L("\(names) 暂无参考报价；其他币种已更新。可为这些币种手动填写，已有值保留。", "No reference quote for \(names). Available currencies updated; existing values are kept. You can enter the missing rates manually.")
            }
        } catch {
            automaticRateRetryAfter = Date().addingTimeInterval(5 * 60)
            rateRefreshError = L("汇率更新失败。已有汇率仍保留；稍后自动重试，也可手动更新或填写。", "Rates could not update. Existing rates are kept; automatic updates retry shortly. You can also retry or enter a rate manually.")
        }
    }

}

/// One entry line. Hover lives here, so moving the pointer never re-renders the whole list.
struct FinanceEntryRow<Actions: View>: View {
    @AppStorage("appLanguage") private var language = "system"
    let entry: MoneyEntry
    let data: FinanceData
    let showBook: Bool
    let hidden: Bool
    var accountID: UUID? = nil
    var balanceAfter: Decimal? = nil
    var restore: (() -> Void)?
    let open: () -> Void
    @ViewBuilder let actions: () -> Actions
    @State private var hovering = false
    var body: some View {
        let icon = data.icon(entry)
        HStack(spacing: 12) {
            MoneyIcon(symbol: icon.symbol, emoji: icon.emoji, tint: icon.tint, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                Text(amount).font(.body.weight(.medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8).foregroundStyle((accountID.map { entry.accountChange(for: $0) > 0 } ?? (entry.kind == .income || entry.kind == .refund)) ? Color.green : .primary)
                if let secondary { Text(secondary).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                if let balanceAfter, let account = data.account(accountID) {
                    Text(L("余额 ", "Balance ") + (hidden ? "••••" : Money.format(balanceAfter, account.currency)))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .help(L("这笔之后的账户账面余额，包含未显示的其他流水。相同时间按列表顺序计算。", "Account balance after this entry, including other hidden entries. Equal timestamps follow list order."))
                }
            }
            if let restore { Button(L("恢复", "Restore"), action: restore).controlSize(.small) }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Color.primary.opacity(0.05) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .contextMenu(menuItems: actions)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(restore == nil ? [.isButton] : [])
        .accessibilityAction { if restore == nil { open() } }
    }
    private var detail: String {
        var parts = [Dates.label(entry.date, pattern: "HH:mm")]
        if let category = data.category(entry.categoryID), category.label != entry.title, entry.kind != .transfer { parts.append(data.categoryPath(category.id)) }
        switch entry.kind {
        case .transfer:
            if let accountID { parts.append(accountID == entry.destinationID ? L("转入", "Transfer in") : L("转出", "Transfer out")) }
            parts.append((data.account(entry.accountID)?.name ?? "") + " → " + (data.account(entry.destinationID)?.name ?? ""))
        case .refund: parts.append(L("退款", "Refund")); if accountID == nil, let a = data.account(entry.accountID) { parts.append(a.name) }
        default: if accountID == nil, let a = data.account(entry.accountID) { parts.append(a.name) }
        }
        if showBook, let book = data.book(entry.bookID) { parts.append(book.name) }
        if !entry.tags.isEmpty { parts.append(entry.tags) }
        if entry.kind != .transfer && entry.kind != .adjustment && entry.baseAmount == nil { parts.append(L("待折算", "Unconverted")) }
        return parts.joined(separator: " · ")
    }
    private var amount: String {
        guard !hidden else { return "••••" }
        if let id = accountID, let account = data.account(id) {
            let change = entry.accountChange(for: id)
            return (change > 0 ? "+" : "") + Money.format(change, account.currency)
        }
        let text = Money.format(entry.amount, entry.currency)
        switch entry.kind {
        case .expense: return "-" + text
        case .income, .refund: return "+" + text
        case .adjustment: return entry.amount > 0 ? "+" + text : text
        case .transfer: return text
        }
    }
    /// What actually left or reached the account when its currency differs, else the base-currency equivalent.
    private var secondary: String? {
        guard !hidden else { return nil }
        if let id = accountID, let viewing = data.account(id) {
            if entry.fee > 0, entry.accountID == id { return L("含手续费 ", "Includes fee ") + Money.format(entry.fee, viewing.currency) }
            if entry.currency != viewing.currency { return L("原金额 ", "Original ") + Money.format(entry.amount, entry.currency) }
            return nil
        }
        let account = data.account(entry.accountID)
        if let account, account.currency != entry.currency, entry.accountAmount != 0 {
            let out = entry.kind == .expense || entry.kind == .transfer
            return (out ? L("实扣 ", "Charged ") : L("实收 ", "Received ")) + Money.format(entry.accountAmount, account.currency)
        }
        if entry.kind == .transfer, let d = data.account(entry.destinationID), d.currency != entry.currency {
            let received = L("到账 ", "Received ") + Money.format(entry.destinationAmount, d.currency)
            return received + (entry.fee > 0 ? " · " + L("手续费 ", "Fee ") + Money.format(entry.fee, account?.currency ?? entry.currency) : "")
        }
        if entry.fee > 0 { return L("手续费 ", "Fee ") + Money.format(entry.fee, account?.currency ?? entry.currency) }
        if entry.currency != data.baseCurrency, let base = entry.baseAmount { return "≈ " + Money.format(base, data.baseCurrency) }
        return nil
    }
}

private struct MoneyConversionRequest: Identifiable {
    let id = UUID()
    let ledger: FinanceData
}

/// Preparing a preview never writes the ledger. The store rechecks every original when confirmed.
private struct FinanceConversionPreview: View {
    let ledger: FinanceData
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hideMoney") private var hidden = false
    @AppStorage("appLanguage") private var language = "system"
    @State private var preview: MoneyConversionPreview?
    @State private var loading = true
    @State private var error: String?
    @State private var notice: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(L("仅补全当前范围内尚未折算的账单，原币金额、账户余额和已填写的折算金额保持不变。", "Completes missing conversions in the selected scope. Original amounts, account balances and existing conversions stay unchanged."))
                    Text(L("有本币实际扣款时优先采用；否则使用账单当日或此前最近发布的欧洲央行参考价。保存后不会随新汇率变动。", "Uses actual account amounts in the reporting currency where available; otherwise, the ECB quote on or most recently before each entry’s date. Saved conversions stay fixed."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if loading { ProgressView(L("正在准备折算预览…", "Preparing conversions…")) }
                if let notice { Text(notice).font(.caption).foregroundStyle(.orange) }
                if let preview {
                    Section(L("可补全 \(preview.changes.count) 笔 · \(preview.baseCurrency)", "\(preview.changes.count) ready · \(preview.baseCurrency)")) {
                        if preview.changes.isEmpty { Text(L("当前没有可自动补全的账单。", "No entries can be completed automatically in this scope.")).foregroundStyle(.secondary) }
                        ForEach(preview.changes, id: \.original.id) { change in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(change.original.title).font(.headline)
                                Text(Dates.label(change.original.date, pattern: "yyyy年M月d日"))
                                    .font(.caption).foregroundStyle(.secondary)
                                if change.original.kind == .transfer {
                                    Text(L("手续费折合：", "Converted fee: ") + Money.display(change.updated.baseFee ?? 0, preview.baseCurrency, hidden: hidden)).monospacedDigit()
                                } else {
                                    Text(Money.display(change.original.amount, change.original.currency, hidden: hidden) + " → " + Money.display(change.updated.baseAmount ?? 0, preview.baseCurrency, hidden: hidden)).monospacedDigit()
                                }
                                if let rate = change.rate {
                                    Text("ECB · " + rate.date + " · 1 " + rate.base + " = " + assetRateText(rate.rate) + " " + rate.quote)
                                        .font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text(L("采用账户实际金额", "Uses the actual account amount")).font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 4)
                        }
                    }
                    if !preview.futureEntries.isEmpty {
                        Section(L("未来日期 · 暂不折算", "Future dates · skipped")) {
                            Text(L("未来的参考价尚未发布。到记账日期后可再次补全，或逐笔填写实际金额。", "Future quotes are not available yet. Complete these after their dates or enter actual amounts individually.")).font(.caption).foregroundStyle(.secondary)
                            ForEach(preview.futureEntries) { entry in pendingEntry(entry) }
                        }
                    }
                    if !preview.unavailableEntries.isEmpty {
                        Section(L("缺少历史报价 · 暂不折算", "Historical quotes unavailable · skipped")) {
                            Text(L("这些账单保持原样，可联网后重试，或打开账单填写实际折算金额。", "These entries stay unchanged. Retry online or open each entry to enter its actual conversion.")).font(.caption).foregroundStyle(.secondary)
                            ForEach(preview.unavailableEntries) { entry in pendingEntry(entry) }
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.formStyle(.grouped)
            .navigationTitle(L("补全折算", "Complete conversions"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("取消", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("确认补全", "Confirm"), action: save).disabled(loading || preview?.changes.isEmpty != false)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 540, minHeight: 460, idealHeight: 600)
        #endif
        .task {
            var history = await RateHistoryStore.cached
            let first = ledger.missingConversionEntries.map(\.date).filter { $0 <= Date() }.min()
            if let first {
                do { history = try await RateHistoryStore.load(since: first) }
                catch { notice = L("历史汇率未能更新，将只使用可用的已缓存报价或实际本币金额。", "Historical rates could not update. Only usable cached quotes and actual reporting-currency amounts are included.") }
            }
            guard !Task.isCancelled else { return }
            preview = ledger.missingConversionPreview(history: history)
            loading = false
        }
        .modifier(SaveRecoveryGuard())
        .modifier(CloudSyncEditingGuard())
    }
    private func pendingEntry(_ entry: MoneyEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.title)
            Text(Dates.label(entry.date, pattern: "yyyy年M月d日") + " · " + entry.currency).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func save() {
        guard let preview, !preview.changes.isEmpty else { return }
        do {
            try FinanceStore.update(context) { try $0.applyMissingConversions(preview) }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Asset reference rates

private func assetRateText(_ value: Decimal) -> String {
    var rate = value, rounded = Decimal.zero
    NSDecimalRound(&rounded, &rate, 9, .plain)
    return Money.text(rounded)
}

private struct FinanceRateEditor: View {
    let data: FinanceData
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appLanguage") private var language = "system"
    @FocusState private var rateFocused: Bool
    @State private var values: [String: String] = [:]
    @State private var restoreReference: Set<String> = []
    @State private var error: String?
    private var currencies: [String] { Set(data.accounts.map(\.currency)).filter { $0 != "CNY" }.sorted() }
    private func originalText(_ currency: String) -> String {
        guard let stored = data.storedRate(from: currency, to: "CNY") else { return "" }
        return assetRateText(stored.rate)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(L("填写 1 单位外币兑换多少人民币，例如 1 USD = 7.10 CNY。只改变当前资产估值，不改变账单。", "Enter CNY per 1 unit of foreign currency, for example 1 USD = 7.10 CNY. This changes asset estimates, not recorded entries."))
                        .font(.callout)
                }
                if currencies.isEmpty { Text(L("添加外币账户后可在这里填写汇率。", "Add a foreign-currency account to enter its rate here.")) }
                ForEach(currencies, id: \.self) { currency in
                    Section(Money.name(currency) + " · " + currency) {
                        HStack {
                            Text("1 " + currency + " =")
                            TextField(L("汇率", "Rate"), text: Binding(get: { values[currency, default: originalText(currency)] }, set: { values[currency] = $0; restoreReference.remove(currency) }))
                                .multilineTextAlignment(.trailing).monospacedDigit().focused($rateFocused)
                                .accessibilityLabel("1 " + currency + L("兑换人民币汇率", " in CNY"))
                                #if os(iOS)
                                .keyboardType(.decimalPad)
                                #endif
                            Text("CNY").foregroundStyle(.secondary)
                        }.frame(minHeight: 44)
                        if restoreReference.contains(currency) {
                            Text(L("保存后清除手动汇率，可点“更新汇率”获取参考值。", "Saving clears the manual rate. Use Update rates to fetch a reference value.")).font(.caption).foregroundStyle(.secondary)
                        } else if let rate = data.storedRate(from: currency, to: "CNY") {
                            Text((rate.isManual ? L("手动汇率 · ", "Manual rate · ") : L("欧洲央行参考汇率 · ", "ECB reference rate · ")) + rate.date)
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(L("暂无汇率，此币种尚未计入总额。", "No rate yet. This currency cannot be included in the total.")).font(.caption).foregroundStyle(.orange)
                        }
                        if data.storedRate(from: currency, to: "CNY")?.isManual == true {
                            Button(L("恢复参考汇率", "Restore reference rate")) { restoreReference.insert(currency); values[currency] = "" }
                                .frame(minHeight: 44)
                        }
                    }
                }
                Section {
                    Text(L("保存过的手动汇率不会被自动更新覆盖。参考汇率按工作日更新，未联网时保留原值。", "Automatic updates keep manual rates. Reference rates update on working days; cached rates remain available offline."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.formStyle(.grouped)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(L("资产汇率", "Asset exchange rates"))
            .toolbar {
                #if os(iOS)
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button(L("完成", "Done")) { rateFocused = false } }
                #endif
                ToolbarItem(placement: .cancellationAction) { Button(L("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) { Button(L("保存", "Save"), action: save).keyboardShortcut("s", modifiers: .command) }
            }
        }
        #if os(macOS)
        .frame(minWidth: 430, idealWidth: 480, minHeight: 400, idealHeight: 520)
        #endif
        .modifier(SaveRecoveryGuard())
        .modifier(CloudSyncEditingGuard())
    }
    private func save() {
        do {
            let changed = currencies.filter { restoreReference.contains($0) || (values[$0] != nil && values[$0] != originalText($0)) }
            if !changed.isEmpty {
                try FinanceStore.update(context) { ledger in
                    for currency in changed {
                        guard ledger.storedRate(from: currency, to: "CNY") == data.storedRate(from: currency, to: "CNY") else {
                            throw TaskBackup.invalid(L("汇率已更新，请重新打开后修改。", "Rates have changed. Reopen this editor before changing them."))
                        }
                        if restoreReference.contains(currency) { ledger.removeManualRate(from: currency, to: "CNY") }
                        else { try ledger.setManualRate(from: currency, to: "CNY", text: values[currency, default: ""]) }
                    }
                }
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Account, book and category editor

struct EntityRequest: Identifiable { var id = UUID(); var kind: FinanceEntityKind; var existingID: UUID?; var income = false; var parentID: UUID? = nil }
struct FinanceEntityDraft {
    var original: FinanceData
    var kind: FinanceEntityKind
    var id: UUID?
    var name: String, currency: String, opening: String, symbol: String
    var archived: Bool
    var accountID: UUID?
    var income = false
    var color = ""
    var type = ""
    var budget = ""
    var emoji = ""
    var bankName = ""
    var assetRate = ""
    var parentID: UUID? = nil
}
struct FinanceEntityEditor: View {
    static let symbols = ["fork.knife", "cup.and.saucer", "takeoutbag.and.cup.and.straw", "cart", "bag", "basket", "tshirt", "tram", "car", "bus", "fuelpump", "airplane",
                          "house", "bolt", "drop", "iphone", "wifi", "heart", "cross.case", "pills", "figure.run", "gamecontroller", "film", "music.note",
                          "book", "graduationcap", "pawprint", "gift", "scissors", "wrench.and.screwdriver", "creditcard", "banknote", "rosette",
                          "chart.line.uptrend.xyaxis", "briefcase", "envelope", "sparkles", "tag", "plus.circle", "ellipsis.circle"]
    @AppStorage("appLanguage") private var language = "system"
    @Environment(EditorDrafts.self) private var drafts
    @State private var generation = Store.recovery.generation
    @State private var ready = false
    @FocusState private var textFocused: Bool
    let kind: FinanceEntityKind
    let id: UUID?
    @State private var original: FinanceData
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var currency: String
    @State private var opening: String
    @State private var archived: Bool
    @State private var accountID: UUID?
    @State private var symbol: String
    @State private var emoji: String
    @State private var showIconPicker = false
    @State private var income: Bool
    @State private var color: String
    @State private var type: String
    @State private var budget: String
    @State private var bankName: String
    @State private var assetRate = ""
    @State private var parentID: UUID?
    @State private var confirmRemoval = false
    @State private var correctingOpening = false
    @State private var confirmOpening = false
    @State private var reconciliation: MoneyEntry?
    @State private var error: String?
    init(kind: FinanceEntityKind, id: UUID? = nil, income: Bool = false, parentID: UUID? = nil, data: FinanceData) {
        self.kind = kind; self.id = id; _original = State(initialValue: data)
        let account = data.accounts.first { $0.id == id }, book = data.books.first { $0.id == id }, category = data.categories.first { $0.id == id }
        _name = State(initialValue: kind == .account ? account?.name ?? "" : kind == .book ? book?.name ?? "" : category?.label ?? "")
        _currency = State(initialValue: account?.currency ?? data.baseCurrency); _opening = State(initialValue: Money.text(account?.opening ?? 0))
        _archived = State(initialValue: account?.archived ?? book?.archived ?? category?.archived ?? false)
        _accountID = State(initialValue: book?.defaultAccountID)
        _symbol = State(initialValue: kind == .account ? account?.symbol ?? "" : kind == .book ? book?.symbol ?? "" : category?.symbol ?? "")
        _emoji = State(initialValue: kind == .account ? account?.emoji ?? "" : kind == .book ? book?.emoji ?? "" : category?.emoji ?? "")
        _income = State(initialValue: category?.isIncome ?? income)
        _color = State(initialValue: category?.resolvedColor ?? (income ? "green" : "blue"))
        _type = State(initialValue: (account?.resolvedType ?? .debit).rawValue)
        _budget = State(initialValue: book?.budget.map(Money.text) ?? "")
        _bankName = State(initialValue: account?.bankName ?? "")
        _parentID = State(initialValue: category?.parentID ?? parentID)
    }
    private var bankField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("所属银行", "Bank")).font(.subheadline.weight(.medium))
            TextField(L("可不填", "Optional"), text: $bankName).focused($textFocused).accessibilityLabel(L("所属银行", "Bank"))
            Menu {
                ForEach([L("中国工商银行", "ICBC"), L("中国建设银行", "China Construction Bank"), L("中国银行", "Bank of China"),
                         L("中国农业银行", "Agricultural Bank of China"), L("招商银行", "China Merchants Bank"), L("交通银行", "Bank of Communications"),
                         L("中信银行", "CITIC Bank"), L("浦发银行", "SPD Bank"), L("平安银行", "Ping An Bank"),
                         "Commonwealth Bank", "ANZ", "NAB", "Westpac", "HSBC", "Citibank", "Chase", "Bank of America"], id: \.self) { bank in
                    Button(bank) { bankName = bank }
                }
                Divider()
                Button(L("清除银行", "Clear bank")) { bankName = "" }
            } label: { Label(L("选择所属银行", "Choose bank"), systemImage: "building.columns") }
                .frame(minHeight: 44)
            Text(L("也可直接输入其他银行名称；仅作账户标记。", "You can type any other bank name. This is an account label."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var accountRateField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("资产参考汇率（可不填）", "Asset exchange rate (optional)")).font(.subheadline.weight(.medium))
            HStack {
                Text("1 " + currency + " =")
                TextField(L("汇率（可不填）", "Rate (optional)"), text: $assetRate).focused($textFocused)
                    .multilineTextAlignment(.trailing).monospacedDigit()
                    .accessibilityLabel("1 " + currency + L("兑换人民币汇率", " in CNY"))
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                Text("CNY").foregroundStyle(.secondary)
            }
            if let rate = original.storedRate(from: currency, to: "CNY") {
                let source = rate.isManual ? L("手动", "Manual") : rate.date
                let quote = "1 \(currency) = \(assetRateText(rate.rate)) CNY · \(source)"
                Text(L("当前：", "Current: ") + quote).font(.caption).foregroundStyle(.secondary)
            }
            Text(L("留空保留现有汇率；没有时，资产页会按自动汇率设置获取参考值。手动汇率仅用于所有 \(currency) 账户的人民币估值；账单请填写实际金额或使用参考汇率。", "Leave blank to keep the current rate; Assets can fetch a reference rate when automatic rates are enabled. Manual rates only value \(currency) assets in CNY; entries use actual amounts or reference rates."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var fallbackSymbol: String {
        switch kind {
        case .account: return (MoneyAccountType(rawValue: type) ?? .debit).symbol
        case .book: return "book.closed"
        case .category: return income ? "banknote" : "tag"
        }
    }
    private var chosenSymbol: String { symbol.isEmpty ? fallbackSymbol : symbol }
    private var used: Bool { id.map { id in original.entries.contains { $0.accountID == id || $0.destinationID == id } } ?? false }
    private var categoryUsed: Bool { kind == .category && id.map { id in original.entries.contains { $0.categoryID == id } || original.categories.contains { $0.parentID == id } } == true }
    var body: some View {
        NavigationStack {
            Form {
                HStack(spacing: 12) {
                    Button { showIconPicker = true } label: {
                        VStack(spacing: 4) {
                            MoneyIcon(symbol: chosenSymbol, emoji: emoji.isEmpty ? nil : emoji, tint: kind == .category ? MoneyColor.color(color) : .accentColor, size: 44)
                            Text(L("换图标", "Change icon")).font(.caption2)
                        }
                    }.buttonStyle(.plain).help(L("选择系统图标或苹果表情", "Choose a symbol or emoji"))
                        .popover(isPresented: $showIconPicker) { MoneyIconPicker(symbol: $symbol, emoji: $emoji, fallback: fallbackSymbol) }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("名称", "Name")).font(.caption).foregroundStyle(.secondary)
                        TextField(L("名称", "Name"), text: $name).focused($textFocused).textFieldStyle(.roundedBorder).font(.title3)
                    }
                }
                if kind == .category {
                    Picker(L("用于", "Used for"), selection: $income) { Text(L("支出", "Spending")).tag(false); Text(L("收入", "Income")).tag(true) }.pickerStyle(.segmented)
                        .disabled(categoryUsed)
                    if categoryUsed { Text(L("此分类已有账单或子分类，不能在支出和收入之间切换。", "This category has entries or subcategories, so it cannot switch between spending and income.")).font(.caption).foregroundStyle(.secondary) }
                    Picker(L("上级分类", "Parent category"), selection: $parentID) {
                        Text(L("无，作为大类", "None — top level")).tag(nil as UUID?)
                        ForEach(original.categories.filter { $0.id != id && $0.parentID == nil && $0.isIncome == income && (!$0.archived || $0.id == parentID) }) {
                            Text($0.label).tag(Optional($0.id))
                        }
                    }.disabled(id.map { id in original.categories.contains { $0.parentID == id } } ?? false)
                    Text(L("支持大类和子分类两层。大类统计包含它的所有子分类。", "Use a main category and its subcategories. Main category totals include every child."))
                        .font(.caption).foregroundStyle(.secondary)
                    Section(L("颜色", "Color")) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 8) {
                            ForEach(MoneyColor.keys, id: \.self) { key in
                                Button { color = key } label: {
                                    Circle().fill(MoneyColor.color(key)).frame(width: 22, height: 22)
                                        .overlay(Circle().strokeBorder(Color.primary.opacity(color == key ? 0.9 : 0), lineWidth: 2).padding(-3))
                                }.buttonStyle(.plain).frame(minWidth: 44, minHeight: 44).accessibilityLabel(MoneyColor.label(key)).accessibilityAddTraits(color == key ? [.isSelected] : []).help(MoneyColor.label(key))
                            }
                        }.padding(.vertical, 4)
                    }
                }
                if kind == .account {
                    Picker(L("类型", "Type"), selection: $type) { ForEach(MoneyAccountType.allCases) { Label($0.label, systemImage: $0.symbol).tag($0.rawValue) } }
                    bankField
                    Picker(L("币种", "Currency"), selection: Binding(get: { currency }, set: { currency = $0; assetRate = "" })) { CurrencyPickerItems() }.disabled(used)
                    if currency != "CNY" { accountRateField }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("期初余额", "Opening balance") + " · " + currency).font(.subheadline.weight(.medium))
                        TextField("0", text: $opening).focused($textFocused).disabled(used && !correctingOpening).monospacedDigit()
                            .accessibilityLabel(L("期初余额", "Opening balance") + " · " + currency)
                            #if os(iOS)
                            .keyboardType(.numbersAndPunctuation)
                            #endif
                    }
                    if used {
                        Text(L("已有流水，币种已锁定。期初余额是开始记账时的余额。", "Currency is locked because this account has entries. The opening balance is what you had when you started recording.")).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(L("核对当前余额…", "Check current balance…"), action: reconcile)
                            if !correctingOpening { Button(L("更正期初余额…", "Correct opening balance…")) { correctingOpening = true } }
                        }
                        if correctingOpening {
                            Text(L("仅用于修正最初填错的金额，会同步改变所有历史余额。调整现在的余额请用“核对当前余额”。", "Use this only to correct the original amount; every historical balance changes. To adjust today's balance, use Check current balance.")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    else { Text(L("信用卡欠款可填负数，例如 -1200。", "For a credit card balance owed, enter a negative number such as -1200.")).font(.caption).foregroundStyle(.secondary) }
                } else if kind == .book {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("每月预算", "Monthly budget") + " · " + original.baseCurrency).font(.subheadline.weight(.medium))
                        TextField(L("可不填", "Optional"), text: $budget).focused($textFocused).monospacedDigit()
                            .accessibilityLabel(L("每月预算", "Monthly budget"))
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                    }
                    Picker(L("常用账户", "Default account"), selection: $accountID) {
                        Text(L("每次选择", "Choose each time")).tag(nil as UUID?)
                        ForEach(original.accounts.filter { !$0.archived || $0.id == accountID }) { Text($0.name + " · " + $0.currency).tag(Optional($0.id)) }
                    }
                    Text(L("新账单金额和账单合计默认使用此账户的币种。账户由所有账本共用，不会复制余额。", "New entry amounts and entry totals default to this account's currency. Accounts are shared across books without copying balances.")).font(.caption).foregroundStyle(.secondary)
                }
                if let id {
                    Toggle(L("归档", "Archived"), isOn: $archived)
                        .disabled(kind == .book && !archived && original.bookArchiveBlock(id) != nil)
                    Text(L("归档后保留历史账目，在新增时隐藏。", "Archiving keeps all history and hides this option for new entries.")).font(.caption).foregroundStyle(.secondary)
                }
                if let id {
                    if let reason = original.removalBlock(kind, id: id) {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button(L("删除", "Delete"), role: .destructive) { confirmRemoval = true }
                    }
                }
                if let error { Text(error).font(.callout).foregroundStyle(.red) }
            }.formStyle(.grouped).scrollDismissesKeyboard(.interactively)
            .navigationTitle(kind == .account ? L("账户", "Account") : kind == .book ? L("账本", "Book") : L("分类", "Category"))
            .toolbar {
                #if os(iOS)
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button(L("完成", "Done")) { textFocused = false } }
                #endif
                ToolbarItem(placement: .cancellationAction) { Button(L("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) { Button(L("保存", "Save")) { save() }.keyboardShortcut("s", modifiers: .command).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 480, minHeight: kind == .account ? 520 : 370, idealHeight: kind == .account ? 610 : 450)
        #endif
        .sheet(item: $reconciliation) { entry in FinanceEntryEditor(entry: entry, expected: nil) }
        .confirmationDialog(L("更正期初余额？", "Correct the opening balance?"), isPresented: $confirmOpening, titleVisibility: .visible) {
            Button(L("确认更正", "Confirm correction")) { save(confirmedOpening: true) }
            Button(L("取消", "Cancel"), role: .cancel) {}
        } message: {
            let old = original.accounts.first { $0.id == id }?.opening ?? 0
            let new = (try? Money.parse(opening, currency: currency, signed: true)) ?? old
            Text(L("期初余额：", "Opening balance: ") + Money.format(old, currency) + " → " + Money.format(new, currency)
                 + "\n" + L("这会更改该账户所有历史余额，不计为收入或支出。调整当前余额请使用“核对当前余额”。", "This changes every historical balance for this account, without counting as income or spending. Use Check current balance to adjust today's balance."))
        }
        .confirmationDialog(L("删除这个项目？", "Delete this item?"), isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button(L("删除", "Delete"), role: .destructive, action: remove)
            Button(L("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(kind == .account
                 ? L("将删除此空账户及其期初余额，并清除账本的常用账户设置。无法直接撤销，可从备份恢复。", "Deletes this unused account and its opening balance, and clears book defaults. Restore a backup to undo.")
                 : L("此项目没有关联账单。删除后无法直接撤销，可从备份恢复。", "This item has no linked entries. Restore a backup to undo deletion."))
        }
        .onAppear {
            if let kept = drafts.financeEntity, kept.kind == kind, kept.id == id {
                original = kept.original
                name = kept.name; currency = kept.currency; opening = kept.opening; symbol = kept.symbol; archived = kept.archived; accountID = kept.accountID
                emoji = kept.emoji; bankName = kept.bankName; assetRate = kept.assetRate; parentID = kept.parentID; income = kept.income; if !kept.color.isEmpty { color = kept.color }; if !kept.type.isEmpty { type = kept.type }; budget = kept.budget
            }
            correctingOpening = used && opening != Money.text(original.accounts.first { $0.id == id }?.opening ?? 0)
            ready = true; keepEntityDraft()
        }
        .onChange(of: [name, currency, opening, symbol, emoji, color, type, budget, bankName, assetRate, parentID?.uuidString ?? "", "\(archived)-\(income)-\(accountID?.uuidString ?? "")"]) { _, _ in if ready { keepEntityDraft() } }
        .onChange(of: income) { _, _ in
            if let parentID, original.category(parentID)?.isIncome != income { self.parentID = nil }
        }
        .onDisappear { if generation == Store.recovery.generation && Store.recovery.failure == nil { drafts.financeEntity = nil } }
        .modifier(SaveRecoveryGuard())
        .modifier(CloudSyncEditingGuard())
    }
    private func keepEntityDraft() {
        drafts.financeEntity = FinanceEntityDraft(original: original, kind: kind, id: id, name: name, currency: currency, opening: opening, symbol: symbol, archived: archived, accountID: accountID,
                                                  income: income, color: color, type: type, budget: budget, emoji: emoji, bankName: bankName, assetRate: assetRate, parentID: parentID)
    }
    private func remove() {
        guard let id else { return }
        do {
            try FinanceStore.update(context) { try $0.remove(kind, id: id, expected: original) }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
    private func reconcile() {
        guard let id else { return }
        do {
            let data = try FinanceStore.read(context) ?? .initial
            reconciliation = data.reconciliationEntry(for: id)
        } catch { self.error = error.localizedDescription }
    }
    private func save(confirmedOpening: Bool = false) {
        do {
            keepEntityDraft()
            let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard emoji.isEmpty || TaskList.validEmoji(emoji) else { throw TaskBackup.invalid(L("请选择一个表情，或恢复默认图标。", "Choose one emoji or use the default icon.")) }
            let budgetText = budget.trimmingCharacters(in: .whitespacesAndNewlines)
            let budgetValue: Decimal? = budgetText.isEmpty ? nil : try Money.parse(budgetText, currency: original.baseCurrency)
            if let budgetValue, budgetValue <= 0 { throw TaskBackup.invalid(L("预算需要大于 0，不设预算请留空。", "A budget must be above 0; leave it empty for none.")) }
            if kind == .account, used, !confirmedOpening,
               try Money.parse(opening, currency: currency, signed: true) != original.accounts.first(where: { $0.id == id })?.opening {
                confirmOpening = true; return
            }
            try FinanceStore.update(context) { data in
                switch kind {
                case .account:
                    let value = MoneyAccount(id: id ?? UUID(), name: title, currency: currency, opening: try Money.parse(opening, currency: currency, signed: true), archived: archived, emoji: emoji.isEmpty ? nil : emoji, symbol: symbol.isEmpty ? nil : symbol, type: type, bankName: bankName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : bankName.trimmingCharacters(in: .whitespacesAndNewlines))
                    try data.updateAccount(value, expected: original.accounts.first { $0.id == id }, allowOpeningCorrection: confirmedOpening)
                    let rateText = assetRate.trimmingCharacters(in: .whitespacesAndNewlines)
                    if currency != "CNY", !rateText.isEmpty {
                        guard data.storedRate(from: currency, to: "CNY") == original.storedRate(from: currency, to: "CNY") else {
                            throw TaskBackup.invalid(L("汇率已更新，请重新打开后修改。", "Rates have changed. Reopen this editor before changing them."))
                        }
                        try data.setManualRate(from: currency, to: "CNY", text: rateText)
                    }
                case .book:
                    let value = MoneyBook(id: id ?? UUID(), name: title, defaultAccountID: accountID, archived: archived, budget: budgetValue, emoji: emoji.isEmpty ? nil : emoji, symbol: symbol.isEmpty ? nil : symbol)
                    try data.updateBook(value, expected: original.books.first { $0.id == id }, baseCurrency: original.baseCurrency)
                case .category:
                    let old = original.categories.first { $0.id == id }
                    // Preserve a built-in name's localization while its display label is unchanged.
                    let stored = old.map { $0.label == title ? $0.name : title } ?? title
                    let value = MoneyCategory(id: id ?? UUID(), name: stored, symbol: chosenSymbol, archived: archived, income: income, color: color, emoji: emoji.isEmpty ? nil : emoji, parentID: parentID)
                    try data.updateCategory(value, expected: old)
                }
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Entry sheet

struct EntryRequest: Identifiable {
    var entry: MoneyEntry
    var expected: MoneyEntry?
    var id: UUID { entry.id }
}

struct FinanceDraft {
    var ledger: FinanceData
    var entry: MoneyEntry
    var expected: MoneyEntry?
    var amount: String, actual: String, received: String, fee: String, converted: String, convertedFee: String
    var balance: Decimal
    var expression: String? = nil
}

/// Native amount editing, with an optional calculator and contextual advanced fields.
struct FinanceEntryEditor: View {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compact: Bool { sizeClass == .compact }
    #else
    private var compact: Bool { false }
    #endif
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private enum Field: Hashable { case amount, title, actual, received, fee, converted, convertedFee, notes, tags }
    @AppStorage("appLanguage") private var language = "system"
    @AppStorage("hideMoney") private var hidden = false
    let expected: MoneyEntry?
    @Environment(EditorDrafts.self) private var drafts
    @State private var generation = Store.recovery.generation
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var tasks: [TaskItem]
    @Query private var records: [FinanceLedger]
    @State private var draft: MoneyEntry
    @State private var ledger = FinanceData.initial
    @State private var accountBalances: [UUID: Decimal] = [:]
    @State private var expression: String
    @State private var amount: String
    @State private var actual: String
    @State private var received: String
    @State private var fee: String
    @State private var converted: String
    @State private var convertedFee: String
    @State private var error: String?
    @State private var notice: String?
    @State private var rates: [MoneyRate] = []
    @AppStorage("moneyAutoRates") private var automaticRates = true
    @State private var filledValues: [String: String] = [:]
    @State private var scaledValues: [String: String] = [:]
    @State private var gettingRates = false
    @State private var entity: EntityRequest?
    @State private var showCalculator = false
    @State private var showMore = false
    @State private var showDate = false
    @State private var initialBalance: Decimal = 0
    @State private var loaded = false
    @State private var confirmDiscard = false
    @State private var initialFingerprint = ""
    @State private var restoringDraft = false
    @FocusState private var focus: Field?
    init(entry: MoneyEntry, expected: MoneyEntry?) {
        self.expected = expected; _draft = State(initialValue: entry)
        let text = entry.amount == 0 ? "" : Money.text(entry.amount)
        _amount = State(initialValue: text)
        _expression = State(initialValue: text.replacingOccurrences(of: "-", with: "−"))
        _actual = State(initialValue: entry.accountAmount == 0 ? "" : Money.text(entry.accountAmount))
        _received = State(initialValue: entry.destinationAmount == 0 ? "" : Money.text(entry.destinationAmount))
        _fee = State(initialValue: entry.fee == 0 ? "" : Money.text(entry.fee))
        _converted = State(initialValue: entry.baseAmount.map(Money.text) ?? "")
        _convertedFee = State(initialValue: entry.baseFee.map(Money.text) ?? "")
        _showMore = State(initialValue: !entry.notes.isEmpty || !entry.tags.isEmpty || entry.taskID != nil)
    }
    private var account: MoneyAccount? { ledger.accounts.first { $0.id == draft.accountID } }
    private var destination: MoneyAccount? { ledger.accounts.first { $0.id == draft.destinationID } }
    private var fingerprint: String { String(describing: draft) + [expression, amount, actual, received, fee, converted, convertedFee].joined(separator: "|") }
    private var dirty: Bool { loaded && fingerprint != initialFingerprint }
    private var rateQuery: String { "\(loaded)-\(automaticRates)-\(draft.currency)-\(draft.accountID?.uuidString ?? "")-\(draft.destinationID?.uuidString ?? "")-\(Dates.calendar.startOfDay(for: draft.date).timeIntervalSince1970)" }
    private var foreign: Bool { draft.currency != ledger.baseCurrency }
    private var desiredAmountFocus: Field? {
        #if os(iOS)
        return showCalculator ? nil : .amount
        #else
        return .amount
        #endif
    }
    private var simpleKind: Bool { draft.kind == .expense || draft.kind == .income || draft.kind == .transfer }
    private var signedAmount: Bool { draft.kind == .adjustment }
    private var activeAccounts: [MoneyAccount] { ledger.accounts.filter { ledger.allowsAccount($0.id, for: draft, replacing: expected) } }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if compact { Text(expected == nil ? L("新增账单", "New entry") : L("编辑已有账单", "Edit existing entry")).font(.caption).foregroundStyle(.secondary) }
            if !compact {
                amountRow.padding(.horizontal, 18).padding(.vertical, 12)
                chips.padding(.horizontal, 18).padding(.bottom, 8)
                Divider()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if compact { amountRow; chips; Divider() }
                    if showMore { moreFields }
                    switch draft.kind {
                    case .expense, .income: categoryGrid
                    case .transfer: transferFields
                    case .refund: refundInfo
                    case .adjustment: adjustmentInfo
                    }
                    if needsRate { rateFields }
                    if draft.deletedAt != nil { Text(L("此账单已删除，请先在最近删除中恢复。", "Restore this entry from Recently deleted before editing.")).foregroundStyle(.secondary) }
                }.padding(.horizontal, 18).padding(.vertical, 12)
            }.scrollDismissesKeyboard(.interactively)
            Divider()
            bottomPanel
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 540, minHeight: showCalculator ? 730 : 540, idealHeight: showCalculator ? 750 : 560)
        #endif
        .background(Color.appBackground)
        #if os(macOS)
        .defaultFocus($focus, .amount)
        #endif
        .interactiveDismissDisabled(dirty)
        .confirmationDialog(L("放弃未保存的修改？", "Discard unsaved changes?"), isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button(L("放弃修改", "Discard changes"), role: .destructive) { dismiss() }
            Button(L("继续编辑", "Keep editing"), role: .cancel) {}
        }
        .task {
            if !loaded, let kept = drafts.finance, kept.entry.id == draft.id {
                ledger = kept.ledger; accountBalances = kept.ledger.accountBalances(); restoringDraft = true
            }
            reload()
            if !loaded {
                if let kept = drafts.finance, kept.entry.id == draft.id {
                    restoringDraft = true
                    draft = kept.entry; amount = kept.amount; actual = kept.actual; received = kept.received
                    fee = kept.fee; converted = kept.converted; convertedFee = kept.convertedFee; initialBalance = kept.balance
                    expression = kept.expression ?? kept.amount.replacingOccurrences(of: "-", with: "−")
                } else {
                    initialBalance = draft.accountID.map { ledger.balance($0, at: draft.date) } ?? 0
                    if draft.kind == .adjustment && expected == nil { amount = Money.text(initialBalance); expression = amount.replacingOccurrences(of: "-", with: "−") }
                }
                initialFingerprint = restoringDraft ? "restored-unsaved" : fingerprint; loaded = true
                keepDraft()
                focus = desiredAmountFocus
            }
        }
        .onChange(of: records.first?.payload) { _, _ in reload() }
        .onChange(of: fingerprint) { _, _ in if loaded { keepDraft() } }
        .onDisappear { if generation == Store.recovery.generation && Store.recovery.failure == nil { drafts.finance = nil } }
        .task(id: rateQuery) {
            if loaded && expected == nil && needsRate && automaticRates { await fetchAndFillRates() }
        }
        #if os(iOS)
        .onChange(of: focus) { _, focusedField in
            // The system keyboard and the calculator must not consume the sheet together.
            if focusedField != nil && showCalculator { showCalculator = false }
        }
        #endif
        .onChange(of: expression) { _, value in
            error = nil; if !value.isEmpty { notice = nil }
            let next = Money.evaluate(value, currency: draft.currency, signed: signedAmount).map(Money.text) ?? ""
            if next != amount { amount = next }
        }
        .onChange(of: amount) { _, _ in
            clearEstimates()
            rescaleRecorded()
            if !rates.isEmpty { applyRates(rates) }
        }
        .onChange(of: draft.bookID) { _, id in
            if expected == nil && draft.kind != .refund, ledger.books.first(where: { $0.id == id })?.defaultAccountID != nil { draft.accountID = ledger.defaultAccount(for: id) }
        }
        .onChange(of: draft.accountID) { old, _ in
            // Reassigning a posting does not change its original currency or historical reporting amount.
            if ledger.accounts.first(where: { $0.id == old })?.currency != account?.currency {
                actual = ""; filledValues["actual"] = nil; scaledValues["actual"] = nil
            }
            // A blank new entry follows its account. Typed amounts and historical entries keep their currency.
            if let account, draft.kind == .transfer || (expected == nil && expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (draft.kind == .expense || draft.kind == .income)) {
                draft.currency = account.currency
            }
        }
        .onChange(of: draft.kind) { _, kind in
            if kind == .transfer, let account { draft.currency = account.currency }
            if kind != .transfer { draft.destinationID = nil; received = ""; fee = ""; convertedFee = "" }
            if kind == .expense || kind == .income, ledger.category(draft.categoryID)?.isIncome != (kind == .income) {
                draft.categoryID = ledger.defaultCategory(income: kind == .income)
            }
            focus = desiredAmountFocus
        }
        .onChange(of: draft.destinationID) { _, _ in received = "" }
        .onChange(of: draft.currency) { _, _ in
            actual = ""; received = ""; converted = ""; convertedFee = ""; rates = []; filledValues = [:]; draft.rateNote = ""
            amount = Money.evaluate(expression, currency: draft.currency, signed: signedAmount).map(Money.text) ?? ""
        }
        .onChange(of: draft.date) { old, new in
            if draft.kind == .adjustment && expected == nil, let id = draft.accountID {
                let untouched = Money.evaluate(expression, currency: draft.currency, signed: true) == initialBalance
                initialBalance = ledger.balance(id, at: new)
                if untouched { expression = Money.text(initialBalance); amount = expression }
            }
            if !Dates.calendar.isDate(old, inSameDayAs: new) { clearEstimates(); rates = []; draft.rateNote = "" }
        }
        .onChange(of: fee) { _, _ in
            if convertedFee == filledValues["fee"] { convertedFee = ""; filledValues["fee"] = nil }
            if let original = expected, original.currency == draft.currency, foreign,
               let value = try? Money.parse(fee, currency: draft.currency),
               let next = Money.rescaledText(convertedFee, recorded: original.baseFee, previous: scaledValues["fee"], from: original.fee, to: value, currency: ledger.baseCurrency) {
                convertedFee = next; scaledValues["fee"] = next
            }
            if !rates.isEmpty { applyRates(rates) }
        }
        .sheet(item: $entity, onDismiss: reload) { item in FinanceEntityEditor(kind: item.kind, id: item.existingID, income: item.income, parentID: item.parentID, data: ledger) }
        .modifier(SaveRecoveryGuard())
        .modifier(CloudSyncEditingGuard())
    }

    // MARK: Layout

    private var topBar: some View {
        HStack(spacing: 12) {
            if simpleKind {
                Picker(L("类型", "Type"), selection: $draft.kind) {
                    ForEach([MoneyKind.expense, .income, .transfer]) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: compact ? .infinity : 230).disabled(expected != nil)
            } else { Text(draft.kind.label).font(.headline) }
            Spacer()
            if !compact { Text(expected == nil ? L("新增账单", "New entry") : L("编辑已有账单", "Edit existing entry")).font(.subheadline).foregroundStyle(.secondary) }
            Button { if dirty { confirmDiscard = true } else { dismiss() } } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: compact ? 44 : 26, height: compact ? 44 : 26).background(Circle().fill(Color.primary.opacity(0.07)))
            }.buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel(L("关闭", "Close")).help(L("关闭（Esc）", "Close (Esc)"))
        }.padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 4)
    }
    private var categoryGrid: some View {
        let income = draft.kind == .income
        let selectedRoot = ledger.rootCategoryID(draft.categoryID)
        let roots = ledger.categories.filter { $0.parentID == nil && (($0.isIncome == income && !$0.archived) || $0.id == selectedRoot) }
        let children = ledger.categories.filter { selectedRoot != nil && $0.parentID == selectedRoot && (($0.isIncome == income && !$0.archived) || $0.id == draft.categoryID) }
        return VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: compact ? (dynamicTypeSize.isAccessibilitySize ? 2 : 4) : 6), spacing: 8) {
                ForEach(roots) { category in categoryButton(category, selected: category.id == selectedRoot) }
                addCategoryButton(income: income, parentID: nil)
            }
            if let parent = ledger.category(selectedRoot), !children.isEmpty {
                Divider()
                HStack {
                    Text(parent.label + L(" · 子分类", " · subcategories")).font(.subheadline.weight(.semibold))
                    Spacer()
                    Button(L("不细分", "No subcategory")) { draft.categoryID = parent.id }.font(.caption).frame(minHeight: 44)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: compact ? (dynamicTypeSize.isAccessibilitySize ? 2 : 4) : 6), spacing: 8) {
                    ForEach(children) { category in categoryButton(category, selected: category.id == draft.categoryID) }
                    if !parent.archived { addCategoryButton(income: income, parentID: parent.id) }
                }
            } else if let parent = ledger.category(selectedRoot), !parent.archived {
                Button { entity = EntityRequest(kind: .category, income: income, parentID: parent.id) } label: {
                    Label(L("为“\(parent.label)”添加子分类", "Add a subcategory to \(parent.label)"), systemImage: "plus")
                }.font(.callout).frame(minHeight: 44)
            }
        }
    }
    private func categoryButton(_ category: MoneyCategory, selected: Bool) -> some View {
        let tint = MoneyColor.color(category.resolvedColor)
        return Button {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.15)) { draft.categoryID = category.id }
            focus = desiredAmountFocus
        } label: {
            VStack(spacing: 5) {
                MoneyIcon(symbol: category.symbol, emoji: category.emoji, tint: selected ? .white : tint, size: 40)
                    .background(Circle().fill(selected ? tint : .clear))
                Text(category.label).font(.caption).lineLimit(2).foregroundStyle(selected ? .primary : .secondary)
            }.frame(maxWidth: .infinity, minHeight: 60).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10).fill(selected ? tint.opacity(0.1) : .clear)).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(ledger.categoryPath(category.id)).accessibilityAddTraits(selected ? [.isSelected] : [])
    }
    private func addCategoryButton(income: Bool, parentID: UUID?) -> some View {
        Button { entity = EntityRequest(kind: .category, income: income, parentID: parentID) } label: {
            VStack(spacing: 5) {
                Image(systemName: "plus").font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: 40, height: 40).overlay(Circle().strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3])))
                Text(L("新增", "Add")).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, minHeight: 60).padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(parentID == nil ? L("新增大类", "New main category") : L("新增子分类", "New subcategory"))
    }
    private var transferFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            (compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))) {
                accountPicker(L("从", "From"), selection: $draft.accountID, excluding: nil)
                Button {
                    let from = draft.accountID; draft.accountID = draft.destinationID; draft.destinationID = from
                } label: { Label(L("对调账户", "Swap accounts"), systemImage: "arrow.left.arrow.right").frame(minHeight: compact ? 44 : nil) }
                    .buttonStyle(.borderless).help(L("对调转出和转入账户", "Swap the two accounts")).accessibilityLabel(L("对调转出和转入账户", "Swap the two accounts"))
                    .disabled(draft.accountID == nil && draft.destinationID == nil)
                accountPicker(L("转到", "To"), selection: $draft.destinationID, excluding: draft.accountID)
            }
            if let from = account, let to = destination {
                Text(L("钱从“\(from.name)”转出，进入“\(to.name)”", "Money leaves “\(from.name)” and arrives in “\(to.name)”"))
                    .font(.callout.weight(.medium))
            }
            if let destination, destination.currency != draft.currency {
                amountField(L("实际到账", "Amount received"), currency: destination.currency, text: $received, field: .received)
            }
            amountField(L("手续费（可不填）", "Fee (optional)"), currency: draft.currency, text: $fee, field: .fee)
            transferBalancePreview
            Text(L("转账只在两个账户之间挪钱，不算收入或支出；手续费计入支出。", "Transfers move money between accounts and are not income or spending; the fee counts as spending.")).font(.caption).foregroundStyle(.secondary)
        }.padding(12).background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }
    @ViewBuilder private var transferBalancePreview: some View {
        if expected != nil {
            Text(L("正在修改原转账，保存后会替换旧记录。新增转账请关闭后点“记一笔”。", "This replaces the original transfer. To add a transfer, close this editor and choose New entry."))
                .font(.caption).foregroundStyle(.secondary)
        }
        if let entry = try? preparedEntry(), entry.accountID != entry.destinationID {
            let ids = [entry.accountID, entry.destinationID, expected?.accountID, expected?.destinationID].compactMap { $0 }
            Divider()
            Text(L("保存后的账户余额", "Account balances after saving")).font(.caption).foregroundStyle(.secondary)
            ForEach(ledger.accounts.filter { ids.contains($0.id) }) { account in
                HStack {
                    Text(account.name).lineLimit(1)
                    Spacer()
                    let after = ledger.balanceAfterSaving(entry, for: account.id, accountBalances: accountBalances)
                    Text(Money.display(accountBalances[account.id, default: 0], account.currency, hidden: hidden)).foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Text(Money.display(after, account.currency, hidden: hidden)).foregroundStyle(after < 0 ? Color.red : .primary)
                }.font(.caption).monospacedDigit()
            }
        }
    }
    private func accountPicker(_ label: String, selection: Binding<UUID?>, excluding: UUID?) -> some View {
        Picker(label, selection: selection) {
            Text(L("选择账户", "Choose account")).tag(nil as UUID?)
            ForEach(activeAccounts.filter { $0.id != excluding }) { a in Text(a.name + " · " + Money.display(accountBalances[a.id, default: 0], a.currency, hidden: hidden)).tag(Optional(a.id)) }
        }.pickerStyle(.menu).frame(maxWidth: .infinity)
    }
    private var refundInfo: some View {
        let original = ledger.entries.first { $0.id == draft.refundOf }
        let category = ledger.category(draft.categoryID)
        return HStack(spacing: 12) {
            MoneyIcon(symbol: category?.symbol ?? "arrow.uturn.backward", emoji: category?.emoji, tint: ledger.tint(category), size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(L("退款会从“\(category?.label ?? L("未分类", "Uncategorized"))”的支出中扣除，不算新收入。", "The refund reduces \(category?.label ?? "uncategorized") spending and is not new income."))
                if let original { Text(L("原消费：", "Original: ") + original.title + " · " + Money.display(original.amount, original.currency, hidden: hidden)).font(.caption).foregroundStyle(.secondary) }
                if let original {
                    Text(L("还可退款：", "Available to refund: ") + Money.display(ledger.remainingRefund(for: original.id, excluding: expected?.id), original.currency, hidden: hidden))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }
    private var adjustmentInfo: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text((account?.name ?? "") + L(" 核对时刻账面余额 ", " balance at the selected time ") + Money.display(initialBalance, draft.currency, hidden: hidden)).font(.headline)
            Text(expected == nil ? L("在上方输入该时刻的实际余额。差额记为调整，不计入收支；更晚的流水不会参与本次核对。", "Enter the actual balance at the selected time above. The difference is an adjustment, not income or spending; later entries are excluded.")
                 : L("这是一次余额调整，金额为调整的差额。", "This is a balance adjustment; the amount is the difference.")).font(.caption).foregroundStyle(.secondary)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }
    private var needsRate: Bool { draft.kind != .adjustment && (foreign || account.map { $0.currency != draft.currency } == true || destination.map { $0.currency != draft.currency } == true) }
    private var rateFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L("外币换算", "Currency conversion"), systemImage: "arrow.triangle.2.circlepath").font(.subheadline.weight(.semibold))
            if let account, account.currency != draft.currency, draft.kind != .transfer {
                amountField(account.name + ((draft.kind == .expense) ? L(" 实际扣款", " charged") : L(" 实际入账", " received")), currency: account.currency, text: $actual, field: .actual)
            }
            if foreign && draft.kind != .transfer && draft.kind != .adjustment && account?.currency != ledger.baseCurrency {
                amountField(L("计入统计", "Counts in totals as"), currency: ledger.baseCurrency, text: $converted, field: .converted)
            }
            if draft.kind == .transfer && foreign && !fee.isEmpty { amountField(L("手续费折合", "Fee in base currency"), currency: ledger.baseCurrency, text: $convertedFee, field: .convertedFee) }
            (compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 8))) {
                Text(draft.rateNote.isEmpty ? L("还没有参考汇率", "No reference rate yet") : draft.rateNote).font(.caption).foregroundStyle(.secondary)
                if !compact { Spacer() }
                Button(gettingRates ? L("获取中…", "Fetching…") : L("按参考汇率填入", "Fill with reference rate")) { fillRates() }
                    .controlSize(.small).frame(minHeight: compact ? 44 : nil).disabled(gettingRates || amount.isEmpty)
            }
            Toggle(L("自动获取参考汇率", "Fetch reference rates automatically"), isOn: $automaticRates).font(.caption)
                #if os(macOS)
                .toggleStyle(.checkbox)
                #endif
            Text(L("以银行实际扣款为准：改成实际金额后不会被覆盖；历史账单不随汇率变化。", "Use what your bank actually charged; amounts you enter are never overwritten, and history never changes with rates.")).font(.caption).foregroundStyle(.secondary)
        }.padding(12).background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.08)))
    }
    private func amountField(_ label: String, currency: String, text: Binding<String>, field: Field) -> some View {
        (compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 8))) {
            Text(label).font(.callout)
            HStack(spacing: 8) {
                if !compact { Spacer() }
                Text(currency).font(.caption).foregroundStyle(.secondary)
                TextField("0", text: text).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).monospacedDigit()
                    .frame(maxWidth: compact ? .infinity : 120, minHeight: compact ? 44 : nil).focused($focus, equals: field)
                    .accessibilityLabel(label + " · " + currency)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
            }
        }
    }
    private var moreFields: some View {
        let recent = recentTags
        return VStack(alignment: .leading, spacing: 10) {
            fieldTitle(L("详细说明", "Details"), L("写不下的细节，比如买了什么、和谁一起、发票号。", "Anything longer: what you bought, who with, an invoice number."))
            TextField(L("可不填", "Optional"), text: $draft.notes, axis: .vertical).focused($focus, equals: .notes).lineLimit(2...5).textFieldStyle(.roundedBorder)
            fieldTitle(L("标签", "Tags"), L("给账单打记号，方便以后搜索，比如“报销”“出差”。多个用逗号分开。", "Marks for finding entries later, such as “reimburse” or “work trip”. Separate with commas."))
            TextField(L("可不填", "Optional"), text: $draft.tags).focused($focus, equals: .tags).textFieldStyle(.roundedBorder)
            if !recent.isEmpty {
                ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    Text(L("常用：", "Recent: ")).font(.caption).foregroundStyle(.secondary)
                    ForEach(recent, id: \.self) { tag in
                        Button(tag) { addTag(tag) }.buttonStyle(.plain).font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Color.primary.opacity(0.07)))
                            .frame(minHeight: compact ? 44 : nil)
                    }
                }
                }.scrollIndicators(.hidden)
            }
            fieldTitle(L("关联任务", "Linked task"), L("这笔钱对应待办里的哪件事，可在任务里看到相关花费。", "Which task this money belongs to; the task shows its entries."))
            Picker(L("关联任务", "Linked task"), selection: $draft.taskID) {
                Text(L("不关联", "None")).tag(nil as UUID?)
                ForEach(tasks.filter { $0.deletedAt == nil || $0.id == draft.taskID }.sorted { $0.createdAt > $1.createdAt }) { Text($0.title).tag(Optional($0.id)) }
                if let id = draft.taskID, !tasks.contains(where: { $0.id == id }) { Text(L("原任务已删除", "Original task removed")).tag(Optional(id)) }
            }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        }.padding(12).background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }

    private func fieldTitle(_ title: String, _ hint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout.weight(.medium))
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
    }
    private static func splitTags(_ text: String) -> [String] {
        text.split(whereSeparator: { ",，、".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    /// The tags used most, not already on this entry.
    private var recentTags: [String] {
        let current = Set(Self.splitTags(draft.tags))
        let counts = ledger.entries.filter { $0.deletedAt == nil }.flatMap { Self.splitTags($0.tags) }.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        return counts.filter { !current.contains($0.key) }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(6).map(\.key)
    }
    private func addTag(_ tag: String) {
        draft.tags = (Self.splitTags(draft.tags) + [tag]).joined(separator: L("，", ", "))
    }
    private var bottomPanel: some View {
        VStack(spacing: 10) {
            statusLine
            if showCalculator { keypad }
            HStack(spacing: 12) {
                Button {
                    showCalculator.toggle()
                    focus = desiredAmountFocus
                } label: {
                    Label(L("计算器", "Calculator"), systemImage: "plus.forwardslash.minus")
                }.buttonStyle(.borderless).foregroundStyle(showCalculator ? Color.accentColor : .secondary)
                    .labelStyle(.iconOnly).frame(minWidth: compact ? 44 : nil, minHeight: compact ? 44 : nil)
                    .accessibilityAddTraits(showCalculator ? [.isSelected] : [])
                Spacer()
                #if os(iOS)
                Button {
                    focus = nil
                } label: {
                    Label(L("收起键盘", "Dismiss keyboard"), systemImage: "keyboard.chevron.compact.down").labelStyle(.iconOnly)
                }.buttonStyle(.borderless).frame(minWidth: 44, minHeight: 44)
                #endif
                if expected == nil && simpleKind && !compact {
                    Button(L("保存并继续", "Save + new")) { save(again: true) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .help(L("保存并继续下一笔（⌘↩）", "Save and start another (⌘↩)"))
                        .disabled(!loaded || gettingRates || draft.deletedAt != nil)
                }
                Button(compact ? L("保存", "Save") : expected == nil ? L("保存新账单", "Save new entry") : L("保存修改", "Save changes")) { save() }.buttonStyle(.borderedProminent)
                    .controlSize(compact ? .large : .regular)
                    .frame(maxWidth: compact ? .infinity : nil, minHeight: compact ? 44 : nil)
                    .keyboardShortcut(.defaultAction).disabled(!loaded || gettingRates || draft.deletedAt != nil)
            }
        }.padding(.horizontal, 18).padding(.vertical, 14)
    }
    private var amountRow: some View {
        let value = Money.evaluate(expression, currency: draft.currency, signed: signedAmount)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(L("金额", "Amount")).foregroundStyle(.secondary)
                Menu {
                    CurrencyChoices { draft.currency = $0 }
                } label: { Text(Money.symbol(draft.currency)) }
                    .menuStyle(.borderlessButton).fixedSize()
                    .disabled(draft.kind == .refund || draft.kind == .adjustment || draft.kind == .transfer)
                    .help(L("币种", "Currency"))
                TextField("0.00", text: $expression)
                    .font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                    .textFieldStyle(.plain).focused($focus, equals: .amount)
                    .accessibilityLabel(L("金额，可输入加减算式", "Amount, addition and subtraction supported"))
                    #if os(iOS)
                    .keyboardType(signedAmount ? .numbersAndPunctuation : .decimalPad)
                    #endif
                if expression.contains(where: { $0 == "+" || $0 == "−" || $0 == "-" }) && expression.count > 1, let value {
                    Text("= " + Money.format(value, draft.currency)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L("备注", "Note")).font(.caption).foregroundStyle(.secondary)
                TextField(L("可不填", "Optional"), text: $draft.title)
                    .textFieldStyle(.plain).focused($focus, equals: .title).frame(minHeight: compact ? 44 : nil)
                    .accessibilityLabel(L("备注", "Note"))
            }
        }
    }
    private var chips: some View {
        // Long account or book names move the last two controls to a second row instead of squeezing them.
        Group {
        if compact {
            ScrollView(.horizontal) {
                HStack(spacing: 8) { dateChip; accountChip; bookChip; moreChip }
            }.scrollIndicators(.hidden)
        } else {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { dateChip; accountChip; bookChip; moreChip; Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { dateChip; accountChip; Spacer(minLength: 0) }
                HStack(spacing: 8) { bookChip; moreChip; Spacer(minLength: 0) }
            }
        }
        }
        }.labelStyle(.titleAndIcon)
    }
    private var dateChip: some View {
        Button { showDate = true } label: { Label(dateText, systemImage: "calendar") }
            .buttonStyle(.plain).fixedSize().modifier(MoneyChip())
            .popover(isPresented: $showDate, arrowEdge: .bottom) { datePopover }
    }
    @ViewBuilder private var accountChip: some View {
        if draft.kind == .expense || draft.kind == .income || draft.kind == .refund {
            Menu {
                Picker(L("账户", "Account"), selection: $draft.accountID) {
                    Text(L("不计入账户（只记收支）", "No account (totals only)")).tag(nil as UUID?)
                    ForEach(activeAccounts) { a in Text(a.name + " · " + Money.display(accountBalances[a.id, default: 0], a.currency, hidden: hidden)).tag(Optional(a.id)) }
                }.pickerStyle(.inline).labelsHidden()
                Divider()
                Button(L("新增账户…", "New account…")) { entity = EntityRequest(kind: .account) }
            } label: { MoneyMenuLabel(title: L("账户：", "Account: ") + (account?.name ?? L("不计入账户", "No account")), symbol: account?.iconSymbol ?? "wallet.pass", emoji: account?.emoji) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().modifier(MoneyChip())
                .help(L("从哪个账户扣款或入账", "Which account this uses"))
        }
    }
    private var bookChip: some View {
        Menu {
            Picker(L("账本", "Book"), selection: $draft.bookID) {
                ForEach(ledger.books.filter { !$0.archived || $0.id == draft.bookID }) { Text($0.name).tag(Optional($0.id)) }
            }.pickerStyle(.inline).labelsHidden()
            Divider()
            Button(L("新建账本…", "New book…")) { entity = EntityRequest(kind: .book) }
        } label: { MoneyMenuLabel(title: L("账本：", "Book: ") + (ledger.book(draft.bookID)?.name ?? L("选择", "choose")), symbol: ledger.book(draft.bookID)?.iconSymbol ?? "book.closed", emoji: ledger.book(draft.bookID)?.emoji) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().modifier(MoneyChip())
            .disabled(draft.kind == .refund)
    }
    private var moreChip: some View {
        Button { withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { showMore.toggle() } } label: {
            Label(showMore ? L("收起", "Less") : L("更多", "More"), systemImage: showMore ? "chevron.up" : "ellipsis")
        }.buttonStyle(.plain).fixedSize().modifier(MoneyChip()).help(L("补充说明、标签、关联任务", "Notes, tags and linked task"))
    }
    private var datePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(L("今天", "Today")) { draft.date = MoneyEntry.timestamp(); showDate = false }
                Button(L("昨天", "Yesterday")) { draft.date = MoneyEntry.timestamp(Dates.calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date()); showDate = false }
            }
            DatePicker("", selection: $draft.date, displayedComponents: .date).datePickerStyle(.graphical).labelsHidden()
            DatePicker(L("时间", "Time"), selection: $draft.date, displayedComponents: .hourAndMinute)
        }.padding(14).frame(width: 260)
    }
    private var dateText: String {
        let time = Dates.label(draft.date, pattern: "HH:mm")
        if Dates.calendar.isDateInToday(draft.date) { return L("今天 ", "Today ") + time }
        if Dates.calendar.isDateInYesterday(draft.date) { return L("昨天 ", "Yesterday ") + time }
        return Dates.label(draft.date, pattern: "M月d日 HH:mm")
    }
    @ViewBuilder private var statusLine: some View {
        if let error {
            Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        } else if let notice {
            Label(notice, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green).frame(maxWidth: .infinity, alignment: .leading)
        } else if draft.kind == .adjustment && expected == nil {
            Text(L("输入核对后的实际余额", "Enter the checked balance")).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var keypad: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow { key("7"); key("8"); key("9"); iconKey("delete.left", "⌫") }
            GridRow { key("4"); key("5"); key("6"); key("+") }
            GridRow { key("1"); key("2"); key("3"); key("−") }
            GridRow {
                Button(L("清空", "Clear")) { expression = ""; focus = desiredAmountFocus }.buttonStyle(MoneyKeyStyle())
                key("0"); key(".")
                Button("=") {
                    if let value = Money.evaluate(expression, currency: draft.currency, signed: signedAmount) { expression = Money.text(value) }
                    focus = desiredAmountFocus
                }.buttonStyle(MoneyKeyStyle())
            }
        }
    }
    private func key(_ value: String) -> some View {
        Button(value) { input(value) }.buttonStyle(MoneyKeyStyle())
    }
    private func iconKey(_ symbol: String, _ value: String) -> some View {
        Button { input(value) } label: { Image(systemName: symbol) }.buttonStyle(MoneyKeyStyle()).accessibilityLabel(L("删除", "Delete"))
    }

    // MARK: Keypad

    private func input(_ key: String) {
        error = nil; notice = nil
        if focus != .amount { focus = desiredAmountFocus }
        var text = expression
        let scale = Money.scale(draft.currency)
        let last = String(text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "+" || $0 == "−" || $0 == "-" }).last ?? "")
        switch key {
        case "⌫":
            if !text.isEmpty { text.removeLast() }
        case "+", "−":
            if text.isEmpty || text == "−" { text = key == "−" && signedAmount ? "−" : "" }
            else if text.last == "+" || text.last == "−" || text.last == "-" { text.removeLast(); text.append(key) }
            else { text.append(key) }
        case ".":
            guard scale > 0, !last.contains(".") else { return }
            text += last.isEmpty ? "0." : "."
        default:
            if let dot = last.firstIndex(of: "."), last.distance(from: dot, to: last.endIndex) - 1 >= scale { return }
            guard text.count < 24 else { return }
            if last == "0" { text.removeLast() }
            text += key
        }
        expression = text
    }

    // MARK: Data

    private func reload() {
        do {
            let current = try FinanceStore.read(context) ?? .initial
            // Keep displayed conversion fields in the denomination they were entered in.
            if loaded || restoringDraft { try current.requireEntryCurrencies(draft, from: ledger) }
            ledger = current
            accountBalances = current.accountBalances()
        } catch { self.error = error.localizedDescription }
    }
    private func fillRates() {
        Task { await fetchAndFillRates() }
    }
    private func fetchAndFillRates() async {
        gettingRates = true; error = nil
        let query = rateQuery
        let source = draft.currency, day = draft.date
        let quotes = [account?.currency, destination?.currency, ledger.baseCurrency].compactMap { $0 }
        do {
            defer { gettingRates = false }
            do {
                let result = try await ExchangeRates.fetch(base: source, quotes: quotes, date: day)
                guard !Task.isCancelled && rateQuery == query else { return }
                rates = result
                applyRates(result)
                draft.rateNote = L("欧洲央行 ", "ECB ") + (result.map(\.date).sorted().first ?? "") + L(" 参考汇率", " reference rate") + rateSummary(result)
            } catch {
                guard !Task.isCancelled && rateQuery == query else { return }
                let cached = ledger.cachedReferenceRates(from: source, quotes: quotes, onOrBefore: ExchangeRates.dayString(day), including: rates)
                rates = cached
                if !cached.isEmpty {
                    applyRates(cached)
                    draft.rateNote = L("离线参考汇率：", "Cached reference rates: ") + cached.map(\.date).sorted().joined(separator: ", ")
                }
                self.error = L("暂时无法联网获取汇率。可填写实际金额，或核对缓存换算值后保存。", "Rates are unavailable. Enter actual amounts or review cached values before saving.")
            }
        }
    }
    private func rateSummary(_ values: [MoneyRate]) -> String {
        guard let rate = values.first(where: { $0.quote == (account?.currency != draft.currency ? account?.currency : ledger.baseCurrency) }) ?? values.first else { return "" }
        let shown = NSDecimalNumber(decimal: rate.rate).rounding(accordingToBehavior: NSDecimalNumberHandler(roundingMode: .plain, scale: 4, raiseOnExactness: false, raiseOnOverflow: false, raiseOnUnderflow: false, raiseOnDivideByZero: false))
        return " · 1 \(rate.base) = \(shown.stringValue) \(rate.quote)"
    }
    /// Editing a recorded foreign entry keeps the rate it was recorded at: untouched converted amounts follow the new amount.
    private func rescaleRecorded() {
        guard let original = expected, original.amount != 0, draft.currency == original.currency,
              let value = try? Money.parse(amount, currency: draft.currency, signed: signedAmount) else { return }
        func follow(_ key: String, _ recorded: Decimal?, _ currency: String?, _ field: inout String) {
            guard let currency, let next = Money.rescaledText(field, recorded: recorded, previous: scaledValues[key], from: original.amount, to: value, currency: currency) else { return }
            field = next; scaledValues[key] = next
        }
        if original.currency != ledger.baseCurrency { follow("converted", original.baseAmount, ledger.baseCurrency, &converted) }
        if draft.accountID == original.accountID, let account, account.currency != draft.currency { follow("actual", original.accountAmount, account.currency, &actual) }
        if draft.destinationID == original.destinationID, let destination, destination.currency != draft.currency { follow("received", original.destinationAmount, destination.currency, &received) }
    }
    private func clearEstimates() {
        if actual == filledValues["actual"] { actual = "" }
        if received == filledValues["received"] { received = "" }
        if converted == filledValues["converted"] { converted = "" }
        if convertedFee == filledValues["fee"] { convertedFee = "" }
        filledValues = [:]
    }
    private func applyRates(_ values: [MoneyRate]) {
        guard let amount = try? Money.parse(amount, currency: draft.currency) else { return }
        func conversion(_ value: Decimal, _ to: String) -> String? {
            if draft.currency == to { return Money.text(value) }
            return values.first { !$0.isManual && $0.base == draft.currency && $0.quote == to }.map { Money.text(Money.round(value * $0.rate, currency: to)) }
        }
        func fill(_ key: String, _ field: inout String, _ replacement: String?) {
            guard let next = Money.refreshedEstimate(field, previous: filledValues[key], replacement: replacement) else { return }
            field = next; filledValues[key] = next
        }
        if let account { fill("actual", &actual, conversion(amount, account.currency)) }
        if let destination { fill("received", &received, conversion(amount, destination.currency)) }
        fill("converted", &converted, conversion(amount, ledger.baseCurrency))
        if let value = try? Money.parse(fee, currency: draft.currency) {
            fill("fee", &convertedFee, conversion(value, ledger.baseCurrency))
        }
    }
    private func keepDraft() {
        drafts.finance = FinanceDraft(ledger: ledger, entry: draft, expected: expected, amount: amount, actual: actual, received: received, fee: fee, converted: converted, convertedFee: convertedFee, balance: initialBalance, expression: expression)
    }
    private func preparedEntry() throws -> MoneyEntry {
        guard !amount.isEmpty, (try? Money.parse(amount, currency: draft.currency, signed: signedAmount)).map({ $0 != 0 || draft.kind == .adjustment }) == true else {
            throw TaskBackup.invalid(expression.isEmpty ? L("先输入金额", "Enter an amount first") : L("金额需要大于 0，\(draft.currency) 最多 \(Money.scale(draft.currency)) 位小数", "The amount must be above 0 with at most \(Money.scale(draft.currency)) decimals"))
        }
        var e = draft
        e.title = e.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if e.kind == .transfer { e.categoryID = nil }
        if e.title.isEmpty { e.title = ledger.categories.first { $0.id == e.categoryID }?.label ?? e.kind.label }
        e.amount = try Money.parse(amount, currency: e.currency, signed: e.kind == .adjustment)
        if e.kind == .adjustment && expected == nil {
            let live = try FinanceStore.read(context) ?? .initial
            guard let id = e.accountID else { throw TaskBackup.invalid(L("请选择账户。", "Choose an account.")) }
            e.amount = try live.reconciliationChange(id, at: e.date, checked: e.amount, expected: initialBalance)
            guard e.amount != 0 else { throw TaskBackup.invalid(L("余额没有变化，不需要校准。", "The balance is unchanged; nothing to adjust.")) }
        }
        e.accountAmount = try account.map { account in account.currency == e.currency ? e.amount : try Money.parse(actual, currency: account.currency, signed: e.kind == .adjustment) } ?? 0
        e.destinationAmount = 0; e.fee = 0; e.baseFee = nil
        if e.kind == .transfer {
            guard e.accountID != nil else { throw TaskBackup.invalid(L("请选择转出账户。", "Choose the account to transfer from.")) }
            guard let destination else { throw TaskBackup.invalid(L("请选择转入账户。", "Choose a receiving account.")) }
            e.destinationAmount = destination.currency == e.currency ? e.amount : try Money.parse(received, currency: destination.currency)
            e.fee = fee.isEmpty ? 0 : try Money.parse(fee, currency: e.currency)
            if e.fee > 0 { e.baseFee = e.currency == ledger.baseCurrency ? e.fee : (convertedFee.isEmpty ? nil : try Money.parse(convertedFee, currency: ledger.baseCurrency)) }
        } else { e.destinationID = nil }
        if e.kind == .transfer || e.kind == .adjustment { e.baseAmount = nil }
        else if e.currency == ledger.baseCurrency { e.baseAmount = e.amount }
        else if account?.currency == ledger.baseCurrency { e.baseAmount = e.accountAmount }
        else { e.baseAmount = converted.isEmpty ? nil : try Money.parse(converted, currency: ledger.baseCurrency) }
        return e
    }
    private func save(again: Bool = false) {
        do {
            keepDraft()
            let e = try preparedEntry()
            try FinanceStore.update(context) { value in
                try value.requireEntryCurrencies(e, from: ledger)
                try value.updateEntry(e, expected: expected, baseCurrency: ledger.baseCurrency, referenceRates: rates)
            }
            if let id = e.bookID { UserDefaults.standard.set(id.uuidString, forKey: "lastMoneyBook") }
            if e.kind == .expense || e.kind == .income { UserDefaults.standard.set(e.accountID?.uuidString ?? "none", forKey: "lastMoneyAccount") }
            if let id = e.categoryID, e.kind == .expense || e.kind == .income { UserDefaults.standard.set(id.uuidString, forKey: "lastMoneyCategory." + (e.kind == .income ? "income" : "expense")) }
            if again { startAnother(after: e) } else { dismiss() }
        } catch { self.error = error.localizedDescription; notice = nil }
    }
    /// Keeps kind, category, account, book, currency and day, so a run of receipts is only amounts.
    private func startAnother(after saved: MoneyEntry) {
        var next = MoneyEntry()
        next.kind = saved.kind; next.categoryID = saved.categoryID; next.accountID = saved.accountID; next.destinationID = saved.destinationID
        next.bookID = saved.bookID; next.currency = saved.currency; next.date = saved.date
        draft = next
        expression = ""; amount = ""; actual = ""; received = ""; fee = ""; converted = ""; convertedFee = ""; filledValues = [:]
        reload()
        initialFingerprint = fingerprint
        error = nil
        notice = L("已记下 ", "Saved ") + saved.title + " " + Money.display(saved.amount, saved.currency, hidden: hidden) + L("，继续下一笔", ". Next one")
        focus = desiredAmountFocus
    }
}

// Association is a UUID on the entry, so deleting a task never cascades into financial records.
struct TaskMoneySection: View {
    @AppStorage("appLanguage") private var language = "system"
    let task: TaskItem
    @Environment(\.modelContext) private var context
    @Query private var records: [FinanceLedger]
    @State private var editor: EntryRequest?
    @AppStorage("hideMoney") private var hidden = false
    @State private var error: String?
    var body: some View {
        // Nothing to link until bookkeeping has been used; the Money section is where it starts.
        if !records.isEmpty {
            switch Result(catching: { try FinanceStore.read(context) }) {
            case .success(let ledger):
                if let ledger { section(ledger) }
            case .failure(let failure):
                Label(L("无法读取关联账单：", "Unable to read linked entries: ") + failure.localizedDescription,
                      systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }
    private func section(_ ledger: FinanceData) -> some View {
        let linked = ledger.entries.filter { $0.taskID == task.id && $0.deletedAt == nil }
        return DisclosureGroup(L("关联账单", "Linked entries") + (linked.isEmpty ? "" : " · \(linked.count)")) {
            ForEach(linked) { entry in
                Button { editor = EntryRequest(entry: entry, expected: entry) } label: {
                    HStack { Text(entry.title); Spacer(); Text(Money.display(entry.amount, entry.currency, hidden: hidden)).monospacedDigit() }
                }.buttonStyle(.borderless).padding(.vertical, 4)
            }
            Button(L("为此任务记一笔", "Record an entry for this task")) {
                do {
                    let data = try FinanceStore.read(context) ?? .initial
                    var e = data.newEntry(preferredBook: nil); e.title = String(task.title.prefix(80)); e.taskID = task.id
                    editor = EntryRequest(entry: e, expected: nil)
                } catch { self.error = error.localizedDescription }
            }.buttonStyle(.borderless).padding(.vertical, 4)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .sheet(item: $editor) { request in FinanceEntryEditor(entry: request.entry, expected: request.expected) }
    }
}
