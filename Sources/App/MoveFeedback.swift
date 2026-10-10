import SwiftUI

struct MoveFeedback: View {
    let message: String
    let canUndo: Bool
    let canShiftDeadline: Bool
    let shiftDeadline: () -> Void
    let undo: () -> Void
    let dismiss: () -> Void
    /// An extra button, such as posting a completed task's pending entries.
    var action: (title: String, run: () -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var touchSize: CGFloat {
        #if os(iOS)
        44
        #else
        24
        #endif
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            if !dynamicTypeSize.isAccessibilitySize {
                HStack(spacing: 10) {
                    Text(message).lineLimit(2)
                    actions
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(message).fixedSize(horizontal: false, vertical: true)
                actions
            }
        }.font(.caption).padding(.horizontal, 10).padding(.vertical, 2)
            .background(Color.appBackground, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.16)))
            .task(id: message) {
                do {
                    try await Task.sleep(for: .seconds(dynamicTypeSize.isAccessibilitySize ? 10 : canUndo || canShiftDeadline || action != nil ? 6 : 3))
                    dismiss()
                } catch {}
            }
    }
    private var actions: some View {
        HStack(spacing: 8) {
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(.borderless).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: touchSize)
            }
            if canShiftDeadline {
                Button(L("截止也一起移", "Move deadline too"), action: shiftDeadline)
                    .buttonStyle(.borderless).fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: touchSize)
            }
            if canUndo { Button(action: undo) { Text(L("撤销", "Undo")).frame(minWidth: touchSize, minHeight: touchSize) }.buttonStyle(.borderless) }
            Button(action: dismiss) { Image(systemName: "xmark").frame(width: touchSize, height: touchSize) }
                .buttonStyle(.plain).accessibilityLabel(L("关闭提示", "Dismiss message"))
        }
    }
}
