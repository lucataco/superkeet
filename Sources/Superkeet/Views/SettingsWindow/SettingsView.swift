import SwiftUI

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .home

    enum SettingsTab: String, CaseIterable, Identifiable {
        case home = "General"
        case output = "Output & Privacy"
        case actions = "Actions"
        case recording = "Advanced"
        case about = "About"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .home: return "gearshape"
            case .output: return "arrow.right.doc.on.clipboard"
            case .actions: return "wand.and.stars"
            case .recording: return "slider.horizontal.3"
            case .about: return "info.circle"
            }
        }
    }

    /// Actions Mode cannot work below macOS 26, so do not advertise a tab full of dead controls.
    private var visibleTabs: [SettingsTab] {
        SettingsTab.allCases.filter { $0 != .actions || AppleIntelligenceAvailability.osSupportsActionsMode }
    }

    var body: some View {
        NavigationSplitView {
            List(visibleTabs, selection: $selectedTab) { tab in
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
        case .actions:
            ActionsTabView()
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
            Text("Version \(AppVersion.current.shortVersion)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
    }

}

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
