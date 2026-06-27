import SwiftUI

/// Main settings window. Uses a `NavigationSplitView` so the sidebar inherits
/// the system's translucent (Liquid Glass) material and selection styling on
/// macOS 26 while degrading gracefully on macOS 14.
struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .home

    enum SettingsTab: String, CaseIterable, Identifiable {
        case home = "General"
        case output = "Output & Privacy"
        case recording = "Advanced"
        case about = "About"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .home: return "gearshape"
            case .output: return "arrow.right.doc.on.clipboard"
            case .recording: return "slider.horizontal.3"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.icon)
                    .tag(tab)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 220, max: 260)
            .safeAreaInset(edge: .top, spacing: 0) { sidebarHeader }
            .safeAreaInset(edge: .bottom, spacing: 0) { sidebarFooter }
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, idealWidth: 800, minHeight: 540, idealHeight: 620)
    }

    @ViewBuilder
    private var detail: some View {
        switch selectedTab {
        case .home:
            HomeTabView()
        case .recording:
            RecordingTabView()
        case .output:
            OutputTabView()
        case .about:
            AboutTabView()
        }
    }

    private var sidebarHeader: some View {
        HStack(spacing: 8) {
            AppIconView(size: 24, cornerRadius: 6)
            Text("Superkeet")
                .font(.headline)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            Text("Version \(Self.appVersion)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}

// MARK: - Shared tab header

/// Large title + subtitle shown at the top of each settings detail pane,
/// matching the native macOS Settings layout above grouped form sections.
struct SettingsTabHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.largeTitle.weight(.bold))
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 2)
    }
}
