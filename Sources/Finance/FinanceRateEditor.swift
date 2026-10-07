import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Charts
#if os(iOS)
import UIKit
#endif

struct MoneyConversionRequest: Identifiable {
    let id = UUID()
    let ledger: FinanceData
}

/// Preparing a preview never writes the ledger. The store rechecks every original when confirmed.
struct FinanceConversionPreview: View {
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

func assetRateText(_ value: Decimal) -> String {
    var rate = value, rounded = Decimal.zero
    NSDecimalRound(&rounded, &rate, 9, .plain)
    return Money.text(rounded)
}

struct FinanceRateEditor: View {
    // Freeze the quote target and comparison snapshot for this editing session.
    @State private var data: FinanceData
    @State private var currency: String
    init(data: FinanceData, currency: String) {
        _data = State(initialValue: data)
        _currency = State(initialValue: currency)
    }
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appLanguage") private var language = "system"
    @FocusState private var rateFocused: Bool
    @State private var values: [String: String] = [:]
    @State private var restoreReference: Set<String> = []
    @State private var error: String?
    private var currencies: [String] { Set(data.accounts.map(\.currency)).filter { $0 != currency }.sorted() }
    private func originalText(_ currency: String) -> String {
        guard let stored = data.assetRate(from: currency, to: self.currency) else { return "" }
        return assetRateText(stored.rate)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(L("填写 1 单位其他币种兑换多少 \(currency)。仅改变当前资产估值，不改变历史账单。", "Enter \(currency) per 1 unit of each other currency. This changes current asset estimates, never historical entries."))
                        .font(.callout)
                }
                if currencies.isEmpty { Text(L("添加外币账户后可在这里填写汇率。", "Add a foreign-currency account to enter its rate here.")) }
                ForEach(currencies, id: \.self) { currency in
                    Section(Money.name(currency) + " · " + currency) {
                        HStack {
                            Text("1 " + currency + " =")
                            TextField(L("汇率", "Rate"), text: Binding(get: { values[currency, default: originalText(currency)] }, set: { values[currency] = $0; restoreReference.remove(currency) }))
                                .multilineTextAlignment(.trailing).monospacedDigit().focused($rateFocused)
                                .accessibilityLabel("1 " + currency + L("兑换汇率，单位 ", " in ") + self.currency)
                                #if os(iOS)
                                .keyboardType(.decimalPad)
                                #endif
                            Text(self.currency).foregroundStyle(.secondary)
                        }.frame(minHeight: 44)
                        if restoreReference.contains(currency) {
                            Text(L("保存后清除此币对的手动汇率，其他币对仍保留。估值可能继续使用其他手动汇率换算；可更新参考价。", "Saving clears this pair’s manual rate and keeps all other pairs. Estimates may still use other manual rates through cross-conversion. You can update reference rates.")).font(.caption).foregroundStyle(.secondary)
                        } else if let rate = data.assetRate(from: currency, to: self.currency) {
                            Text((rate.isManual ? L("含手动汇率", "Includes manual rates") : "ECB") + (rate.referenceDates.isEmpty ? "" : " · " + rate.referenceDates.joined(separator: " / ")))
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(L("暂无汇率，此币种尚未计入总额。", "No rate yet. This currency cannot be included in the total.")).font(.caption).foregroundStyle(.orange)
                        }
                        if data.storedRate(from: currency, to: self.currency)?.isManual == true {
                            Button(L("清除此币对手动汇率", "Clear this pair’s manual rate")) { restoreReference.insert(currency); values[currency] = "" }
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
                        guard ledger.assetRate(from: currency, to: self.currency) == data.assetRate(from: currency, to: self.currency) else {
                            throw TaskBackup.invalid(L("汇率已更新，请重新打开后修改。", "Rates have changed. Reopen this editor before changing them."))
                        }
                        if restoreReference.contains(currency) { ledger.removeManualRate(from: currency, to: self.currency) }
                        else { try ledger.setManualRate(from: currency, to: self.currency, text: values[currency, default: ""]) }
                    }
                }
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
