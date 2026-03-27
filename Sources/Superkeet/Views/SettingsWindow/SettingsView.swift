import SwiftUI

/// Main settings window with vertical sidebar tabs
struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .home

    enum SettingsTab: String, CaseIterable, Identifiable {
        case home = "Setup"
        case output = "Output & Privacy"
        case recording = "Advanced"
        case about = "About"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .home: return "checklist"
            case .recording: return "slider.horizontal.3"
            case .output: return "text.cursor"
            case .about: return "info.circle.fill"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            // Sidebar
            List(SettingsTab.allCases, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.icon)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 200)
        } detail: {
            // Content
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
        .frame(minWidth: 550, idealWidth: 650, minHeight: 400, idealHeight: 480)
    }
}
