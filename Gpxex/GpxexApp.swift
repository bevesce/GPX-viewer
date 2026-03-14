import SwiftUI

@main
struct GpxexApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open\u{2026}") {
                    appState.openFilePicker()
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            // Edit menu additions
            CommandGroup(after: .pasteboard) {
                Divider()

                Button("Remove Selected") {
                    appState.removeSelectedRoutes()
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(appState.selectedRouteIds.isEmpty)

                Button("Remove All Routes") {
                    appState.routes.removeAll()
                    appState.selectedRouteIds = []
                    appState.hoveredRouteId = nil
                    appState.lastClickedRouteId = nil
                }
                .disabled(appState.routes.isEmpty)
            }

            // View menu additions
            CommandGroup(after: .toolbar) {
                Divider()

                Button("Fit All Routes") {
                    NotificationCenter.default.post(name: .fitAllRoutes, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(appState.routes.isEmpty)
            }
        }
    }
}
