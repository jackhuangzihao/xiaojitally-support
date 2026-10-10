import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Shared spacing, corner radii, surfaces and text roles, so pages polished at different times look like one app.
/// Pages adopt these one at a time; nothing here changes behaviour.
enum Design {
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }
    enum Radius {
        /// Tags and small badges.
        static let small: CGFloat = 6
        /// Buttons, fields and rows inside a card.
        static let medium: CGFloat = 10
        /// Cards.
        static let large: CGFloat = 14
    }
}

extension Font {
    /// The single number a summary is about.
    #if os(macOS)
    static let heroAmount = Font.system(size: 34, weight: .semibold).monospacedDigit()
    #else
    static let heroAmount = Font.largeTitle.weight(.semibold).monospacedDigit()
    #endif
    /// Secondary figures beside the hero amount.
    static let figure = Font.title3.weight(.semibold).monospacedDigit()
    /// Amounts at the end of a row.
    static let rowAmount = Font.body.weight(.semibold).monospacedDigit()
}

extension Color {
    /// A card raised above the window: white in light mode, a step lighter than the window in dark mode.
    static let cardBackground: Color = {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.165, alpha: 1) : .white
        })
        #else
        // A phone page is white in light mode, so cards there are the grouped grey; in dark mode a step above black.
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? .secondarySystemGroupedBackground : .secondarySystemBackground
        })
        #endif
    }()
}

/// The background of one row in a run of rows that reads as a single card. Only the first and last rows are
/// rounded, so a long lazy list keeps loading row by row instead of being wrapped in one container.
struct CardRowBackground: View {
    let first: Bool
    let last: Bool

    var body: some View {
        UnevenRoundedRectangle(topLeadingRadius: first ? Design.Radius.large : 0, bottomLeadingRadius: last ? Design.Radius.large : 0,
                               bottomTrailingRadius: last ? Design.Radius.large : 0, topTrailingRadius: first ? Design.Radius.large : 0,
                               style: .continuous)
            .fill(Color.cardBackground)
    }
}

/// A card: its own background, a hairline edge so it stays visible in dark mode, and a soft shadow in light mode.
struct CardSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Design.Radius.large, style: .continuous)
        content
            .background(shape.fill(Color.cardBackground))
            .overlay(shape.strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05)))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.05), radius: 6, y: 2)
    }
}

/// One look for every small label: repeat rules, statuses, linked tasks.
struct TagStyle: ViewModifier {
    let tint: Color
    var weight: Font.Weight = .semibold

    func body(content: Content) -> some View {
        content
            .font(.caption2.weight(weight)).lineLimit(1)
            .foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous))
    }
}

/// A small tinted button for the main action of a row, such as confirming an entry.
struct RowActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.22 : 0.13),
                        in: RoundedRectangle(cornerRadius: Design.Radius.medium - 2, style: .continuous))
            .contentShape(Rectangle())
    }
}

extension View {
    func cardSurface() -> some View { modifier(CardSurface()) }
    func tagStyle(_ tint: Color, weight: Font.Weight = .semibold) -> some View { modifier(TagStyle(tint: tint, weight: weight)) }
}
