import SwiftUI
import SwiftData

/// Bindings point directly to the editor's existing fields and FocusState.
struct FinanceEntryAmount<Focus: Hashable>: View {
    @AppStorage("appLanguage") private var language = "system"
    let compact: Bool
    let kind: MoneyKind
    let signedAmount: Bool
    let value: Decimal?
    @Binding var currency: String
    @Binding var expression: String
    @Binding var title: String
    let focus: FocusState<Focus?>.Binding
    let amountFocus: Focus
    let titleFocus: Focus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(L("金额", "Amount")).foregroundStyle(.secondary)
                Menu {
                    CurrencyChoices { currency = $0 }
                } label: { Text(Money.symbol(currency)) }
                    .menuStyle(.borderlessButton).fixedSize()
                    .disabled(kind == .refund || kind == .adjustment || kind == .transfer)
                    .help(L("币种", "Currency"))
                TextField("0.00", text: $expression)
                    .font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                    .textFieldStyle(.plain).focused(focus, equals: amountFocus)
                    .accessibilityLabel(L("金额，可输入加减算式", "Amount, addition and subtraction supported"))
                    #if os(iOS)
                    .keyboardType(signedAmount ? .numbersAndPunctuation : .decimalPad)
                    #endif
                if expression.contains(where: { $0 == "+" || $0 == "−" || $0 == "-" }) && expression.count > 1, let value {
                    Text("= " + Money.format(value, currency)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L("备注", "Note")).font(.caption).foregroundStyle(.secondary)
                TextField(L("可不填", "Optional"), text: $title)
                    .textFieldStyle(.plain).focused(focus, equals: titleFocus).frame(minHeight: compact ? 44 : nil)
                    .accessibilityLabel(L("备注", "Note"))
            }
        }
    }
}

struct FinanceEntryDetails<Focus: Hashable>: View {
    @AppStorage("appLanguage") private var language = "system"
    let compact: Bool
    let recent: [String]
    let tasks: [TaskItem]
    @Binding var notes: String
    @Binding var tags: String
    @Binding var taskID: UUID?
    let focus: FocusState<Focus?>.Binding
    let notesFocus: Focus
    let tagsFocus: Focus
    let addTag: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldTitle(L("详细说明", "Details"), L("写不下的细节，比如买了什么、和谁一起、发票号。", "Anything longer: what you bought, who with, an invoice number."))
            TextField(L("可不填", "Optional"), text: $notes, axis: .vertical).focused(focus, equals: notesFocus).lineLimit(2...5).textFieldStyle(.roundedBorder)
            fieldTitle(L("标签", "Tags"), L("给账单打记号，方便以后搜索，比如“报销”“出差”。多个用逗号分开。", "Marks for finding entries later, such as “reimburse” or “work trip”. Separate with commas."))
            TextField(L("可不填", "Optional"), text: $tags).focused(focus, equals: tagsFocus).textFieldStyle(.roundedBorder)
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
            Picker(L("关联任务", "Linked task"), selection: $taskID) {
                Text(L("不关联", "None")).tag(nil as UUID?)
                ForEach(tasks.filter { $0.deletedAt == nil || $0.id == taskID }.sorted { $0.createdAt > $1.createdAt }) { Text($0.title).tag(Optional($0.id)) }
                if let id = taskID, !tasks.contains(where: { $0.id == id }) { Text(L("原任务已删除", "Original task removed")).tag(Optional(id)) }
            }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        }.padding(12).background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }

    private func fieldTitle(_ title: String, _ hint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout.weight(.medium))
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Category presentation reads choices; the editor owns selection side effects and focus.
struct FinanceEntryCategories: View {
    @AppStorage("appLanguage") private var language = "system"
    let compact: Bool
    let dynamicTypeSize: DynamicTypeSize
    let roots: [MoneyCategory]
    let children: [MoneyCategory]
    let parent: MoneyCategory?
    let selectedRoot: UUID?
    @Binding var categoryID: UUID?
    let categoryPath: (UUID?) -> String
    let selectCategory: (UUID) -> Void
    let addCategory: (UUID?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("分类", "Category")).font(.subheadline.weight(.medium))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: compact ? (dynamicTypeSize.isAccessibilitySize ? 2 : 4) : 6), spacing: 8) {
                ForEach(roots) { category in categoryButton(category, selected: category.id == selectedRoot) }
                addCategoryButton(parentID: nil)
            }
            if let parent, !children.isEmpty {
                Divider()
                HStack {
                    Text(parent.label + L(" · 子分类", " · subcategories")).font(.subheadline.weight(.semibold))
                    Spacer()
                    Button(L("不细分", "No subcategory")) { categoryID = parent.id }.font(.caption).frame(minHeight: 44)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: compact ? (dynamicTypeSize.isAccessibilitySize ? 2 : 4) : 6), spacing: 8) {
                    ForEach(children) { category in categoryButton(category, selected: category.id == categoryID) }
                    if !parent.archived { addCategoryButton(parentID: parent.id) }
                }
            } else if let parent, !parent.archived {
                Button { addCategory(parent.id) } label: {
                    Label(L("为“\(parent.label)”添加子分类", "Add a subcategory to \(parent.label)"), systemImage: "plus")
                }.font(.callout).frame(minHeight: 44)
            }
        }
    }
    private func categoryButton(_ category: MoneyCategory, selected: Bool) -> some View {
        let tint = MoneyColor.color(category.resolvedColor)
        return Button {
            selectCategory(category.id)
        } label: {
            VStack(spacing: 5) {
                MoneyIcon(symbol: category.symbol, emoji: category.emoji, tint: selected ? .white : tint, size: 40)
                    .background(Circle().fill(selected ? tint : .clear))
                Text(category.label).font(.caption).lineLimit(2).foregroundStyle(selected ? .primary : .secondary)
            }.frame(maxWidth: .infinity, minHeight: 60).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10).fill(selected ? tint.opacity(0.1) : .clear)).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(categoryPath(category.id)).accessibilityAddTraits(selected ? [.isSelected] : [])
    }
    private func addCategoryButton(parentID: UUID?) -> some View {
        Button { addCategory(parentID) } label: {
            VStack(spacing: 5) {
                Image(systemName: "plus").font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: 40, height: 40).overlay(Circle().strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3])))
                Text(L("新增", "Add")).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, minHeight: 60).padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(parentID == nil ? L("新增大类", "New main category") : L("新增子分类", "New subcategory"))
    }
}
