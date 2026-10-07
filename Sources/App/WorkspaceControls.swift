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
        Picker(L("功能", "Workspace"), selection: $finance) {
            Text(L("待办", "Tasks")).tag(false)
            Text(L("财务", "Finance")).tag(true)
        }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 14)
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
