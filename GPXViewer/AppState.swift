import Foundation
import AppKit
import Combine

class AppState: ObservableObject {
    @Published var routes: [GPXRoute] = []
    @Published var selectedRouteId: UUID? = nil
    @Published var hoveredRouteId: UUID? = nil
    @Published var loadingProgress: Double? = nil  // nil = idle, 0–1 = loading

    private let loadQueue = DispatchQueue(label: "gpx.load", qos: .userInitiated)

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
                NotificationCenter.default.post(name: .fitAllRoutes, object: nil)
            }
        }
    }

    func removeRoute(id: UUID) {
        routes.removeAll { $0.id == id }
        if selectedRouteId == id { selectedRouteId = nil }
        if hoveredRouteId == id { hoveredRouteId = nil }
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
