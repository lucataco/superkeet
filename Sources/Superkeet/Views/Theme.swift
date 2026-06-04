import SwiftUI

/// Centralized design tokens so cards, spacing, and surfaces stay consistent
/// across every view. Prefer these over inline `Color.primary.opacity(...)`
/// and ad-hoc corner radii.
enum Theme {
    // MARK: Spacing
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    // MARK: Corner radius
    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 10
        static let lg: CGFloat = 12
    }

    // MARK: Surfaces
    enum Surface {
        /// Subtle filled card background.
        static let fill = Color.primary.opacity(0.04)
        /// Slightly stronger fill (e.g. badges, search field).
        static let fillStrong = Color.primary.opacity(0.08)
        /// Hairline border for cards.
        static let border = Color.primary.opacity(0.08)
    }
}

// MARK: - Card style

private struct CardStyle: ViewModifier {
    var padding: CGFloat = Theme.Spacing.md
    var cornerRadius: CGFloat = Theme.Radius.md

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.Surface.fill)
            .cornerRadius(cornerRadius)
    }
}

extension View {
    /// Applies the standard Superkeet card surface (fill + corner radius).
    func cardStyle(padding: CGFloat = Theme.Spacing.md,
                   cornerRadius: CGFloat = Theme.Radius.md) -> some View {
        modifier(CardStyle(padding: padding, cornerRadius: cornerRadius))
    }
}
