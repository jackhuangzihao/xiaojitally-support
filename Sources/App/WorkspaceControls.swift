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
struct PhoneSearchToolbar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), UIDevice.current.userInterfaceIdiom == .phone {
            content.searchToolbarBehavior(.minimize)
        } else { content }
    }
}
#endif
