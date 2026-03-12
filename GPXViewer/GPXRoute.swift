import Foundation
import CoreLocation
import SwiftUI
import AppKit

struct RouteColor {
    let swiftUI: Color
    let nsColor: NSColor

    init(r: Double, g: Double, b: Double) {
        self.swiftUI = Color(red: r, green: g, blue: b)
        self.nsColor = NSColor(red: r, green: g, blue: b, alpha: 1.0)
    }
}

let routeColorPalette: [RouteColor] = [
    RouteColor(r: 0.90, g: 0.10, b: 0.10),  // red
    RouteColor(r: 0.95, g: 0.50, b: 0.00),  // orange
    RouteColor(r: 0.60, g: 0.10, b: 0.80),  // purple
    RouteColor(r: 0.90, g: 0.10, b: 0.55),  // pink
    RouteColor(r: 0.75, g: 0.55, b: 0.00),  // gold
    RouteColor(r: 0.45, g: 0.28, b: 0.10),  // brown
    RouteColor(r: 0.80, g: 0.20, b: 0.30),  // crimson
    RouteColor(r: 0.70, g: 0.00, b: 0.45),  // magenta
    RouteColor(r: 0.95, g: 0.30, b: 0.20),  // coral
    RouteColor(r: 0.55, g: 0.35, b: 0.65),  // mauve
]

struct GPXRoute: Identifiable {
    let id: UUID
    let fileName: String
    let coordinates: [CLLocationCoordinate2D]
    let colorIndex: Int
    let fileURL: URL
    let startTime: Date?
    let endTime: Date?
    let totalDistance: Double  // metres

    var color: RouteColor { routeColorPalette[colorIndex % routeColorPalette.count] }
    var duration: TimeInterval? {
        guard let s = startTime, let e = endTime else { return nil }
        return e.timeIntervalSince(s)
    }

    init(fileName: String, coordinates: [CLLocationCoordinate2D], colorIndex: Int,
         fileURL: URL, startTime: Date?, endTime: Date?, totalDistance: Double) {
        self.id = UUID()
        self.fileName = fileName
        self.coordinates = coordinates
        self.colorIndex = colorIndex
        self.fileURL = fileURL
        self.startTime = startTime
        self.endTime = endTime
        self.totalDistance = totalDistance
    }
}
