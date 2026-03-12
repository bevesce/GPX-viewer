import SwiftUI

@main
struct GPXViewerApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    appState.openFilePicker()
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            CommandMenu("Routes") {
                Button("Fit All Routes") {
                    NotificationCenter.default.post(name: .fitAllRoutes, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(appState.routes.isEmpty)

                Divider()

                Button("Remove All Routes") {
                    appState.routes.removeAll()
                    appState.selectedRouteId = nil
                    appState.hoveredRouteId = nil
                }
                .disabled(appState.routes.isEmpty)
            }
        }
    }
}
