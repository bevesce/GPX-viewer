import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var isDropTargeted = false

    var body: some View {
        NavigationSplitView {
            RouteListView()
                .frame(minWidth: 220, idealWidth: 260)
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 400)
        } detail: {
            ZStack {
                MapView(appState: appState)

                // Drop overlay indicator
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.accentColor, lineWidth: 3)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.accentColor.opacity(0.08))
                        )
                        .padding(8)
                        .overlay(
                            VStack(spacing: 8) {
                                Image(systemName: "arrow.down.doc")
                                    .font(.system(size: 40))
                                Text("Drop GPX files")
                                    .font(.headline)
                            }
                            .foregroundColor(.accentColor)
                        )
                }

                // Map toolbar — top-right
                VStack {
                    HStack {
                        Spacer()
                        mapToolbar
                            .padding(10)
                    }
                    Spacer()
                }

                // Loading progress overlay (bottom-left)
                if let progress = appState.loadingProgress {
                    VStack {
                        Spacer()
                        HStack {
                            ProgressView(value: progress)
                                .frame(width: 160)
                            .padding(8)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .shadow(radius: 4)
                            .padding(10)
                            Spacer()
                        }
                    }
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .frame(minWidth: 800, minHeight: 550)
    }

    private var mapToolbar: some View {
        Button(action: {
            NotificationCenter.default.post(name: .zoomToUserLocation, object: nil)
        }) {
            Image(systemName: "location.fill")
                .font(.system(size: 12))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Zoom to current location")
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 4)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                } else if let str = item as? String {
                    url = URL(string: str)
                }
                if let url {
                    DispatchQueue.main.async {
                        self.appState.loadURLs([url])
                    }
                }
            }
        }
        return true
    }
}

extension Notification.Name {
    static let fitAllRoutes      = Notification.Name("fitAllRoutes")
    static let zoomToRoute       = Notification.Name("zoomToRoute")
    static let scrollToRoute     = Notification.Name("scrollToRoute")
    static let zoomToUserLocation = Notification.Name("zoomToUserLocation")
}
