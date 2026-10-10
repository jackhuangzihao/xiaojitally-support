import SwiftUI

/// Only the ranking reads this observable property during rendering. Opening a row
/// doesn't recompute FinanceHome's charts, filtered entries or asset summaries.
@Observable final class MoneyRankingExpansion { var key: MoneyCategoryKey? }
private struct MoneyRanking<Row: View, Detail: View>: View {
    let rows: [MoneyCategoryTotal]
    let expansion: MoneyRankingExpansion
    @ViewBuilder var row: (MoneyCategoryTotal) -> Row
    @ViewBuilder var detail: (MoneyCategoryTotal) -> Detail
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var body: some View {
        // One card for the whole ranking, rows separated by hairlines.
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                let open = expansion.key == item.id
                if index > 0 { Divider().padding(.leading, 54) }
                MoneyHover { hovering in
                    Button {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { expansion.key = open ? nil : item.id }
                    } label: {
                        HStack(spacing: 12) {
                            row(item)
                            Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }.padding(.vertical, 10).padding(.horizontal, 12).contentShape(Rectangle())
                            .background(RoundedRectangle(cornerRadius: Design.Radius.medium, style: .continuous).fill(hovering || open ? Color.primary.opacity(0.05) : .clear))
                    }.buttonStyle(.plain)
                }
                if open { detail(item) }
            }
        }.padding(4).cardSurface()
    }
}


/// The ranking receives row presentation and its existing expansion owner.
struct FinanceCategoryRanking<Detail: View>: View {
    @AppStorage("appLanguage") private var language = "system"
    let rows: [MoneyCategoryTotal]
    let expansion: MoneyRankingExpansion
    let hidden: Bool
    let category: (UUID?) -> MoneyCategory?
    let tint: (MoneyCategory?) -> Color
    let breakdownLabel: (MoneyCategoryKey) -> String
    let totalDisplay: (MoneyStatisticsTotal) -> String
    @ViewBuilder var detail: (MoneyCategoryTotal) -> Detail

    var body: some View {
        let top = rows.map { abs($0.total) }.max() ?? 1
        let sum = rows.map(\.total).filter { $0 > 0 }.reduce(0, +)
        let complete = rows.allSatisfy { $0.summary.complete }
        return MoneyRanking(rows: rows, expansion: expansion) { row in
            let category: MoneyCategory? = { if case .category(let id) = row.id { return self.category(id) }; return nil }()
            let tint = self.tint(category)
            HStack(spacing: 12) {
                MoneyIcon(symbol: category?.symbol ?? (row.id == .fees ? "arrow.left.arrow.right" : "tag"), emoji: category?.emoji, tint: tint, size: 32)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(breakdownLabel(row.id))
                        if complete && sum > 0 && row.total > 0 && !hidden { Text("\(Int((double(row.total / sum) * 100).rounded()))%").font(.caption).foregroundStyle(.secondary) }
                        Text(L("\(row.count + row.missing) 笔", "\(row.count + row.missing)")).font(.caption).foregroundStyle(.tertiary)
                        Spacer()
                        Text(totalDisplay(row.summary)).monospacedDigit().foregroundStyle(row.missing > 0 ? Color.orange : row.total < 0 ? .green : .primary)
                    }
                    if row.missing > 0 {
                        Text(L("\(row.missing) 笔待折算", "\(row.missing) unconverted")).tagStyle(.orange)
                    } else {
                        MoneyBar(value: top > 0 ? double(abs(row.total) / top) : 0, tint: row.total < 0 ? .green : tint)
                    }
                }
            }
        } detail: { row in
            detail(row)
        }
    }
}

/// History summaries are read-only; drilldown and conversion still run on the page owner.
struct FinanceCategoryHistory: View {
    @AppStorage("appLanguage") private var language = "system"
    let months: [(start: Date, summary: MoneyStatisticsTotal)]
    let label: String
    let rangeLabel: String
    let tint: Color
    let compact: Bool
    let dynamicTypeSize: DynamicTypeSize
    let statsCurrency: String
    let display: (Decimal, String?) -> String
    let totalDisplay: (MoneyStatisticsTotal) -> String
    let open: () -> Void
    let completeConversions: () -> Void

    var body: some View {
        let summaries = months.map(\.summary)
        let top = summaries.map { abs($0.total) }.max() ?? 0
        let average = MoneyStatisticsTotal.average(summaries)
        let missing = summaries.reduce(0) { $0 + $1.missing }
        let estimates = summaries.reduce(into: Set<String>()) { $0.formUnion($1.estimateDates) }
        return VStack(alignment: .leading, spacing: 10) {
            (compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout())) {
                Text(label + L(" · 近 6 个月", " · last 6 months"))
                    .font(.caption).foregroundStyle(.secondary)
                if !compact { Spacer() }
                Button(L("查看此分类账单 · ", "View category entries · ") + rangeLabel) { open() }
                    .controlSize(.small).frame(minHeight: compact ? 44 : nil)
            }
            Text(L("月均：", "Monthly average: ") + (average.map { display(Money.round($0, currency: statsCurrency), statsCurrency) }
                ?? (missing > 0 ? L("待补全折算", "Pending conversions") : L("待历史汇率确认", "Pending historical rates"))))
                .font(.caption).foregroundStyle(average == nil ? Color.orange : .secondary)
            if dynamicTypeSize.isAccessibilitySize {
                ForEach(months, id: \.start) { month in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Dates.label(month.start, pattern: "yyyy年M月")).font(.caption)
                        Text(totalDisplay(month.summary)).monospacedDigit()
                        if month.summary.missing > 0 { Text(L("\(month.summary.missing) 笔待折算", "\(month.summary.missing) unconverted")).font(.caption).foregroundStyle(.orange) }
                    }
                }
            } else {
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(months, id: \.start) { month in
                        MoneyHover { hovering in
                            VStack(spacing: 4) {
                                Text(hovering || month.start == months.last?.start ? totalDisplay(month.summary) : " ")
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
                                .accessibilityLabel(Dates.label(month.start, pattern: "yyyy年M月") + " · " + totalDisplay(month.summary))
                        }
                    }
                }.frame(minHeight: 100, alignment: .bottom)
            }
            if missing > 0 {
                Text(L("近 6 个月有 \(missing) 笔金额待折算，暂不计算月均；标记月份并非零支出。", "\(missing) amounts in these six months need conversion. The average is withheld; marked months do not mean zero activity."))
                    .font(.caption).foregroundStyle(.orange)
                Button(L("补全这 6 个月的折算…", "Complete these six months’ conversions…")) {
                    completeConversions()
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
}
