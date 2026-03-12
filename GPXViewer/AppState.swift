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
        // Snapshot existing URLs for deduplication before going to background
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
                        let files = contents
                            .filter { $0.pathExtension.lowercased() == "gpx" }
                            .sorted { $0.lastPathComponent < $1.lastPathComponent }
                        allURLs += files
                    }
                } else if url.pathExtension.lowercased() == "gpx" {
                    allURLs.append(url)
                }
            }

            let newURLs = allURLs.filter { !existingURLs.contains($0) }
            guard !newURLs.isEmpty else { return }

            let totalCount = newURLs.count
            DispatchQueue.main.async { [weak self] in
                self?.loadingProgress = 0.0
            }

            let batchSize = 20
            var batch: [GPXRoute] = []
            var colorIndex = initialColorIndex
            var anyAdded = false

            for (i, url) in newURLs.enumerated() {
                guard let parsed = GPXParser.parse(url: url) else { continue }
                let route = GPXRoute(
                    fileName: url.deletingPathExtension().lastPathComponent,
                    coordinates: parsed.coordinates,
                    simplified: parsed.simplified,
                    colorIndex: colorIndex,
                    fileURL: url,
                    startTime: parsed.startTime,
                    endTime: parsed.endTime,
                    totalDistance: parsed.totalDistance
                )
                batch.append(route)
                colorIndex += 1
                anyAdded = true

                if batch.count >= batchSize || i == newURLs.count - 1 {
                    let toAppend = batch
                    batch = []
                    let progress = Double(i + 1) / Double(totalCount)
                    DispatchQueue.main.async { [weak self] in
                        self?.routes.append(contentsOf: toAppend)
                        self?.loadingProgress = progress
                    }
                }
            }

            // Runs after all batch appends because the main queue is FIFO
            DispatchQueue.main.async { [weak self] in
                self?.loadingProgress = nil
                if anyAdded {
                    NotificationCenter.default.post(name: .fitAllRoutes, object: nil)
                }
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
