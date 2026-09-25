import SwiftUI

@main
struct NoteTakerApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(state)
        } label: {
            MenuBarLabel()
                .environmentObject(state)
        }

        Window("Meeting Transcript", id: "transcript") {
            TranscriptWindow()
                .environmentObject(state)
        }
        .defaultSize(width: 560, height: 640)
        .windowResizability(.contentMinSize)

        Window(L10n.t("Library", "보관함"), id: "library") {
            LibraryView()
                .environmentObject(state)
        }
        .defaultSize(width: 780, height: 540)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
        }
        .windowResizability(.contentSize)
    }
}

/// The always-mounted menu bar icon. Also the hook where app-wide setup runs,
/// since the label view exists from launch.
struct MenuBarLabel: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: iconName)
            .onAppear {
                state.openWindowAction = { id in openWindow(id: id) }
                state.registerHotKeys()
            }
    }

    private var iconName: String {
        switch state.status {
        case .recording: return "record.circle.fill"
        case .preparing, .stopping, .summarizing: return "waveform.circle.fill"
        case .idle: return "waveform.circle"
        }
    }
}
