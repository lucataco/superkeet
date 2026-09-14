import SwiftUI

enum Theme {
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
    }

    enum Radius {
        static let md: CGFloat = 10
        static let lg: CGFloat = 12
    }

    enum Surface {
        static let fill = Color.primary.opacity(0.04)
    }
}

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
    func cardStyle(padding: CGFloat = Theme.Spacing.md,
                   cornerRadius: CGFloat = Theme.Radius.md) -> some View {
        modifier(CardStyle(padding: padding, cornerRadius: cornerRadius))
    }
}
