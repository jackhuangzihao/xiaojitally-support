import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Charts
#if os(iOS)
import UIKit
#endif

// MARK: - Shared pieces

/// A thin colored bar; the system progress bar ignores category colors on the Mac.
struct MoneyBar: View {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
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


extension FinanceHome {
    private var statsCurrency: String { reportingCurrency }
    func statsEntries(_ span: DateInterval) -> [MoneyEntry] {
        data.entries.filter { $0.deletedAt == nil && !$0.isPending && $0.date >= span.start && $0.date < span.end && (bookFilterID == nil || $0.bookID == bookFilterID) }
    }
    private func statsValue(_ entry: MoneyEntry, income: Bool, days: [String]?) -> Decimal? {
        data.statisticsAmount(entry, income: income, in: statsCurrency, history: rateHistory, days: days)
    }
    private func statsSum(_ entries: [MoneyEntry], income: Bool, days: [String]?) -> MoneyStatisticsTotal {
        data.statisticsTotal(entries, income: income, in: statsCurrency, history: rateHistory, days: days)
    }
    private var selectedStatsRange: DateInterval? {
        guard statsCalendar, let date = statsSelectedDate, date >= range.start, date < range.end else { return nil }
        return Dates.calendar.dateInterval(of: statsUnit, for: date)
    }
    private var categoryStatsRange: DateInterval { selectedStatsRange ?? range }
    private var categoryRangeLabel: String {
        let span = categoryStatsRange
        if selectedStatsRange != nil { return Dates.label(span.start, pattern: statsUnit == .month ? "yyyy年M月" : "M月d日") }
        if period != .week { return Dates.label(span.start, pattern: period == .year ? "yyyy年" : "yyyy年M月") }
        return Dates.label(span.start, pattern: "M月d日") + " – " + Dates.label(span.end.addingTimeInterval(-1), pattern: "M月d日")
    }
    var statisticsPage: some View {
        let span = range, days = rateHistory?.sortedDays
        let entries = statsEntries(span)
        let spent = statsSum(entries, income: false, days: days), earned = statsSum(entries, income: true, days: days)
        let previousAnchor = Dates.calendar.date(byAdding: period.component, value: -1, to: anchor) ?? anchor
        let before = statsSum(statsEntries(Dates.calendar.dateInterval(of: period.component, for: previousAnchor)!), income: false, days: days)
        let value: (MoneyEntry) -> Decimal? = { statsValue($0, income: statsIncome, days: days) }
        let rows = categoryRows(selectedStatsRange.map { statsEntries($0) } ?? entries)
        let earliest = data.entries.filter { $0.deletedAt == nil && !$0.isPending }.map(\.date).min() ?? Date()
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                periodHeader
                // Same summary card as the bills page: spending leads, income and net beside it.
                VStack(alignment: .leading, spacing: 12) {
                    (compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 24))) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(totalLabel(L("支出", "Spending"), spent)).font(.caption).foregroundStyle(.secondary)
                            Text(totalDisplay(spent, currency: statsCurrency)).font(.heroAmount).lineLimit(1).minimumScaleFactor(0.5)
                                .accessibilityLabel(totalLabel(L("支出", "Spending"), spent)).accessibilityValue(totalDisplay(spent, currency: statsCurrency))
                            change(now: spent, before: before)
                        }
                        if !compact { Spacer(minLength: 0) }
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) { statsFigures(spent: spent, earned: earned) }
                            VStack(alignment: .leading, spacing: 8) { statsFigures(spent: spent, earned: earned) }
                        }
                    }
                    rateNote(entries, estimates: spent.estimateDates.union(earned.estimateDates))
                    if spent.missing + earned.missing > 0 { Divider(); missingAmounts(spent.missing + earned.missing) }
                    DisclosureGroup(L("明细与计算说明", "Breakdown and calculation")) {
                        VStack(alignment: .leading, spacing: 8) {
                            originalSplit(entries)
                            Text(L("本期结余是收入减支出，不含期初余额。支出含手续费、扣除退款；负数表示退款更多。外币使用账单已记录的折算或对应日期的参考汇率。", "Period net is income minus spending, excluding opening balances. Spending includes fees minus refunds; negative spending means refunds were larger. Foreign totals use recorded conversions or reference rates for the entry date."))
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 8)
                    }.font(.callout)
                }.padding(compact ? Design.Spacing.l : 20).cardSurface()
                let selectedTotal = statsIncome ? earned : spent
                // The chart and its two switches share one card.
                VStack(alignment: .leading, spacing: 10) {
                    (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))) {
                        Picker(L("方向", "Direction"), selection: $statsIncome) {
                            Text(L("支出", "Spending")).tag(false)
                            Text(L("收入", "Income")).tag(true)
                        }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: compact ? .infinity : 150)
                        if !compact { Spacer() }
                        Picker(L("视图", "View"), selection: $statsCalendar) {
                            Text(L("趋势", "Trend")).tag(false)
                            Text(L("日历", "Calendar")).tag(true)
                        }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: compact ? .infinity : 130)
                    }
                    if selectedTotal.missing > 0 {
                        Text(L("图表和分类仅显示已折算部分，空白不代表零收支。", "Charts and categories show converted amounts only; gaps do not mean zero activity."))
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if !statsCalendar && rows.isEmpty {
                        Text(selectedTotal.missing > 0 ? L("本期账单尚待折算，补全后显示图表。", "Complete the pending conversions to see this period’s charts.") : statsIncome ? L("这段时间没有可统计的收入。", "No income in this period.") : L("这段时间没有可统计的支出或退款。", "No spending or refunds in this period."))
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
                    } else {
                        let points = buckets(entries, span: span, value: value)
                        MoneyChartHover { hovered in
                            if statsCalendar { calendarGrid(points, hovered: hovered) } else { trend(points, hovered: hovered) }
                        }.id(span.start)
                    }
                }.padding(compact ? Design.Spacing.m : Design.Spacing.l).cardSurface()
                if statsCalendar || !rows.isEmpty {
                    categorySummaryHeader
                    if rows.isEmpty {
                        Text(statsIncome ? L("所选日期没有收入。", "No income for the selected date.") : L("所选日期没有支出或退款。", "No spending or refunds for the selected date."))
                            .foregroundStyle(.secondary)
                    } else { ranking(rows) }
                }
            }.padding(compact ? 16 : 24)
        }
        .onChange(of: span.start) { _, _ in statsSelectedDate = nil; rankingExpansion.key = nil }
        .onChange(of: period) { _, _ in statsSelectedDate = nil; rankingExpansion.key = nil }
        .task(id: "\(statsCurrency)-\(data.baseCurrency)-\(Int(earliest.timeIntervalSince1970 / 86400))") { await loadRates(since: earliest) }
    }
    /// Income and period net beside the spending total; an unconverted value shows in orange.
    @ViewBuilder private func statsFigures(spent: MoneyStatisticsTotal, earned: MoneyStatisticsTotal) -> some View {
        summaryFigure(totalLabel(L("收入", "Income"), earned), totalDisplay(earned, currency: statsCurrency),
                      tint: earned.missing > 0 && earned.convertedCount == 0 ? .orange : earned.total > 0 && !hidden ? .green : .primary)
        summaryFigure(L("本期结余", "Period net"), balanceDisplay(spent: spent, earned: earned, currency: statsCurrency),
                      tint: spent.missing + earned.missing > 0 && spent.convertedCount + earned.convertedCount == 0 ? .orange : .primary,
                      caption: netCaption(spent: spent, earned: earned))
    }
    func loadRates(since: Date, currency: String? = nil) async {
        guard (currency ?? statsCurrency) != data.baseCurrency else { return }
        if rateHistory == nil { rateHistory = await RateHistoryStore.cached }
        loadingRates = true
        if let history = try? await RateHistoryStore.load(since: since) { rateHistory = history }
        loadingRates = false
    }
    var entriesCurrencyMenu: some View {
        Menu {
            Button(L("跟随常用账户：", "Follow default account: ") + defaultEntriesCurrency) { entriesCurrencyRaw = "" }
            Divider()
            CurrencyChoices { entriesCurrencyRaw = $0 }
        } label: { Label(entriesCurrency + (entriesCurrencyRaw.isEmpty ? L(" · 自动", " · Auto") : ""), systemImage: "banknote") }
            .fixedSize().help(L("默认跟随账户币种；临时切换只改变合计显示，不改变原始金额", "Follows the default account; a temporary override changes totals, never original amounts"))
    }
    var statsCurrencyMenu: some View {
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
        } else if loadingRates && rateHistory == nil && statsCurrency != data.baseCurrency && foreign {
            Text(L("正在下载每日参考汇率…", "Downloading daily reference rates…"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    /// "比上月 ↑12%": spending up reads as a warning, down as good news.
    @ViewBuilder func change(now: MoneyStatisticsTotal, before: MoneyStatisticsTotal) -> some View {
        if let value = now.change(from: before), !hidden {
            let ratio = double(value)
            let name: String = { switch period { case .week: L("比上周", "vs last week"); case .month: L("比上月", "vs last month"); case .year: L("比去年", "vs last year") } }()
            let text = abs(ratio) < 0.005 ? L("持平", "flat") : (ratio > 0 ? "↑" : "↓") + "\(Int((abs(ratio) * 100).rounded()))%"
            Text(name + " " + text).font(.caption).foregroundStyle(abs(ratio) < 0.005 ? Color.secondary : ratio > 0 ? Color.orange : Color.green)
                .help(L("上一段支出 ", "Previous period ") + display(before.total, statsCurrency))
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
    private func trend(_ points: [TrendPoint], hovered: Binding<Date?>) -> some View {
        FinanceTrendChart(points: points, hovered: hovered, statsUnit: statsUnit, period: period,
                          statsIncome: statsIncome, hidden: hidden, statsCurrency: statsCurrency,
                          display: display, pointDisplay: pointDisplay) { date, unit in
            openBucket(date, unit: unit)
        }
    }
    private func pointDisplay(_ point: TrendPoint) -> String {
        if hidden { return "••••" }
        if point.missing > 0 && point.count == 0 { return L("待折算", "Unconverted") }
        return display(point.amount, statsCurrency) + (point.missing > 0 ? L(" · 小计", " · subtotal") : "")
    }
    private func calendarGrid(_ points: [TrendPoint], hovered: Binding<Date?>) -> some View {
        FinanceStatisticsCalendar(points: points, hovered: hovered, statsUnit: statsUnit,
                                  statsIncome: statsIncome, hidden: hidden, statsCurrency: statsCurrency,
                                  compact: compact, statsSelectedDate: statsSelectedDate,
                                  display: display, pointDisplay: pointDisplay, selectStatsDate: selectStatsDate)
    }
    private func selectStatsDate(_ date: Date) {
        statsSelectedDate = date
        rankingExpansion.key = nil
    }
    private var categorySummaryHeader: some View {
        // The calendar owns date selection; keep only context and navigation beside the categories.
        (compact || dynamicTypeSize.isAccessibilitySize
         ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
         : AnyLayout(HStackLayout(spacing: 16))) {
            Text(categoryRangeLabel + L(" · 分类汇总", " · Category totals"))
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            if let span = selectedStatsRange {
                (dynamicTypeSize.isAccessibilitySize
                 ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                 : AnyLayout(HStackLayout(spacing: 16))) {
                    Button(statsUnit == .month ? L("查看本月账单", "View month’s entries") : L("查看当天账单", "View day’s entries")) {
                        openBucket(span.start, unit: statsUnit)
                    }
                    .frame(minHeight: compact ? 44 : 24)
                    Button(L("返回整期", "Show full period")) {
                        statsSelectedDate = nil; rankingExpansion.key = nil
                    }
                    .frame(minHeight: compact ? 44 : 24)
                }.font(.callout).buttonStyle(.borderless)
            }
        }
    }

    private func rememberStats() {
        statsReturn = StatsPlace(anchor: anchor, period: period, income: statsIncome, expanded: rankingExpansion.key, selectedDate: statsSelectedDate, billRange: dateRange)
    }
    func backToStats(_ place: StatsPlace) {
        drilldown = nil; dateRange = place.billRange
        anchor = place.anchor; period = place.period; statsIncome = place.income; rankingExpansion.key = place.expanded; statsSelectedDate = place.selectedDate
        selection = "stats"
    }
    private func openBucket(_ date: Date, unit: Calendar.Component) {
        rememberStats()
        drilldown = nil; categoryFilter = nil; kindFilter = nil; accountFilter = nil; accountDetailID = nil; search = ""
        anchor = date; dateRange = unit == .month ? .month : .day
        selection = "all"
    }
    func breakdownLabel(_ key: MoneyCategoryKey) -> String {
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
        FinanceCategoryRanking(rows: rows, expansion: rankingExpansion, hidden: hidden,
                               category: data.category, tint: data.tint, breakdownLabel: breakdownLabel,
                               totalDisplay: { totalDisplay($0, currency: statsCurrency, subtotal: true) }) { row in
            let category: MoneyCategory? = { if case .category(let id) = row.id { return data.category(id) }; return nil }()
            subcategoryRanking(row.id)
            categoryHistory(row.id, tint: data.tint(category))
        }
    }
    @ViewBuilder private func subcategoryRanking(_ key: MoneyCategoryKey) -> some View {
        if case .category(let id) = key, let id {
            let children = data.categories.filter { $0.parentID == id }
            if !children.isEmpty {
                let periodEntries = statsEntries(categoryStatsRange)
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
        return FinanceCategoryHistory(months: months, label: breakdownLabel(key), rangeLabel: categoryRangeLabel,
                                      tint: tint, compact: compact, dynamicTypeSize: dynamicTypeSize,
                                      statsCurrency: statsCurrency, display: display,
                                      totalDisplay: { totalDisplay($0, currency: statsCurrency, subtotal: true) },
                                      open: { drill(key) }) {
            guard let first = months.first?.start, let end = Dates.calendar.dateInterval(of: .month, for: anchor)?.end else { return }
            prepareConversion(data.entries.filter {
                $0.deletedAt == nil && !$0.isPending && $0.date >= first && $0.date < end && (bookFilterID == nil || $0.bookID == bookFilterID)
                    && key.includes($0, income: statsIncome, data: data)
            })
        }
    }
    private func drill(_ key: MoneyCategoryKey, includeSubcategories: Bool = true) {
        rememberStats()
        drilldown = MoneyDrilldown(range: categoryStatsRange, key: key, income: statsIncome, includeSubcategories: includeSubcategories)
        categoryFilter = nil; kindFilter = nil; accountFilter = nil; accountDetailID = nil; search = ""; dateRange = .month
        selection = "all"
    }

    // MARK: Assets

}

extension FinanceHome {
    struct TrendPoint: Identifiable { var date: Date; var amount: Decimal; var count: Int; var missing: Int; var value: Double { double(amount) }; var id: Date { date } }
}
