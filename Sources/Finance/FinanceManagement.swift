import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Charts
#if os(iOS)
import UIKit
#endif

extension FinanceHome {
    var managementPage: some View {
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
                Picker(L("显示币种", "Display currency"), selection: $statsCurrencyRaw) {
                    Text(L("跟随记账本位币 · ", "Use recorded currency · ") + data.baseCurrency).tag("")
                    CurrencyPickerItems()
                }
                Text(L("可随时切换统计图表与合计的显示币种，不改变账单原金额、历史折算或账户余额。此设置与统计页共用。", "Change the currency used for Statistics totals and charts at any time. Original amounts, recorded conversions and account balances stay the same."))
                    .font(.caption).foregroundStyle(.secondary)
                if data.canChangeBaseCurrency {
                    Picker(L("记账本位币", "Recorded currency"), selection: Binding(get: { data.baseCurrency }, set: { currency in mutate { try $0.changeBaseCurrency(to: currency, expected: data.baseCurrency) } })) {
                        CurrencyPickerItems()
                    }
                } else {
                    LabeledContent(L("记账本位币", "Recorded currency"), value: data.baseCurrency)
                }
                Text(L("历史折算与预算按记账本位币保存；有账单或预算后不再更改。账单页合计默认跟随常用账户，资产总额折合人民币。", "Recorded conversions and budgets keep their original currency, which is fixed once entries or budgets exist. Entries default to the account currency; net worth is shown in CNY."))
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text(L("统计显示币种", "Reporting currency")) }
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
                    Menu {
                        Button(L("编辑分类", "Edit category")) { entity = EntityRequest(kind: .category, existingID: category.id, income: income) }
                        Button(archived ? L("恢复分类", "Restore category") : L("归档分类", "Archive category"), systemImage: archived ? "arrow.uturn.backward" : "archivebox") {
                            var value = category; value.archived = !archived
                            mutate { try $0.updateCategory(value, expected: category) }
                        }.disabled(archived && category.parentID.flatMap { data.category($0) }?.archived == true)
                        if archived && category.parentID.flatMap({ data.category($0) })?.archived == true {
                            Text(L("请先恢复上级分类", "Restore the parent category first"))
                        }
                    } label: {
                        Label(L("管理分类", "Manage category"), systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                            .frame(minWidth: 44, minHeight: 44)
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden)
                        .accessibilityLabel(L("管理分类：", "Manage category: ") + category.label)
                }
            }
            if !archived {
                Button { entity = EntityRequest(kind: .category, income: income) } label: { Label(L("新增大类", "New main category"), systemImage: "plus") }
                    .frame(minHeight: 44)
                Text(L("点 … 可编辑或归档任何分类，包括预设分类。归档后新增账单不再显示，历史账目保留；大类的子分类会一起归档。", "Use … to edit or archive any category, including presets. Archived categories disappear from new entries and keep their history. Archiving a main category includes its children."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }

    // MARK: Actions

}
