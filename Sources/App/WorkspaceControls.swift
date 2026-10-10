import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Charts
#if os(iOS)
import UIKit
#endif

struct AppSectionPicker: View {
    @AppStorage("appLanguage") private var language = "system"
    @Binding var finance: Bool
    var body: some View {
        // A full-width switch with icons, so it reads as the top-level choice it is. The system segmented
        // control keeps its own width and drops icons on macOS, so the two halves are drawn here.
        HStack(spacing: 2) {
            segment(L("待办", "Tasks"), symbol: "checklist", value: false)
            segment(L("财务", "Finance"), symbol: "wallet.pass", value: true)
        }
        .padding(3)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: Design.Radius.medium, style: .continuous))
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain).accessibilityLabel(L("功能", "Workspace"))
    }

    private func segment(_ title: String, symbol: String, value: Bool) -> some View {
        let selected = finance == value
        return Button { finance = value } label: {
            Label(title, systemImage: symbol)
                .font(.callout.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.primary : .secondary)
                .frame(maxWidth: .infinity, minHeight: 26)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: Design.Radius.medium - 3, style: .continuous).fill(Color.cardBackground)
                            .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

#if os(iOS)
/// Keep search presentation local to the visible page. The automatically minimized
/// iOS toolbar search controller can retain focus after a tab/page has disappeared.
struct PhoneWorkspaceToolbar<Scope: Hashable>: ViewModifier {
    @Binding var text: String
    let prompt: String
    let scope: Scope
    var enabled = true
    let settings: () -> Void
    let add: () -> Void
    let addLabel: String
    var canAdd = true
    @State private var presented = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(action: settings) { Label(L("设置", "Settings"), systemImage: "gearshape") }
                    Button(action: add) { Label(addLabel, systemImage: "plus") }
                        .keyboardShortcut("n", modifiers: .command).disabled(!canAdd)
                    if enabled {
                        Button {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { presented.toggle() }
                            if !presented { close() }
                        } label: { Label(L("搜索", "Search"), systemImage: "magnifyingglass") }
                        .keyboardShortcut("f", modifiers: .command)
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if presented && enabled {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(prompt, text: $text)
                            .focused($focused)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .submitLabel(.search).onSubmit { focused = false }
                            .task {
                                guard presented && enabled && !Task.isCancelled else { return }
                                focused = true
                            }
                        Button {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { close() }
                        } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                            .accessibilityLabel(L("关闭搜索", "Close search"))
                    }
                    .padding(.leading, 12).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .background(Color.appBackground)
                    .transition(.opacity)
                }
            }
            .onChange(of: enabled) { _, value in if !value { close() } }
            .onChange(of: scope) { _, _ in close() }
            .onDisappear { close() }
    }

    private func close() {
        focused = false
        presented = false
        text = ""
    }
}
#endif
