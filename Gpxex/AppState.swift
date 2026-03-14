import Foundation
import AppKit
import Combine

class AppState: ObservableObject {
    @Published var routes: [GPXRoute] = []
    @Published var selectedRouteIds: Set<UUID> = []
    @Published var hoveredRouteId: UUID? = nil
    @Published var loadingProgress: Double? = nil  // nil = idle, 0–1 = loading

    // Anchor for shift-click range selection — not published (no re-render needed)
    var lastClickedRouteId: UUID? = nil

    private let loadQueue = DispatchQueue(label: "gpx.load", qos: .userInitiated)
    private static let savedURLsKey = "savedRouteURLs"

    init() {
        if let strings = UserDefaults.standard.stringArray(forKey: Self.savedURLsKey) {
            let urls = strings.compactMap { URL(string: $0) }
            if !urls.isEmpty { loadURLs(urls) }
        }
    }

    private func persistRouteURLs() {
        let strings = routes.map { $0.fileURL.absoluteString }
        UserDefaults.standard.set(strings, forKey: Self.savedURLsKey)
    }

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
                self?.persistRouteURLs()
                NotificationCenter.default.post(name: .fitAllRoutes, object: nil)
            }
        }
    }

    func removeRoute(id: UUID) {
        routes.removeAll { $0.id == id }
        selectedRouteIds.remove(id)
        if lastClickedRouteId == id { lastClickedRouteId = nil }
        if hoveredRouteId == id { hoveredRouteId = nil }
        persistRouteURLs()
    }

    func removeSelectedRoutes() {
        let ids = selectedRouteIds
        routes.removeAll { ids.contains($0.id) }
        selectedRouteIds = []
        lastClickedRouteId = nil
        if let h = hoveredRouteId, ids.contains(h) { hoveredRouteId = nil }
        persistRouteURLs()
    }

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
            // Plain click: select only this route, or deselect if it's the only one
            if selectedRouteIds == [route.id] {
                selectedRouteIds = []
            } else {
                selectedRouteIds = [route.id]
            }
            lastClickedRouteId = route.id
        }
    }

    func openFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.title = "Open"
        panel.message = "Select GPX files or a folder containing GPX files"
        if panel.runModal() == .OK {
            loadURLs(panel.urls)
        }
    }
}
