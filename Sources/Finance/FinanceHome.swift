import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Charts
#if os(iOS)
import UIKit
#endif

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
    let scope: String
    @Binding var text: String
    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $text, prompt: L("搜索账单、备注、标签", "Search entries, notes and tags"))
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

/// Finance state stays here; page extensions share it without adding another observation owner.
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
    var compact: Bool { sizeClass == .compact }
    #else
    var compact: Bool { false }
    #endif
    @Environment(EditorDrafts.self) private var drafts
    @State private var generation = Store.recovery.generation
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.dynamicTypeSize) var dynamicTypeSize
    @Binding var selection: String
    var openTask: (UUID) -> Void
    var settings: () -> Void
    @Environment(\.modelContext) private var context
    @Query private var records: [FinanceLedger]
    @AppStorage("hideMoney") var hidden = false
    @AppStorage("appLanguage") private var language = "system"
    @AppStorage("moneyBookScope") var scope = ""
    @AppStorage("moneyAutoRates") var automaticRates = true
    @State var data = FinanceData.initial
    @State private var loadedPayload: Data?
    @State private var loadingError: String?
    @State private var error: String?
    @State var anchor = Date()
    @State var period = MoneyPeriod.month
    @State var statsIncome = false
    @State var statsSelectedDate: Date?
    @State var dateRange = MoneyDateRange.month
    @State var showDateRange = false
    @State var fixedRange: DateInterval?
    @State var customStart = Date()
    @State var customEnd = Date()
    @State var search = ""
    @State var accountDetailID: UUID?
    @AppStorage("moneyRunningBalances") var showRunningBalances = false
    @State var accountFilter: UUID?
    @State var drilldown: MoneyDrilldown?
    @State var categoryFilter: UUID?
    @State var kindFilter: MoneyKind?
    @State var editor: EntryRequest?
    @State var entity: EntityRequest?
    @State private var lastDeleted: MoneyEntry?
    @State var confirmDelete: MoneyEntry?
    @State var removingAccount: MoneyAccount?
    @State var showArchivedAccounts = false
    @State var rangeBeforeAccount: MoneyDateRange?
    @State var confirmSamples = false
    @State private var info: String?
    @AppStorage("moneyStatsCurrency") var statsCurrencyRaw = ""
    @State var entriesCurrencyRaw = ""
    @AppStorage("moneyStatsCalendar") var statsCalendar = false
    @State var rankingExpansion = MoneyRankingExpansion()
    /// Where Statistics was when one of its bars, days or categories opened the entry list.
    struct StatsPlace { var anchor: Date; var period: MoneyPeriod; var income: Bool; var expanded: MoneyCategoryKey?; var selectedDate: Date?; var billRange: MoneyDateRange }
    @State var statsReturn: StatsPlace?
    @State var rateHistory: RateHistory?
    @State var loadingRates = false
    @State var refreshing = false
    @State var rateRefreshError: String?
    @State var showAssetRates = false
    @State var conversionRequest: MoneyConversionRequest?
    @State var lastAutomaticRateAttempt: Date?
    @State var automaticRateRetryAfter: Date?
    @State var lastAutomaticRateKey = ""
    @State var foreignCurrency = ""
    @State var document: FinanceCSV?
    @State var exporting = false

    private var presentationActive: Bool {
        editor != nil || entity != nil || conversionRequest != nil || showAssetRates || exporting || showDateRange
            || error != nil || info != nil || confirmDelete != nil || removingAccount != nil || confirmSamples
    }

    /// Nil means every book.
    var bookFilterID: UUID? { data.books.first { $0.id.uuidString == scope }?.id }
    var scopeName: String { data.book(bookFilterID)?.name ?? L("全部账本", "All books") }
    var range: DateInterval { Dates.calendar.dateInterval(of: period.component, for: anchor)! }
    var billRange: DateInterval? { drilldown?.range ?? (dateRange == .custom ? fixedRange : dateRange.interval(at: anchor, through: customEnd)) }
    var selectedAccount: MoneyAccount? { data.account(accountDetailID) }

    var entryDefaults: (book: MoneyBook?, account: MoneyAccount?) {
        data.entryDefaults(preferredBook: bookFilterID, preferredAccount: accountFilter)
    }
    var defaultEntriesCurrency: String { data.account(accountFilter)?.currency ?? entryDefaults.account?.currency ?? data.baseCurrency }
    private var entryDefaultsKey: String {
        [scope, accountFilter?.uuidString ?? "", entryDefaults.book?.id.uuidString ?? "", entryDefaults.account?.id.uuidString ?? "", defaultEntriesCurrency].joined(separator: "/")
    }
    var entriesCurrency: String {
        selectedAccount?.currency ?? (Money.currencies.contains(entriesCurrencyRaw) ? entriesCurrencyRaw : defaultEntriesCurrency)
    }
    func entryTotals(_ entries: [MoneyEntry], income: Bool) -> MoneyStatisticsTotal {
        data.statisticsTotal(entries, income: income, in: entriesCurrency, history: rateHistory, days: rateHistory?.sortedDays)
    }
    func totalDisplay(_ total: MoneyStatisticsTotal, currency: String? = nil, subtotal: Bool = false) -> String {
        if hidden { return "••••" }
        if total.missing > 0 && total.convertedCount == 0 { return L("待折算", "Unconverted") }
        return (total.estimateDates.isEmpty ? "" : "≈ ") + display(total.total, currency ?? entriesCurrency)
            + (subtotal && total.missing > 0 ? L(" · 小计", " · subtotal") : "")
    }
    func totalLabel(_ label: String, _ total: MoneyStatisticsTotal) -> String {
        total.missing > 0 && total.convertedCount > 0 ? label + L(" · 已折算小计", " · converted subtotal") : label
    }
    func balanceDisplay(spent: MoneyStatisticsTotal, earned: MoneyStatisticsTotal, currency: String) -> String {
        if hidden { return "••••" }
        guard spent.missing + earned.missing == 0 else { return L("待折算", "Unconverted") }
        return ((!spent.estimateDates.isEmpty || !earned.estimateDates.isEmpty) ? "≈ " : "") + display(earned.total - spent.total, currency)
    }
    var filtered: [MoneyEntry] {
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

    private var phonePages: some View {
        let active = accountDetailID == nil ? selection : "accounts"
        return (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))) {
            ForEach([("all", L("账单", "Entries")), ("stats", L("统计", "Statistics")), ("accounts", L("资产", "Assets"))], id: \.0) { key, title in
                Button {
                    accountDetailID = nil
                    selection = key
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

    private var pageIdentity: String {
        if selection == "all", let accountDetailID { return "account:\(accountDetailID)" }
        return selection
    }

    var body: some View {
        VStack(spacing: 0) {
            if compact { phonePages }
            ZStack {
                page
                    #if os(macOS)
                    .modifier(FinanceSearch(enabled: selection == "all" || selection == "trash", scope: pageIdentity, text: $search))
                    #endif
                    .id(pageIdentity).transition(.opacity)
            }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: pageIdentity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .primaryAction) {
                Button(action: settings) { Label(L("设置", "Settings"), systemImage: "gearshape") }
            }
            #endif
            #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    if !compact {
                        Button(L("账单", "Entries"), systemImage: "list.bullet.rectangle") { selection = "all" }
                        Button(L("统计", "Statistics"), systemImage: "chart.bar") { selection = "stats" }
                        Button(L("资产", "Assets"), systemImage: "wallet.pass") { selection = "accounts" }
                        Divider()
                    }
                    Button(L("记账管理", "Manage finance"), systemImage: "slider.horizontal.3") { selection = "manage" }
                    Button(L("最近删除", "Recently deleted"), systemImage: "trash") { selection = "trash" }
                    Divider()
                    Button(hidden ? L("显示金额", "Show amounts") : L("隐藏金额", "Hide amounts"), systemImage: hidden ? "eye.slash" : "eye") { hidden.toggle() }
                    Button(L("设置与备份", "Settings & backup"), systemImage: "gearshape", action: settings)
                } label: { Label(L("更多财务操作", "More finance options"), systemImage: compact ? "ellipsis.circle" : "line.3.horizontal") }
            }
            #endif

            #if os(macOS)
            ToolbarItem {
                Button { hidden.toggle() } label: { Label(hidden ? L("显示金额", "Show amounts") : L("隐藏金额", "Hide amounts"), systemImage: hidden ? "eye.slash" : "eye") }
            }
            #endif
            #if os(macOS)
            ToolbarItem(placement: .primaryAction) {
                Button(action: newEntry) { Label(L("记一笔", "New entry"), systemImage: "plus") }
                    .labelStyle(.titleAndIcon)
                    .keyboardShortcut("n", modifiers: .command).disabled(loadingError != nil)
            }
            #endif
        }
        #if os(iOS)
        .modifier(PhoneWorkspaceToolbar(text: $search,
            prompt: L("搜索账单、备注、标签", "Search entries, notes and tags"), scope: pageIdentity,
            enabled: selection == "all" || selection == "trash", settings: settings, add: newEntry,
            addLabel: L("记一笔", "New entry"), canAdd: loadingError == nil))
        #endif
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
                    Button { restore(lastDeleted) } label: { Text(L("撤销", "Undo")).frame(minWidth: 44, minHeight: 44) }
                    Button { self.lastDeleted = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.buttonStyle(.borderless).accessibilityLabel(L("关闭提示", "Dismiss"))
                }.padding(.horizontal, 12).background(.regularMaterial)
            }
        }
    }
    private var deleteTitle: String {
        let refunds = confirmDelete.map { $0.kind == .expense ? data.liveRefunds(of: $0.id).count : 0 } ?? 0
        return refunds > 0
            ? L("这笔消费有 \(refunds) 笔退款，会一起移到最近删除。余额和统计会同步更新。", "This purchase has \(refunds) refunds; they move to Recently deleted with it. Balances and totals will update.")
            : L("将账单移到最近删除？余额和统计会同步更新。", "Move this entry to Recently deleted? Balances and totals will update.")
    }
    var title: String {
        switch selection {
        case "accounts": return L("资产", "Assets")
        case "stats": return L("统计", "Statistics")
        case "manage": return L("记账管理", "Manage finance")
        case "trash": return L("最近删除", "Recently deleted")
        default: return selectedAccount?.name ?? L("账单", "Entries")
        }
    }
    func display(_ value: Decimal, _ currency: String? = nil) -> String { hidden ? "••••" : Money.format(value, currency ?? data.baseCurrency) }

    // MARK: Header and filters


}
extension FinanceHome {
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
    func mutate(_ change: (inout FinanceData) throws -> Void) {
        do { try FinanceStore.update(context, change); reload() } catch { self.error = error.localizedDescription }
    }
    func newEntry() {
        editor = EntryRequest(entry: data.newEntry(preferredBook: bookFilterID, preferredAccount: accountDetailID ?? accountFilter), expected: nil)
    }
    func duplicate(_ original: MoneyEntry) {
        editor = EntryRequest(entry: data.copyEntry(original, preferredBookID: bookFilterID), expected: nil)
    }
    func newRefund(_ original: MoneyEntry) {
        guard data.remainingRefund(for: original.id) > 0 else { return }
        var entry = MoneyEntry(); entry.kind = .refund; entry.title = String((L("退款：", "Refund: ") + original.title).prefix(80))
        entry.currency = original.currency; entry.accountID = original.accountID; entry.bookID = original.bookID; entry.categoryID = original.categoryID; entry.refundOf = original.id
        entry.amount = data.remainingRefund(for: original.id)
        editor = EntryRequest(entry: entry, expected: nil)
    }
    func reconcile(_ account: MoneyAccount) {
        editor = EntryRequest(entry: data.reconciliationEntry(for: account.id, bookID: bookFilterID), expected: nil)
    }
    private func delete(_ entry: MoneyEntry) {
        do {
            try FinanceStore.update(context) { try $0.trash(entry) }
            reload(); lastDeleted = data.entries.first { $0.id == entry.id }
        } catch { self.error = error.localizedDescription }
    }
    func restore(_ entry: MoneyEntry) {
        do { try FinanceStore.update(context) { try $0.restore(entry) }; lastDeleted = nil; reload() } catch { self.error = error.localizedDescription }
    }
    func addSamples() {
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
    func refreshRates() { Task { await updateAssetRates() } }
    @MainActor func updateAssetRates() async {
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
