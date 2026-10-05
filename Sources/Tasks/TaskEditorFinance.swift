import SwiftUI
import SwiftData

extension TaskEditor {
    // A new task keeps its entry in this draft; both are committed by the same Save.
    var newTaskFinance: AnyView {
        if let finance = linkedFinance {
            let binding = Binding(get: { linkedFinance ?? finance }, set: { linkedFinance = $0 })
            return AnyView(VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(L("同时记一笔", "Record an entry"), systemImage: "banknote").font(.subheadline.weight(.semibold))
                    Spacer()
                    Button { linkedFinance = nil; focus = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 44, height: 44)
                    }.buttonStyle(.plain).accessibilityLabel(L("移除这笔未保存账单", "Remove this unsaved entry"))
                }
                Picker(L("收支类型", "Entry type"), selection: binding.entry.kind) {
                    Text(MoneyKind.expense.label).tag(MoneyKind.expense)
                    Text(MoneyKind.income.label).tag(MoneyKind.income)
                }.pickerStyle(.segmented)
                financeAmountField(L("金额", "Amount") + " · " + finance.entry.currency, text: binding.amount, field: .financeAmount)
                if financeCurrencyChanged {
                    Text(L("账户币种已更换，请按 \(finance.entry.currency) 重新输入金额。", "The account currency changed. Enter the amount in \(finance.entry.currency)."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                financeChoice(L("账本", "Book")) {
                    Picker(L("账本", "Book"), selection: binding.entry.bookID) {
                        ForEach(finance.ledger.books.filter { !$0.archived }) { Text($0.name).tag(Optional($0.id)) }
                    }.pickerStyle(.menu).labelsHidden()
                }
                financeChoice(L("账户", "Account")) {
                    Picker(L("账户", "Account"), selection: binding.entry.accountID) {
                        Text(L("不关联账户", "No account")).tag(nil as UUID?)
                        ForEach(finance.ledger.accounts.filter { !$0.archived }) { Text($0.name + " · " + $0.currency).tag(Optional($0.id)) }
                    }.pickerStyle(.menu).labelsHidden()
                }
                financeChoice(L("分类", "Category")) {
                    Picker(L("分类", "Category"), selection: binding.entry.categoryID) {
                        Text(L("未分类", "Uncategorised")).tag(nil as UUID?)
                        ForEach(finance.ledger.orderedCategories.filter { !$0.archived && $0.isIncome == (finance.entry.kind == .income) }) {
                            Text(finance.ledger.categoryPath($0.id)).tag(Optional($0.id))
                        }
                    }.pickerStyle(.menu).labelsHidden()
                }
                DatePicker(L("记账日期", "Entry date"), selection: binding.entry.date, displayedComponents: .date).datePickerStyle(.compact)
                if finance.entry.currency != finance.ledger.baseCurrency {
                    financeAmountField(L("折算金额", "Converted amount") + " · " + finance.ledger.baseCurrency, text: binding.converted, field: .financeConverted)
                    if let rate = finance.referenceRate, finance.converted == finance.estimatedConversion {
                        Text(L("参考价日期：", "Reference rate date: ") + rate.date).font(.caption).foregroundStyle(.secondary)
                    } else if finance.converted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(L("未填写折算金额时，这笔账单会标记为待折算，可在财务中补全。", "Without a converted amount, this entry will be marked for conversion in Finance."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(L("保存任务时一起入账；取消不会产生账单。重复任务只记录这一次。", "Saved together with this task. Cancelling creates no entry. Repeating tasks record this occurrence only."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onChange(of: finance.entry.kind) { _, kind in
                linkedFinance?.entry.categoryID = finance.ledger.defaultCategory(income: kind == .income)
            }
            .onChange(of: finance.entry.bookID) { _, id in
                if finance.ledger.books.first(where: { $0.id == id })?.defaultAccountID != nil {
                    linkedFinance?.entry.accountID = finance.ledger.defaultAccount(for: id)
                }
            }
            .onChange(of: finance.entry.accountID) { _, _ in
                let oldCurrency = linkedFinance?.entry.currency
                linkedFinance?.followAccountCurrency()
                if oldCurrency != linkedFinance?.entry.currency { financeCurrencyChanged = true }
            }
            .onChange(of: finance.amount) { _, value in
                linkedFinance?.refreshConversion()
                if !value.isEmpty { financeCurrencyChanged = false }
            }
            .onChange(of: finance.entry.date) { _, _ in linkedFinance?.refreshConversion() })
        } else {
            return AnyView(Button {
                do {
                    linkedFinance = TaskFinanceDraft(ledger: try FinanceStore.read(context) ?? .initial)
                    financeCurrencyChanged = false
                    focus = .financeAmount
                } catch { errorMessage = error.localizedDescription }
            } label: {
                Label(L("同时记一笔", "Record an entry with this task"), systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(Color.accentColor))
        }
    }

    private func financeAmountField(_ label: String, text: Binding<String>, field: Focus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField("0.00", text: text).textFieldStyle(.roundedBorder).focused($focus, equals: field)
                .accessibilityLabel(label)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
        }
    }

    private func financeChoice<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content().frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
    }

    // MARK: Schedule — five rows that are always shown; tapping one opens it right underneath

}
