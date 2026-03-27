import Foundation
#if os(macOS)
import AppKit
#endif
import Combine

class AppState: ObservableObject {
    @Published var routes: [GPXRoute] = []
    @Published var selectedRouteIds: Set<UUID> = []
    @Published var hoveredRouteId: UUID? = nil
    @Published var loadingProgress: Double? = nil  // nil = idle, 0–1 = loading
    @Published var distanceFilterLow: Double = 0
    @Published var distanceFilterHigh: Double = 0

    var maxRouteDistance: Double { routes.map(\.totalDistance).max() ?? 0 }

    var filteredRouteIds: Set<UUID> {
        let maxDist = maxRouteDistance
        guard maxDist > 0, distanceFilterLow > 1 || distanceFilterHigh < maxDist - 1 else {
            return Set(routes.map(\.id))
        }
        return Set(routes.filter {
            $0.totalDistance >= distanceFilterLow && $0.totalDistance <= distanceFilterHigh
        }.map(\.id))
    }
    #if !os(macOS)
    @Published var showingFilePicker = false
    #endif

    // Anchor for shift-click range selection — not published (no re-render needed)
    var lastClickedRouteId: UUID? = nil

    private let loadQueue = DispatchQueue(label: "gpx.load", qos: .userInitiated)
    #if !os(macOS)
    // macOS session is stored in "savedSessionTabs" ([[String]]) by persistRouteURLs()
    // iOS still uses per-file security-scoped bookmarks
    private static let savedBookmarksKey = "savedRouteBookmarks"
    #endif

    // Only the first AppState ever created restores routes from UserDefaults.
    // Subsequent instances (new tabs) start empty unless given pending routes.
    static var firstInstanceCreated = false

    // Set to true when the instance is pre-loaded with routes (new tab from selection).
    // ContentView reads this once on appear to trigger a fit, then clears it.
    var fitOnAppear = false

    init() {
        AppStateRegistry.shared.register(self)

        // Path 1: new tab opened from selection (routes already parsed)
        if let pending = PendingTabRoutes.shared.dequeue() {
            routes = pending
            fitOnAppear = true
            return
        }

        // Path 2: session restore for non-first tab
        if let pendingURLs = PendingTabRoutes.shared.dequeueURLs() {
            loadURLs(pendingURLs)
            fitOnAppear = true
            return
        }

        guard !AppState.firstInstanceCreated else { return }
        AppState.firstInstanceCreated = true

        #if os(macOS)
        // If launched via "Open With", load those files instead of restoring session
        if AppLaunchState.shared.openedWithFiles {
            let urls = AppLaunchState.shared.filesToOpen
            AppLaunchState.shared.filesToOpen = []
            if !urls.isEmpty { loadURLs(urls) }
            return
        }
        // Restore saved session: first tab loads directly; remaining tabs are enqueued
        if let tabArrays = UserDefaults.standard.array(forKey: "savedSessionTabs") as? [[String]] {
            let allTabURLs = tabArrays.map { $0.compactMap { URL(string: $0) } }
            if let firstTab = allTabURLs.first, !firstTab.isEmpty {
                loadURLs(firstTab)
            }
            for tab in allTabURLs.dropFirst() where !tab.isEmpty {
                PendingTabRoutes.shared.enqueueURLs(tab)
            }
        }
        #else
        let dataArray = UserDefaults.standard.array(forKey: Self.savedBookmarksKey) as? [Data] ?? []
        let resolved = dataArray.compactMap { data -> URL? in
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: .withoutUI,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { return nil }
            return url
        }
        if !resolved.isEmpty { loadURLs(resolved) }
        #endif
    }

    deinit {
        AppStateRegistry.shared.unregister(self)
    }

    #if os(macOS)
    private func persistRouteURLs() {
        // Save the full session (all tabs) so every write is complete
        let allTabs = AppStateRegistry.shared.states.map { state in
            state.routes.map { $0.fileURL.absoluteString }
        }
        UserDefaults.standard.set(allTabs, forKey: "savedSessionTabs")
    }
    #else
    private func persistRouteBookmarks() {
        let bookmarks = routes.compactMap { route -> Data? in
            _ = route.fileURL.startAccessingSecurityScopedResource()
            defer { route.fileURL.stopAccessingSecurityScopedResource() }
            return try? route.fileURL.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        UserDefaults.standard.set(bookmarks, forKey: Self.savedBookmarksKey)
    }
    #endif

    func loadURLs(_ urls: [URL]) {
        // Snapshot on main thread before going to background
        let existingURLs = Set(routes.map { $0.fileURL })
        let initialColorIndex = routes.count

        loadQueue.async { [weak self] in
            guard let self else { return }

            // Collect all GPX file URLs
            var allURLs: [URL] = []
            for url in urls {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    if let contents = try? FileManager.default.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles]
                    ) {
                        allURLs += contents
                            .filter { $0.pathExtension.lowercased() == "gpx" }
                            .sorted { $0.lastPathComponent < $1.lastPathComponent }
                    }
                } else if url.pathExtension.lowercased() == "gpx" {
                    allURLs.append(url)
                }
            }

            let newURLs = allURLs.filter { !existingURLs.contains($0) }
            guard !newURLs.isEmpty else { return }

            let totalCount = newURLs.count
            DispatchQueue.main.async { [weak self] in self?.loadingProgress = 0.0 }

            // Parse all files concurrently; results keyed by original index to preserve order
            var results = [Int: GPXRoute]()
            var completed = 0
            var lastReportedFraction = 0.0
            let lock = NSLock()

            #if !os(macOS)
            // Start security-scoped access for all URLs before concurrent reading
            for url in newURLs { _ = url.startAccessingSecurityScopedResource() }
            defer { newURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
            #endif

            DispatchQueue.concurrentPerform(iterations: totalCount) { i in
                let url = newURLs[i]
                var route: GPXRoute? = nil
                if let parsed = GPXParser.cachedParse(url: url) {
                    route = GPXRoute(
                        fileName: url.deletingPathExtension().lastPathComponent,
                        coordinates: parsed.coordinates,
                        simplified: parsed.simplified,
                        colorIndex: initialColorIndex + i,
                        fileURL: url,
                        startTime: parsed.startTime,
                        endTime: parsed.endTime,
                        totalDistance: parsed.totalDistance
                    )
                }

                lock.lock()
                if let route { results[i] = route }
                completed += 1
                let fraction = Double(completed) / Double(totalCount)
                // Report progress at most every 5% to avoid flooding the main queue
                let shouldReport = fraction - lastReportedFraction >= 0.05 || completed == totalCount
                if shouldReport { lastReportedFraction = fraction }
                lock.unlock()

                if shouldReport {
                    let f = fraction
                    DispatchQueue.main.async { [weak self] in self?.loadingProgress = f }
                }
            }

            // Collect routes in original URL order, then push to main thread in batches
            let ordered = (0..<totalCount).compactMap { results[$0] }
            guard !ordered.isEmpty else {
                DispatchQueue.main.async { [weak self] in self?.loadingProgress = nil }
                return
            }

            let batchSize = 40
            for start in stride(from: 0, to: ordered.count, by: batchSize) {
                let batch = Array(ordered[start..<min(start + batchSize, ordered.count)])
                DispatchQueue.main.async { [weak self] in self?.routes.append(contentsOf: batch) }
            }

            // Fit after all batches land — main queue is FIFO so this runs last
            DispatchQueue.main.async { [weak self] in
                self?.loadingProgress = nil
                #if os(macOS)
                self?.persistRouteURLs()
                #else
                self?.persistRouteBookmarks()
                #endif
                NotificationCenter.default.post(name: .fitAllRoutes, object: self)
            }
        }
    }

    func removeRoute(id: UUID) {
        routes.removeAll { $0.id == id }
        selectedRouteIds.remove(id)
        if lastClickedRouteId == id { lastClickedRouteId = nil }
        if hoveredRouteId == id { hoveredRouteId = nil }
        #if os(macOS)
        persistRouteURLs()
        #else
        persistRouteBookmarks()
        #endif
    }

    func removeSelectedRoutes() {
        let ids = selectedRouteIds
        routes.removeAll { ids.contains($0.id) }
        selectedRouteIds = []
        lastClickedRouteId = nil
        if let h = hoveredRouteId, ids.contains(h) { hoveredRouteId = nil }
        #if os(macOS)
        persistRouteURLs()
        #else
        persistRouteBookmarks()
        #endif
    }

    #if os(macOS)
    func handleListTap(route: GPXRoute, modifiers: NSEvent.ModifierFlags, visibleRoutes: [GPXRoute]) {
        if modifiers.contains(.shift) {
            guard let anchor = lastClickedRouteId,
                  let anchorIdx = visibleRoutes.firstIndex(where: { $0.id == anchor }),
                  let currentIdx = visibleRoutes.firstIndex(where: { $0.id == route.id }) else {
                selectedRouteIds = [route.id]
                lastClickedRouteId = route.id
                return
            }
            let lo = min(anchorIdx, currentIdx)
            let hi = max(anchorIdx, currentIdx)
            selectedRouteIds = Set(visibleRoutes[lo...hi].map { $0.id })
            // Don't update lastClickedRouteId on shift-click
        } else if modifiers.contains(.command) {
            if selectedRouteIds.contains(route.id) {
                selectedRouteIds.remove(route.id)
            } else {
                selectedRouteIds.insert(route.id)
            }
            lastClickedRouteId = route.id
        } else {
            // Plain click: select only this route, or deselect if it's the only one selected
            if selectedRouteIds == [route.id] {
                selectedRouteIds = []
                lastClickedRouteId = nil  // no anchor when nothing is selected
            } else {
                selectedRouteIds = [route.id]
                lastClickedRouteId = route.id
            }
        }
    }
    #else
    func handleListTap(route: GPXRoute, visibleRoutes: [GPXRoute]) {
        if selectedRouteIds == [route.id] {
            selectedRouteIds = []
        } else {
            selectedRouteIds = [route.id]
        }
        lastClickedRouteId = route.id
    }
    #endif

    #if os(macOS)
    func renameRoute(id: UUID, newName: String) throws {
        guard let idx = routes.firstIndex(where: { $0.id == id }) else { return }
        let route = routes[idx]
        let newURL = route.fileURL
            .deletingLastPathComponent()
            .appendingPathComponent(newName)
            .appendingPathExtension(route.fileURL.pathExtension)
        try FileManager.default.moveItem(at: route.fileURL, to: newURL)
        routes[idx].fileName = newName
        routes[idx].fileURL = newURL
        persistRouteURLs()
    }
    #endif

    func openFilePicker() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.title = "Open"
        panel.message = "Select GPX files or a folder containing GPX files"
        if panel.runModal() == .OK {
            loadURLs(panel.urls)
        }
        #else
        showingFilePicker = true
        #endif
    }
}

/// Passes a set of routes from "Open Selected in New Tab" to the next AppState init.
/// Also holds URL sets for session restore of non-first tabs.
/// All access is on the main thread (UI actions → window creation), so no locking needed.
class PendingTabRoutes {
    static let shared = PendingTabRoutes()
    private var routeQueue: [[GPXRoute]] = []
    private var urlQueue: [[URL]] = []

    func enqueue(_ routes: [GPXRoute]) { routeQueue.append(routes) }
    func dequeue() -> [GPXRoute]? { routeQueue.isEmpty ? nil : routeQueue.removeFirst() }

    func enqueueURLs(_ urls: [URL]) { urlQueue.append(urls) }
    func dequeueURLs() -> [URL]? { urlQueue.isEmpty ? nil : urlQueue.removeFirst() }

    var pendingURLTabCount: Int { urlQueue.count }
}

/// Tracks all live AppState instances in creation order (main-thread only).
class AppStateRegistry {
    static let shared = AppStateRegistry()
    private(set) var states: [AppState] = []

    func register(_ state: AppState) { states.append(state) }
    func unregister(_ state: AppState) { states.removeAll { $0 === state } }
}

#if os(macOS)
/// Set by AppDelegate before any AppState is created when launched via "Open With".
class AppLaunchState {
    static let shared = AppLaunchState()
    var openedWithFiles = false
    var filesToOpen: [URL] = []
}
#endif
