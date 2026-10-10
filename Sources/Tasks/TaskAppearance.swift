import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Observation
#if os(iOS)
import UIKit
#endif

struct CalendarPriorityMark: View {
    @Environment(\.locale) private var locale
    let priority: Int
    var isDone = false
    var body: some View {
        if priority > 0 {
            // The same light tag as elsewhere: red text for high, orange for medium.
            let tint: Color = isDone ? .secondary : priority == 2 ? .red : .orange
            Text(priority == 2 ? L("高", "H") : L("中", "M"))
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 4).frame(height: 14)
                .foregroundStyle(tint)
                .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
                .fixedSize()
                .accessibilityLabel(priority == 2 ? L("高优先级", "High priority") : L("中优先级", "Medium priority"))
        }
    }
}

// One palette for calendar blocks, sidebar icons and list selectors.
enum ListColor {
    static let presets: [(hex: String, zh: String, en: String)] = [
        ("799B80", "鼠尾草绿", "Sage"), ("409870", "森林绿", "Forest"), ("39A99B", "薄荷绿", "Mint"),
        ("3F9FBF", "湖蓝", "Lake"), ("5287CE", "蓝色", "Blue"), ("6571C5", "靛蓝", "Indigo"),
        ("9373C5", "紫色", "Purple"), ("B17AC3", "薰衣草紫", "Lavender"), ("C578AC", "玫瑰紫", "Rose"),
        ("D77690", "粉色", "Pink"), ("D46B65", "珊瑚红", "Coral"), ("BE565C", "红色", "Red"),
        ("D88951", "橙色", "Orange"), ("BD943F", "琥珀色", "Amber"), ("B5A44C", "金黄色", "Gold"),
        ("8C9C51", "橄榄绿", "Olive"), ("A0826E", "棕色", "Brown"), ("7C8C9C", "蓝灰色", "Slate"),
        ("28786A", "扩展色 1", "Extended 1"),
        ("21689B", "扩展色 2", "Extended 2"),
        ("334BA1", "扩展色 3", "Extended 3"),
        ("6646A5", "扩展色 4", "Extended 4"),
        ("953E92", "扩展色 5", "Extended 5"),
        ("AE4770", "扩展色 6", "Extended 6"),
        ("A74432", "扩展色 7", "Extended 7"),
        ("A56829", "扩展色 8", "Extended 8"),
        ("837A27", "扩展色 9", "Extended 9"),
        ("557C36", "扩展色 10", "Extended 10"),
        ("476D55", "扩展色 11", "Extended 11"),
        ("55636D", "扩展色 12", "Extended 12"),
        ("50B89C", "扩展色 13", "Extended 13"),
        ("57B6CF", "扩展色 14", "Extended 14"),
        ("779BE0", "扩展色 15", "Extended 15"),
        ("8C83D7", "扩展色 16", "Extended 16"),
        ("B493D8", "扩展色 17", "Extended 17"),
        ("D897BD", "扩展色 18", "Extended 18"),
        ("E5A07D", "扩展色 19", "Extended 19"),
        ("DDB869", "扩展色 20", "Extended 20"),
        ("B8C66E", "扩展色 21", "Extended 21"),
        ("87B4A4", "扩展色 22", "Extended 22"),
        ("A5AFBF", "扩展色 23", "Extended 23"),
        ("A9A0BB", "扩展色 24", "Extended 24"),
        ("3E5650", "扩展色 25", "Extended 25"),
        ("354E69", "扩展色 26", "Extended 26"),
        ("514467", "扩展色 27", "Extended 27"),
        ("764B62", "扩展色 28", "Extended 28"),
        ("775345", "扩展色 29", "Extended 29"),
        ("746C4A", "扩展色 30", "Extended 30")
    ]
    static func available(used: Set<String>) -> String {
        if let first = presets.first(where: { !used.contains($0.hex) }) { return first.hex }
        // Additional deterministic colors keep allocation possible after the fixed palette is used up.
        for index in 0...0xFFFFFF {
            let value = String(format: "%06X", (index &* 7919 &+ 0x527F96) & 0xFFFFFF)
            if !used.contains(value) { return value }
        }
        return "799B80"
    }
    static func normalize(_ lists: [TaskList]) {
        var reserved = Set(lists.compactMap { $0.colorHex?.uppercased() }.filter(TaskList.validColor))
        var seen = Set<String>()
        for list in lists.sorted(by: { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }) {
            if let color = list.colorHex?.uppercased(), TaskList.validColor(color), seen.insert(color).inserted { continue }
            let color = available(used: reserved)
            list.colorHex = color; reserved.insert(color); seen.insert(color)
        }
    }

    static func color(_ id: UUID?, hex: String? = nil) -> Color {
        if let hex, TaskList.validColor(hex), let rgb = UInt32(hex, radix: 16) {
            return Color(.sRGB, red: Double((rgb >> 16) & 255) / 255,
                         green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, opacity: 1)
        }
        guard let id else { return .secondary }
        let palette: [Color] = [.accentColor, .blue, .purple, .orange, .teal, .pink]
        let index = id.uuidString.utf8.reduce(0) { ($0 * 31 + Int($1)) % palette.count }
        return palette[index]
    }
}

struct ColoredListLabel: View {
    let name: String
    let id: UUID
    var colorHex: String? = nil
    var emoji: String? = nil
    var isGroup = false
    var body: some View {
        Label {
            Text(name)
        } icon: {
            if let emoji { Text(emoji) }
            else { Image(systemName: isGroup ? "folder.fill" : "list.bullet.rectangle").foregroundStyle(ListColor.color(id, hex: colorHex)) }
        }
    }
}

extension DeadlineCountdown {
    var color: Color {
        switch level {
        case .normal: .secondary
        case .soon, .today: .orange
        case .overdue: .red
        }
    }
}

extension Color {
    static var appBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
    static let selectedInk = Color("SelectedInk")
}


/// Hover state kept inside one row.
struct RowHover<Content: View>: View {
    @State private var hovering = false
    @ViewBuilder let content: (Bool) -> Content
    var body: some View {
        content(hovering).onHover { inside in if inside != hovering { hovering = inside } }
    }
}

struct ListTreeMenu: View {
    let nodes: [ListNode]
    let select: (UUID) -> Void
    var body: some View {
        ForEach(nodes) { node in
            if let children = node.children {
                Menu {
                    Button(L("查看此组全部任务", "View all tasks in group")) { select(node.id) }
                    ListTreeMenu(nodes: children, select: select)
                } label: {
                    ColoredListLabel(name: node.list.name, id: node.id, colorHex: node.list.colorHex, emoji: node.list.emoji, isGroup: true)
                }
            } else {
                Button { select(node.id) } label: { ColoredListLabel(name: node.list.name, id: node.id, colorHex: node.list.colorHex, emoji: node.list.emoji) }
            }
        }
    }
}
