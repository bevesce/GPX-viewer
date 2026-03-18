import SwiftUI

#if os(macOS)
class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        let gpxURLs = urls.filter { $0.pathExtension.lowercased() == "gpx" }
        guard !gpxURLs.isEmpty else { return }

        if AppState.firstInstanceCreated {
            // App already running — load into the active (key) window's AppState
            if let state = AppStateRegistry.shared.states.last {
                state.loadURLs(gpxURLs)
            }
        } else {
            // Cold launch via "Open With" — skip session restore
            AppLaunchState.shared.openedWithFiles = true
            AppLaunchState.shared.filesToOpen = gpxURLs
        }
    }
}
#endif

@main
struct GpxexApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) var openWindow
    @FocusedObject private var appState: AppState?
    #endif

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
        }
        #if os(macOS)
        .commands {
            SidebarCommands()

            CommandGroup(replacing: .newItem) {
                Button("New Tab") {
                    openWindow(id: "main")
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("Open\u{2026}") {
                    appState?.openFilePicker()
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            // Edit menu additions
            CommandGroup(after: .pasteboard) {
                Divider()

                Button("Open Selected in New Tab") {
                    guard let state = appState else { return }
                    let routes = state.routes.filter { state.selectedRouteIds.contains($0.id) }
                    PendingTabRoutes.shared.enqueue(routes)
                    openWindow(id: "main")
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(appState?.selectedRouteIds.isEmpty ?? true)

                Button("Remove Selected") {
                    appState?.removeSelectedRoutes()
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(appState?.selectedRouteIds.isEmpty ?? true)

                Button("Select All Routes") {
                    if let state = appState {
                        state.selectedRouteIds = Set(state.routes.map { $0.id })
                    }
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(appState?.routes.isEmpty ?? true)

                Button("Remove All Routes") {
                    appState?.routes.removeAll()
                    appState?.selectedRouteIds = []
                    appState?.hoveredRouteId = nil
                    appState?.lastClickedRouteId = nil
                }
                .disabled(appState?.routes.isEmpty ?? true)
            }

            // View menu additions
            CommandGroup(after: .toolbar) {
                Divider()

                Button("Fit All Routes") {
                    if let state = appState {
                        NotificationCenter.default.post(name: .fitAllRoutes, object: state)
                    }
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(appState?.routes.isEmpty ?? true)
            }
        }
        #endif
    }
}
