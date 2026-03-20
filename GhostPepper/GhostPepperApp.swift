import SwiftUI

@main
struct GhostPepperApp: App {
    @StateObject private var appState = AppState()
    @State private var hasInitialized = false

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState)
                .task {
                    guard !hasInitialized else { return }
                    hasInitialized = true
                    await appState.initialize()
                }
        } label: {
            Image(systemName: menuBarIconName)
                .symbolRenderingMode(.palette)
                .foregroundStyle(menuBarIconColor)
        }
    }

    private var menuBarIconName: String {
        switch appState.status {
        case .loading:
            return "arrow.down.circle"
        case .recording:
            return "waveform.circle.fill"
        case .error:
            return "exclamationmark.triangle"
        default:
            return "waveform"
        }
    }

    private var menuBarIconColor: Color {
        switch appState.status {
        case .loading: return .orange
        case .recording: return .red
        case .error: return .yellow
        default: return .primary
        }
    }
}
