import Foundation
import AppKit
import Combine

class AppState: ObservableObject {
    @Published var routes: [GPXRoute] = []
    @Published var selectedRouteId: UUID? = nil
    @Published var hoveredRouteId: UUID? = nil

    func loadURLs(_ urls: [URL]) {
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    loadDirectory(url: url)
                } else if url.pathExtension.lowercased() == "gpx" {
                    loadGPXFile(url: url)
                }
            }
        }
    }

    private func loadDirectory(url: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let gpxFiles = contents.filter { $0.pathExtension.lowercased() == "gpx" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in gpxFiles {
            loadGPXFile(url: file)
        }
    }

    private func loadGPXFile(url: URL) {
        guard !routes.contains(where: { $0.fileURL == url }) else { return }
        guard let parsed = GPXParser.parse(url: url) else { return }
        let route = GPXRoute(
            fileName: url.deletingPathExtension().lastPathComponent,
            coordinates: parsed.coordinates,
            colorIndex: routes.count,
            fileURL: url,
            startTime: parsed.startTime,
            endTime: parsed.endTime,
            totalDistance: parsed.totalDistance
        )
        routes.append(route)
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
        panel.title = "Open GPX Files"
        panel.message = "Select GPX files or a folder containing GPX files"
        if panel.runModal() == .OK {
            loadURLs(panel.urls)
        }
    }
}
