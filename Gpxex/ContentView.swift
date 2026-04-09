import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

struct ContentView: View {
    @StateObject private var appState = AppState()
    @State private var isDropTargeted = false
    @State private var searchText = ""
    #if os(iOS)
    @State private var selectedDetent: PresentationDetent = .height(80)
    #endif

    #if os(macOS)
    @Environment(\.openWindow) var openWindow

    private var windowTitle: String {
        switch appState.routes.count {
        case 0: return "Gpxex"
        case 1: return appState.routes[0].fileName
        default: return "\(appState.routes.count) routes"
        }
    }
    #endif

    var body: some View {
        mainContent
            .environmentObject(appState)
            #if os(macOS)
            .focusedSceneObject(appState)
            .background(WindowConfigurator(title: windowTitle))
            .onAppear {
                if appState.fitOnAppear {
                    appState.fitOnAppear = false
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .fitAllRoutes, object: appState)
                    }
                }
                // Restore additional session tabs (only runs once, for the first window)
                let extraTabs = PendingTabRoutes.shared.pendingURLTabCount
                if extraTabs > 0 {
                    for _ in 0..<extraTabs {
                        openWindow(id: "main")
                    }
                }
            }
            #endif
    }

    private var mainContent: some View {
        #if os(macOS)
        NavigationSplitView {
            RouteListView(searchText: $searchText)
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
                        iOSMapControls
                            .padding(.trailing, 16)
                            .padding(.bottom, locationButtonBottomPadding)
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.75), value: selectedDetent)
            }
            .overlay(alignment: .bottomLeading) {
                Group {
                    if selectedDetent != .large {
                        Group {
                            if #available(iOS 26, *) {
                                GlassEffectContainer {
                                    openFilesButton
                                }
                            } else {
                                openFilesButton
                            }
                        }
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                }
                .padding(.leading, 16)
                .padding(.bottom, locationButtonBottomPadding)
                .animation(.spring(response: 0.4, dampingFraction: 0.75), value: selectedDetent)
            }
            .sheet(isPresented: .constant(true)) {
                RouteListView(searchText: $searchText, selectedDetent: $selectedDetent)
                    .onChange(of: searchText) { _, newValue in
                        if !newValue.isEmpty { selectedDetent = .large }
                    }
                .fileImporter(
                    isPresented: $appState.showingFilePicker,
                    allowedContentTypes: [UTType(importedAs: "com.topografix.gpx"), .xml],
                    allowsMultipleSelection: true
                ) { result in
                    if case .success(let urls) = result {
                        appState.loadURLs(urls)
                    }
                }
                .sheet(isPresented: $appState.showingFolderPicker) {
                    FolderPicker { url in
                        appState.showingFolderPicker = false
                        if let url { appState.loadFolder(url) }
                    }
                    .ignoresSafeArea()
                }
                .sheet(item: $appState.longPressedRoute) { route in
                    RouteDetailSheet(route: route)
                        .environmentObject(appState)
                        .presentationDetents([.height(200)])
                        .presentationDragIndicator(.visible)
                        .presentationBackground(.ultraThinMaterial)
                        .presentationCornerRadius(20)
                }
                .presentationDetents([.height(80), .medium, .large], selection: $selectedDetent)
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationBackground(.ultraThinMaterial)
                .presentationCornerRadius(20)
                .interactiveDismissDisabled(true)
            }
        #endif
    }

    #if os(iOS)
    private var locationButtonBottomPadding: CGFloat {
        let H = UIScreen.main.bounds.height
        // iOS 26 glass sheet gives enough visual separation with a negative margin;
        // on iOS 18 the opaque sheet overlaps buttons, so push them above the sheet edge.
        let margin: CGFloat = if #available(iOS 26, *) { -8 } else { 16 }
        if selectedDetent == .height(80) {
            return 80 + margin
        } else {
            return H * 0.5 + margin
        }
    }
    #endif

    private var locationButton: some View {
        Button(action: {
            NotificationCenter.default.post(name: .zoomToUserLocation, object: appState)
        }) {
            Image(systemName: "location.fill")
                .padding(4)
                .shadow(radius: 3)
        }
        .help("Zoom to current location")
    }

    #if os(iOS)
    private var iOSMapControls: some View {
        VStack(spacing: 0) {
            Button(action: {
                NotificationCenter.default.post(name: .fitAllRoutes, object: appState)
            }) {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .frame(width: 24, height: 24)
                    .padding(8)
            }
            .buttonStyle(.plain)
            .disabled(appState.routes.isEmpty)

            Divider()

            Button(action: {
                NotificationCenter.default.post(name: .zoomToUserLocation, object: appState)
            }) {
                Image(systemName: "location.fill")
                    .frame(width: 24, height: 24)
                    .padding(8)
            }
            .buttonStyle(.plain)
        }
        .fixedSize()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var openFilesButton: some View {
        Menu {
            Button(action: { appState.openFilePicker() }) {
                Label("Add Files…", systemImage: "doc.badge.plus")
            }
            Button(action: { appState.showingFolderPicker = true }) {
                Label("Add Folder…", systemImage: "folder.badge.plus")
            }
            if !appState.routes.isEmpty {
                Divider()
                Button(role: .destructive, action: { appState.removeAllRoutes() }) {
                    Label("Clear All", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "plus")
                .frame(width: 24, height: 24)
                .padding(8)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
    #endif

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

#if os(macOS)
/// Handles two jobs for each ContentView window:
/// - makeNSView: attaches the new window as a tab after the currently selected
///   tab (if any other content window is open).
/// - updateNSView: keeps the window/tab title in sync with the route list.
private struct WindowConfigurator: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let newWindow = view.window else { return }
            newWindow.tabbingMode = .preferred
            let existing = NSApp.windows.first {
                $0 !== newWindow && $0.isVisible
                    && !($0 is NSPanel)
                    && $0.contentViewController != nil
            }
            if let existing {
                let insertAfter = existing.tabGroup?.selectedWindow ?? existing
                insertAfter.addTabbedWindow(newWindow, ordered: .above)
                newWindow.makeKeyAndOrderFront(nil)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Defer so we run after SwiftUI's own NavigationSplitView title pass.
        // Also set tab.title, which controls the tab strip label independently
        // from the title bar (and is not touched by SwiftUI).
        let t = title
        DispatchQueue.main.async {
            nsView.window?.title = t
            nsView.window?.tab.title = t
        }
    }
}
#endif

extension Notification.Name {
    static let fitAllRoutes       = Notification.Name("fitAllRoutes")
    static let zoomToRoute        = Notification.Name("zoomToRoute")
    static let zoomToRoutes       = Notification.Name("zoomToRoutes")
    static let scrollToRoute      = Notification.Name("scrollToRoute")
    static let zoomToUserLocation = Notification.Name("zoomToUserLocation")
}

#if os(iOS)
/// Wraps UIDocumentPickerViewController for folder selection from iCloud Drive and local storage.
struct FolderPicker: UIViewControllerRepresentable {
    let onFinish: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFinish: (URL?) -> Void
        init(onFinish: @escaping (URL?) -> Void) { self.onFinish = onFinish }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onFinish(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onFinish(nil)
        }
    }
}
#endif
