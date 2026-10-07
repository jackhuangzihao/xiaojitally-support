import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Charts
#if os(iOS)
import UIKit
#endif

extension FinanceHome {
    private struct AccountGroup: Identifiable { var type: MoneyAccountType; var accounts: [MoneyAccount]; var id: String { type.rawValue } }
}

/// An explicit header button prevents List from treating the whole overview as a disclosure target.
private struct AssetRateDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let compact: Bool

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    configuration.label
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .frame(minHeight: compact ? 44 : 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(Color.accentColor)
            .accessibilityValue(configuration.isExpanded ? L("已展开", "Expanded") : L("已收起", "Collapsed"))
            .accessibilityIdentifier("finance.assetRatesDisclosure")
            if configuration.isExpanded { configuration.content.transition(.opacity) }
        }
    }
}

extension FinanceHome {
    private var assetCurrencies: [String] { Set(data.accounts.map(\.currency)).filter { $0 != reportingCurrency }.sorted() }
    private var selectedForeignCurrency: String? { assetCurrencies.contains(foreignCurrency) ? foreignCurrency : assetCurrencies.first }
    var assetsPage: some View {
        let balances = data.accountBalances()
        let summary = data.assetSummary(in: reportingCurrency, accountBalances: balances)
        let groups = MoneyAccountType.allCases.map { type in AccountGroup(type: type, accounts: data.accounts.filter { $0.resolvedType == type && !$0.archived }) }.filter { !$0.accounts.isEmpty }
        return assetContainer {
            Section {
                assetOverview(summary).buttonStyle(.borderless)
                // Keep disclosure sizing and hit testing out of the balance/menu row.
                if !assetCurrencies.isEmpty { rateLine(summary).buttonStyle(.borderless) }
            }.listRowSeparator(.hidden).listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            ForEach(groups) { group in
                Section {
                    ForEach(group.accounts) { account in
                        accountRow(account, balance: balances[account.id, default: 0])
                    }
                } header: {
                    HStack {
                        Text(group.type.label).font(.subheadline.weight(.semibold))
                        Text("\(group.accounts.count)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let subtotal = data.assetSummary(in: reportingCurrency, accountBalances: balances, accounts: group.accounts).total {
                            Text(display(subtotal, reportingCurrency)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }.textCase(nil)
                }
            }
            if data.accounts.contains(where: \.archived) {
                Section {
                    DisclosureGroup(L("已归档账户", "Archived accounts"), isExpanded: $showArchivedAccounts) {
                        ForEach(data.accounts.filter(\.archived)) { accountRow($0, balance: balances[$0.id, default: 0]) }
                    }
                } footer: {
                    Text(L("归档用于停用账户，历史和余额仍保留。余额变化请通过转账或“核对余额”记录。", "Archive accounts you no longer use. History and balances remain; record balance changes with a transfer or Check balance."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .confirmationDialog(L("删除账户？", "Delete account?"), isPresented: Binding(get: { removingAccount != nil }, set: { if !$0 { removingAccount = nil } }), titleVisibility: .visible) {
            Button(L("删除账户", "Delete account"), role: .destructive) {
                if let account = removingAccount {
                    var expected = FinanceData(); expected.accounts = [account]
                    mutate { try $0.remove(.account, id: account.id, expected: expected) }
                }
                removingAccount = nil
            }
            Button(L("取消", "Cancel"), role: .cancel) { removingAccount = nil }
        } message: {
            Text(L("“\(removingAccount?.name ?? "")”及其初始余额将被永久删除。使用它的账本将取消默认账户设置。", "“\(removingAccount?.name ?? "")” and its opening balance will be permanently deleted. Books using it will no longer have a default account."))
        }
        .task(id: assetCurrencies.joined(separator: "-") + "-\(reportingCurrency)-\(automaticRates)") { await refreshStaleAssetRates() }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            if scenePhase == .active { Task { await refreshStaleAssetRates() } }
        }
        #if os(iOS)
        .refreshable { await updateAssetRates() }
        #endif
    }
    @ViewBuilder private func assetContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        #if os(iOS)
        List { content() }.listStyle(.insetGrouped).scrollContentBackground(.hidden)
            .contentMargins(.top, 0, for: .scrollContent)
        #else
        ScrollView { LazyVStack(alignment: .leading, spacing: 20) { content() }.padding(24) }
        #endif
    }
    private func assetOverview(_ summary: MoneyAssetSummary) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(L("账户总览", "Accounts overview")).font(.headline)
                Spacer()
                Button { entity = EntityRequest(kind: .account) } label: { Label(L("新增账户", "New account"), systemImage: "plus") }
                    .frame(minHeight: compact ? 44 : 24)
            }
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(L("净资产", "Net worth")).foregroundStyle(.secondary)
                    Spacer()
                    statsCurrencyMenu.labelStyle(.titleAndIcon).frame(minHeight: compact ? 44 : 24)
                }.font(.subheadline)
                Text(hidden ? "••••" : summary.total.map { display($0, reportingCurrency) } ?? L("待补充汇率", "Rates needed"))
                    .font(.system(size: compact ? 30 : 36, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                if summary.total == nil {
                    Label(L("缺少 \(summary.missingCurrencies.joined(separator: "、")) 汇率，总额尚不完整。", "Missing \(summary.missingCurrencies.joined(separator: ", ")) rates. The total is incomplete."), systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Divider()
                (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16)) : AnyLayout(HStackLayout(alignment: .top, spacing: 16))) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(Money.name(reportingCurrency) + " · " + reportingCurrency).font(.caption).foregroundStyle(.secondary)
                            .frame(minHeight: compact && assetCurrencies.count > 1 ? 44 : nil, alignment: .leading)
                        Text(display(summary.balances[reportingCurrency, default: 0], reportingCurrency))
                            .font(.system(size: compact ? 19 : 22, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 6) {
                        if let currency = selectedForeignCurrency {
                            if assetCurrencies.count > 1 {
                                Menu {
                                    ForEach(assetCurrencies, id: \.self) { code in Button(Money.name(code) + " · " + code) { foreignCurrency = code } }
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(L("其他币种 · ", "Other currencies · ") + currency)
                                        Image(systemName: "chevron.down").accessibilityHidden(true)
                                    }.frame(minHeight: compact ? 44 : nil)
                                }
                                .font(.caption).menuStyle(.borderlessButton).menuIndicator(.hidden)
                                .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text(L("其他币种 · ", "Other currencies · ") + currency).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(display(summary.balances[currency, default: 0], currency))
                                .font(.system(size: compact ? 19 : 22, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                        } else {
                            Text(L("其他币种", "Other currencies")).font(.caption).foregroundStyle(.secondary)
                            Text(L("暂无", "None")).font(.title3.weight(.semibold))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if let currency = selectedForeignCurrency {
                    HStack(spacing: 8) {
                        if let rate = data.assetRate(from: currency, to: reportingCurrency) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("1 " + currency + " = " + assetRateText(rate.rate) + " " + reportingCurrency)
                                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                                if rate.isManual { Text(L("手动估值", "Manual estimate")) }
                                if !rate.referenceDates.isEmpty {
                                    Text("ECB · " + rate.referenceDates.joined(separator: " / "))
                                }
                            }
                        } else {
                            Text(currency + L(" 尚未填写汇率", " needs an exchange rate"))
                        }
                        Spacer(minLength: 0)
                        Button(L("修改汇率", "Edit rate")) { showAssetRates = true }
                            .frame(minHeight: compact ? 44 : nil)
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }.padding(18).background(RoundedRectangle(cornerRadius: 14).fill(Color.accentColor.opacity(0.08)))
            if data.accounts.isEmpty {
                ContentUnavailableView {
                    Label(L("添加你的第一个账户", "Add your first account"), systemImage: "wallet.pass")
                } description: {
                    Text(L("银行卡、支付宝、现金都可以是账户。所有账本共用同一套账户，在哪个账本花钱，都从同一个余额里扣。", "Cards, wallets and cash are accounts. Every book shares them, so spending in any book comes out of the same balance."))
                } actions: { Button(L("新增账户", "New account")) { entity = EntityRequest(kind: .account) }.buttonStyle(.borderedProminent) }
            }
        }
    }
    func refreshStaleAssetRates() async {
        guard automaticRates, !assetCurrencies.isEmpty else { return }
        let key = reportingCurrency + "-" + assetCurrencies.joined(separator: "-")
        let now = Date()
        if let automaticRateRetryAfter, now < automaticRateRetryAfter { return }
        if automaticRateRetryAfter == nil, lastAutomaticRateKey == key, let lastAutomaticRateAttempt,
           now.timeIntervalSince(lastAutomaticRateAttempt) < 6 * 3600,
           Dates.calendar.isDate(lastAutomaticRateAttempt, inSameDayAs: now) { return }
        let stale = assetCurrencies.contains { currency in
            guard let rate = data.assetRate(from: currency, to: reportingCurrency) else { return true }
            return rate.quotes.contains { !$0.isManual && (now.timeIntervalSince($0.fetchedAt) > 6 * 3600 || !Dates.calendar.isDate($0.fetchedAt, inSameDayAs: now)) }
        }
        if stale {
            lastAutomaticRateKey = key; lastAutomaticRateAttempt = now
            await updateAssetRates()
        }
    }
    private func rateLine(_ summary: MoneyAssetSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let rateRefreshError {
                Label(rateRefreshError, systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(.orange)
            }
            DisclosureGroup(L("汇率与估值说明", "Rates and valuation")) {
                VStack(alignment: .leading, spacing: 10) {
                    if !summary.rateDates.isEmpty {
                        Text("ECB · " + summary.rateDates.joined(separator: " / ")).font(.caption).foregroundStyle(.secondary)
                    }
                    if !summary.manualCurrencies.isEmpty {
                        Text(L("手动估值：", "Manual estimates: ") + summary.manualCurrencies.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(L("含期初余额、负债和归档账户。参考汇率按工作日更新，仅用于当前估值，不改写历史账单。", "Includes opening balances, debts and archived accounts. Reference rates update on working days, estimate current value and never rewrite historical entries."))
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle(L("自动更新参考汇率", "Update reference rates automatically"), isOn: $automaticRates)
                    Button(action: refreshRates) {
                        Text(refreshing ? L("更新中…", "Updating…") : L("更新汇率", "Update rates")).frame(minHeight: compact ? 44 : 24)
                    }.disabled(refreshing)
                }.padding(.top, 8)
            }
            .disclosureGroupStyle(AssetRateDisclosureStyle(compact: compact))
            .font(.callout)
        }
    }
    private func accountRow(_ account: MoneyAccount, balance: Decimal) -> some View {
        let foreign = account.currency != reportingCurrency
        return HStack(spacing: 0) {
        Button { showAccount(account.id) } label: {
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
                        if let base = data.converted(balance, from: account.currency, to: reportingCurrency) {
                            Text("≈ " + display(base, reportingCurrency)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        } else {
                            Text(L("缺少汇率", "Rate needed")).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                if !compact { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
            }.padding(.horizontal, compact ? 0 : 12).padding(.vertical, 12).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("查看这个账户的全部账单", "Show every entry for this account"))
        Menu { accountActions(account) } label: {
            Label(L("管理账户", "Manage account"), systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden)
            .accessibilityLabel(L("管理账户：", "Manage account: ") + account.name)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 4))
        .contextMenu { accountActions(account) }
    }
    @ViewBuilder private func accountActions(_ account: MoneyAccount) -> some View {
        Button(L("查看账单", "Show entries")) { showAccount(account.id) }
        Button(L("编辑账户", "Edit account")) { entity = EntityRequest(kind: .account, existingID: account.id) }
        Button(L("核对余额", "Check balance")) { reconcile(account) }
        Button(account.archived ? L("恢复账户", "Restore account") : L("归档账户", "Archive account"), systemImage: account.archived ? "arrow.uturn.backward" : "archivebox") {
            toggleAccountArchive(account)
        }
        if let reason = data.removalBlock(.account, id: account.id) { Text(reason) }
        else { Button(L("删除账户…", "Delete account…"), systemImage: "trash", role: .destructive) { removingAccount = account } }
    }
    private func toggleAccountArchive(_ account: MoneyAccount) {
        var value = account; value.archived.toggle()
        mutate { try $0.updateAccount(value, expected: account) }
    }
    func showAccount(_ id: UUID) {
        if accountDetailID == nil { rangeBeforeAccount = dateRange }
        drilldown = nil; accountDetailID = id; accountFilter = nil; categoryFilter = nil; kindFilter = nil; search = ""; dateRange = .all
        selection = "all"
    }

    // MARK: Categories and settings

}
