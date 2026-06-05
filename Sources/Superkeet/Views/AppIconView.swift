import SwiftUI
import AppKit

/// Renders the app icon consistently across onboarding and settings surfaces.
struct AppIconView: View {
    let size: CGFloat
    let cornerRadius: CGFloat

    init(size: CGFloat = 96, cornerRadius: CGFloat = 20) {
        self.size = size
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        if let appIcon = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage {
            Image(nsImage: appIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .cornerRadius(cornerRadius)
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
    }
}
