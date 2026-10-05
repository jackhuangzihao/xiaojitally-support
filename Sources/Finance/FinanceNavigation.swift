import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Charts
#if os(iOS)
import UIKit
#endif

extension FinanceHome {
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
    var periodHeader: AnyView {
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
    var bookSelector: some View {
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
    @ViewBuilder var filterChips: some View {
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
    func metric(_ label: String, _ value: String, size: CGFloat = 20) -> some View {
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

    func metricPair(_ first: (String, String), _ second: (String, String)) -> some View {
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

}
