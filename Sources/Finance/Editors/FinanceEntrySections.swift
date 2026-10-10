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
    var calculatorOn = false
    var toggleCalculator: () -> Void = {}
    /// Show how earlier names can be reused (new income and expenses only).
    var nameHint = false
    /// Earlier names matching what is typed; choosing one also takes its category and account.
    var suggestions: [MoneyEntrySuggestion] = []
    var detail: (MoneyEntrySuggestion) -> String = { _ in "" }
    var choose: (MoneyEntrySuggestion) -> Void = { _ in }

    var body: some View {
        // The amount leads the editor; the name shares its card, under a hairline.
        VStack(alignment: .leading, spacing: 0) {
            Text(kind.label + L("金额", " amount")).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .center, spacing: 10) {
                Menu {
                    CurrencyChoices { currency = $0 }
                } label: {
                    Text(Money.symbol(currency)).font(.headline)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: Design.Radius.medium - 2, style: .continuous))
                }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .disabled(kind == .refund || kind == .adjustment || kind == .transfer)
                    .help(L("币种", "Currency"))
                TextField("0.00", text: $expression)
                    .font(.system(size: compact ? 34 : 40, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(kind == .income ? Color.green : .primary)
                    .textFieldStyle(.plain).focused(focus, equals: amountFocus)
                    .accessibilityLabel(L("金额，可输入加减算式", "Amount, addition and subtraction supported"))
                    #if os(iOS)
                    .keyboardType(signedAmount ? .numbersAndPunctuation : .decimalPad)
                    #endif
                if expression.contains(where: { $0 == "+" || $0 == "−" || $0 == "-" }) && expression.count > 1, let value {
                    Text("= " + Money.format(value, currency)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer(minLength: 0)
                Button(action: toggleCalculator) {
                    Label(L("计算器", "Calculator"), systemImage: "plus.forwardslash.minus")
                }
                .buttonStyle(CardButtonStyle(prominent: calculatorOn, minHeight: compact ? 44 : 0))
                .accessibilityAddTraits(calculatorOn ? [.isSelected] : [])
                .help(L("打开计算器键盘，可以输入加减算式", "Open the calculator keypad for addition and subtraction"))
            }
            Divider().padding(.vertical, 10)
            HStack(spacing: 8) {
                Image(systemName: "pencil").foregroundStyle(.tertiary).accessibilityHidden(true)
                TextField(nameHint ? L("名称：输入后可套用以前记过的分类和账户", "Name: type to reuse an earlier category and account")
                                   : L("名称（可不填）", "Name (optional)"), text: $title)
                    .textFieldStyle(.plain).focused(focus, equals: titleFocus).frame(minHeight: compact ? 44 : 22)
                    .accessibilityLabel(L("名称", "Name"))
            }
            if !suggestions.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(suggestions) { suggestion in
                        let exact = MoneyTitleIndex.isExact(suggestion, title)
                        Button { choose(suggestion) } label: {
                            HStack(spacing: 4) {
                                Text(suggestion.title).lineLimit(1)
                                let extra = detail(suggestion)
                                if !extra.isEmpty { Text(extra).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            .font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                            .frame(minHeight: compact ? 44 : nil)
                            .background(exact ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06), in: Capsule())
                            .contentShape(Capsule())
                        }.buttonStyle(.plain)
                            .accessibilityLabel(L("用以前的“", "Use earlier “") + suggestion.title + L("”", "”"))
                            .accessibilityHint(L("同时选上次用的分类和账户", "Also picks the category and account used last time"))
                    }
                }.padding(.top, 8).accessibilityIdentifier("finance.titleSuggestions")
            }
        }
        .padding(14).cardSurface()
    }
}

struct FinanceEntryDetails<Focus: Hashable>: View {
    @AppStorage("appLanguage") private var language = "system"
    let compact: Bool
    let tasks: [TaskItem]
    @Binding var notes: String
    @Binding var taskID: UUID?
    let focus: FocusState<Focus?>.Binding
    let notesFocus: Focus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldTitle(L("备注", "Notes"), L("补充细节，例如和谁一起、买了什么、发票号。填了会显示在账单列表里。", "Extra details such as who with, what you bought or an invoice number. Shown in the entry list."))
            TextField(L("可不填", "Optional"), text: $notes, axis: .vertical).focused(focus, equals: notesFocus).lineLimit(2...5).textFieldStyle(.roundedBorder)
            fieldTitle(L("关联任务", "Linked task"), L("这笔钱对应待办里的哪件事，可在任务里看到相关花费。", "Which task this money belongs to; the task shows its entries."))
            TaskLinkPicker(tasks: tasks, taskID: $taskID)
        }.padding(14).cardSurface()
    }

    private func fieldTitle(_ title: String, _ hint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout.weight(.medium))
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Which tasks to offer when linking an entry. Pure, so the choice is testable without a store.
enum TaskLinkOptions {
    struct Candidate: Equatable {
        var id: UUID
        var title: String
        var done: Bool
        var deleted: Bool
        var date: Date?
        var completedAt: Date?
    }
    struct Option: Identifiable, Equatable {
        var id: UUID
        var title: String
        var done: Bool
        var date: Date?
    }

    /// Without a query: unfinished tasks dated within a week either side of today, by date, then tasks completed
    /// in the last week. With one: any task whose name contains it, unfinished first. Deleted tasks are never offered.
    static func make(_ candidates: [Candidate], query: String, now: Date = Date(), calendar: Calendar = Dates.calendar)
        -> (open: [Option], done: [Option]) {
        let live = candidates.filter { !$0.deleted }
        func option(_ c: Candidate) -> Option { Option(id: c.id, title: c.title, done: c.done, date: c.date) }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty {
            let hits = live.filter { $0.title.range(of: needle, options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive]) != nil }
            func distance(_ c: Candidate) -> TimeInterval { c.date.map { abs($0.timeIntervalSince(now)) } ?? .infinity }
            let ordered = hits.sorted { distance($0) < distance($1) }
            return (Array(ordered.filter { !$0.done }.prefix(20)).map(option), Array(ordered.filter(\.done).prefix(10)).map(option))
        }
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -7, to: today),
              let end = calendar.date(byAdding: .day, value: 8, to: today) else { return ([], []) }
        let open = live.filter { c in !c.done && c.date.map { $0 >= start && $0 < end } == true }
            .sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
        let done = live.filter { c in c.done && c.completedAt.map { $0 >= start } == true }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        return (Array(open.prefix(8)).map(option), Array(done.prefix(5)).map(option))
    }
}

/// Picks the task an entry belongs to, with search. An existing link to a deleted task stays shown until changed.
struct TaskLinkPicker: View {
    let tasks: [TaskItem]
    @Binding var taskID: UUID?
    @State private var query = ""

    private var candidates: [TaskLinkOptions.Candidate] {
        tasks.map { .init(id: $0.id, title: $0.title, done: $0.isDone, deleted: $0.deletedAt != nil, date: $0.calendarDate, completedAt: $0.completedAt) }
    }
    private var selectedTitle: String {
        guard let id = taskID else { return L("不关联", "None") }
        guard let task = tasks.first(where: { $0.id == id }) else { return L("原任务已删除", "Original task removed") }
        return task.title + (task.deletedAt != nil ? L("（已删除）", " (deleted)") : "")
    }

    var body: some View {
        let options = TaskLinkOptions.make(candidates, query: query)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(selectedTitle, systemImage: taskID == nil ? "circle.dashed" : "checklist")
                    .font(.callout).lineLimit(1)
                    .foregroundStyle(taskID == nil ? Color.secondary : .primary)
                Spacer(minLength: 8)
                if taskID != nil { Button(L("不关联", "Unlink")) { taskID = nil }.buttonStyle(.borderless).frame(minHeight: 32) }
            }
            TextField(L("搜索任务名称", "Search tasks"), text: $query).textFieldStyle(.roundedBorder)
            if options.open.isEmpty && options.done.isEmpty {
                Text(query.isEmpty ? L("近一周没有任务，输入名称搜索全部任务。", "No tasks this week. Type a name to search all tasks.")
                     : L("没有找到“\(query)”", "No task matches “\(query)”"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            group(query.isEmpty ? L("未完成 · 近期", "Unfinished · this week") : L("未完成", "Unfinished"), options.open)
            group(query.isEmpty ? L("最近完成", "Recently completed") : L("已完成", "Completed"), options.done)
        }
    }

    @ViewBuilder private func group(_ title: String, _ options: [TaskLinkOptions.Option]) -> some View {
        if !options.isEmpty {
            Text(title).font(.caption).foregroundStyle(.secondary).padding(.top, 2)
            ForEach(options) { option in
                Button { taskID = option.id } label: {
                    HStack(spacing: 8) {
                        Image(systemName: option.done ? "checkmark.circle" : "circle").foregroundStyle(.secondary)
                        Text(option.title).lineLimit(1)
                        Spacer(minLength: 8)
                        if let date = option.date { Text(Dates.label(date, pattern: "M月d日")).font(.caption).foregroundStyle(.secondary) }
                        if option.id == taskID { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                    }
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(option.id == taskID ? .isSelected : [])
            }
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
        // Main categories and subcategories each in their own card, titles above them.
        VStack(alignment: .leading, spacing: 8) {
            Text(L("分类", "Category")).font(.subheadline.weight(.semibold)).padding(.horizontal, 2)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: compact ? (dynamicTypeSize.isAccessibilitySize ? 2 : 4) : 6), spacing: 8) {
                ForEach(roots) { category in categoryButton(category, selected: category.id == selectedRoot) }
                addCategoryButton(parentID: nil)
            }.padding(8).cardSurface()
            if let parent, !children.isEmpty {
                HStack {
                    Text(parent.label + L(" · 子分类", " · subcategories")).font(.subheadline.weight(.semibold))
                    Spacer()
                    Button(L("不细分", "No subcategory")) { categoryID = parent.id }
                        .buttonStyle(CardButtonStyle()).font(.caption).frame(minHeight: 44)
                }.padding(.horizontal, 2).padding(.top, 4)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: compact ? (dynamicTypeSize.isAccessibilitySize ? 2 : 4) : 6), spacing: 8) {
                    ForEach(children) { category in categoryButton(category, selected: category.id == categoryID) }
                    if !parent.archived { addCategoryButton(parentID: parent.id) }
                }.padding(8).cardSurface()
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
                .background(RoundedRectangle(cornerRadius: Design.Radius.medium, style: .continuous).fill(selected ? tint.opacity(0.14) : .clear)).contentShape(Rectangle())
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
