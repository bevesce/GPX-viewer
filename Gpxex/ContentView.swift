import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var isDropTargeted = false
    #if os(iOS)
    @State private var selectedDetent: PresentationDetent = .height(80)
    #endif

    var body: some View {
        #if os(macOS)
        NavigationSplitView {
            RouteListView()
                .frame(minWidth: 220, idealWidth: 260)
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 400)
        } detail: {
            ZStack {
                MapView(appState: appState)

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

                VStack {
                    HStack {
                        Spacer()
                        locationButton.padding(10)
                    }
                    Spacer()
                }

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
            .toolbar(.hidden)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .frame(minWidth: 800, minHeight: 550)
        #else
        MapView(appState: appState)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .overlay(alignment: .bottomTrailing) {
                Group {
                    if selectedDetent != .large {
                        Group {
                            if #available(iOS 26, *) {
                                GlassEffectContainer {
                                    locationButton
                                }
                                    .padding(.trailing, 16)
                                .padding(.bottom, locationButtonBottomPadding)
                            } else {
                                locationButton
                            }
                        }
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.75), value: selectedDetent)
            }
            .overlay(alignment: .bottomLeading) {
                if let progress = appState.loadingProgress {
                    ProgressView(value: progress)
                        .frame(width: 160)
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .shadow(radius: 4)
                        .padding(.leading, 10)
                        .padding(.bottom, 8)
                }
            }
            .sheet(isPresented: .constant(true)) {
                RouteListView()
                    .fileImporter(
                        isPresented: $appState.showingFilePicker,
                        allowedContentTypes: [UTType(importedAs: "com.topografix.gpx"), .xml],
                        allowsMultipleSelection: true
                    ) { result in
                        if case .success(let urls) = result {
                            appState.loadURLs(urls)
                        }
                    }
                    .presentationDetents([.height(80), .medium, .large], selection: $selectedDetent)
                    .presentationDragIndicator(.visible)
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    .presentationCornerRadius(20)
                    .interactiveDismissDisabled(true)
            }
        #endif
    }

    #if os(iOS)
    private var locationButtonBottomPadding: CGFloat {
        let H = UIScreen.main.bounds.height
        let margin: CGFloat = 8
        if selectedDetent == .height(80) {
            return 80 + margin
        } else {
            return H * 0.5 + margin
        }
    }
    #endif

    private var locationButton: some View {
        Button(action: {
            NotificationCenter.default.post(name: .zoomToUserLocation, object: nil)
        }) {
            Image(systemName: "location.fill")
                .padding(4)
                .shadow(radius: 3)
            
        }
        #if os(macOS)
        .help("Zoom to current location")
        #else
        .buttonStyle(.plain)
        #endif
    }

    #if os(macOS)
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
    #endif
}

extension Notification.Name {
    static let fitAllRoutes       = Notification.Name("fitAllRoutes")
    static let zoomToRoute        = Notification.Name("zoomToRoute")
    static let scrollToRoute      = Notification.Name("scrollToRoute")
    static let zoomToUserLocation = Notification.Name("zoomToUserLocation")
}
