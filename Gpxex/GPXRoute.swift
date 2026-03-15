import Foundation
import CoreLocation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct RouteColor {
    let swiftUI: Color
    private let r, g, b: Double

    #if os(macOS)
    var native: NSColor { NSColor(red: r, green: g, blue: b, alpha: 1.0) }
    #else
    var native: UIColor { UIColor(red: r, green: g, blue: b, alpha: 1.0) }
    #endif

    init(r: Double, g: Double, b: Double) {
        self.r = r; self.g = g; self.b = b
        self.swiftUI = Color(red: r, green: g, blue: b)
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

struct RouteBoundingBox {
    let minLat: Double
    let maxLat: Double
    let minLon: Double
    let maxLon: Double
}

struct GPXRoute: Identifiable {
    let id: UUID
    var fileName: String
    let coordinates: [CLLocationCoordinate2D]
    let simplified: [CLLocationCoordinate2D]  // decimated for map rendering
    let boundingBox: RouteBoundingBox          // derived from simplified at init time
    let colorIndex: Int
    var fileURL: URL
    let startTime: Date?
    let endTime: Date?
    let totalDistance: Double  // metres

    var color: RouteColor { routeColorPalette[colorIndex % routeColorPalette.count] }
    var duration: TimeInterval? {
        guard let s = startTime, let e = endTime else { return nil }
        return e.timeIntervalSince(s)
    }

    init(fileName: String, coordinates: [CLLocationCoordinate2D],
         simplified: [CLLocationCoordinate2D], colorIndex: Int,
         fileURL: URL, startTime: Date?, endTime: Date?, totalDistance: Double) {
        self.id = UUID()
        self.fileName = fileName
        self.coordinates = coordinates
        self.simplified = simplified
        self.colorIndex = colorIndex
        self.fileURL = fileURL
        self.startTime = startTime
        self.endTime = endTime
        self.totalDistance = totalDistance

        var minLat =  Double.infinity, maxLat = -Double.infinity
        var minLon =  Double.infinity, maxLon = -Double.infinity
        for c in simplified {
            if c.latitude  < minLat { minLat = c.latitude  }
            if c.latitude  > maxLat { maxLat = c.latitude  }
            if c.longitude < minLon { minLon = c.longitude }
            if c.longitude > maxLon { maxLon = c.longitude }
        }
        self.boundingBox = RouteBoundingBox(
            minLat: minLat.isFinite ? minLat : 0,
            maxLat: maxLat.isFinite ? maxLat : 0,
            minLon: minLon.isFinite ? minLon : 0,
            maxLon: maxLon.isFinite ? maxLon : 0
        )
    }
}
