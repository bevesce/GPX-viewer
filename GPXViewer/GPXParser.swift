import Foundation
import CoreLocation

struct ParsedGPX {
    let coordinates: [CLLocationCoordinate2D]
    let simplified: [CLLocationCoordinate2D]
    let startTime: Date?
    let endTime: Date?
    let totalDistance: Double  // metres
}

class GPXParser: NSObject, XMLParserDelegate {
    private var coordinates: [CLLocationCoordinate2D] = []
    private var times: [Date] = []

    private var isInTrackPoint = false
    private var isInTime = false
    private var timeBuffer = ""

    private static let isoFull: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoBasic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(url: URL) -> ParsedGPX? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let instance = GPXParser()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = instance
        guard xmlParser.parse(), !instance.coordinates.isEmpty else { return nil }

        let dist = zip(instance.coordinates, instance.coordinates.dropFirst()).reduce(0.0) { acc, pair in
            let a = CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
            let b = CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude)
            return acc + a.distance(from: b)
        }

        let simplified = douglasPeucker(instance.coordinates, epsilon: 0.0001)

        return ParsedGPX(
            coordinates: instance.coordinates,
            simplified: simplified,
            startTime: instance.times.first,
            endTime: instance.times.last,
            totalDistance: dist
        )
    }

    // MARK: - Douglas-Peucker simplification

    private static func douglasPeucker(
        _ coords: [CLLocationCoordinate2D],
        epsilon: Double
    ) -> [CLLocationCoordinate2D] {
        guard coords.count > 2 else { return coords }

        var maxDist = 0.0
        var maxIndex = 0
        let first = coords[0]
        let last = coords[coords.count - 1]

        for i in 1..<coords.count - 1 {
            let d = perpendicularDistance(coords[i], from: first, to: last)
            if d > maxDist {
                maxDist = d
                maxIndex = i
            }
        }

        if maxDist > epsilon {
            let left  = douglasPeucker(Array(coords[0...maxIndex]), epsilon: epsilon)
            let right = douglasPeucker(Array(coords[maxIndex...]), epsilon: epsilon)
            return left.dropLast() + right
        } else {
            return [first, last]
        }
    }

    private static func perpendicularDistance(
        _ p: CLLocationCoordinate2D,
        from a: CLLocationCoordinate2D,
        to b: CLLocationCoordinate2D
    ) -> Double {
        let dx = b.longitude - a.longitude
        let dy = b.latitude  - a.latitude
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else {
            let ex = p.longitude - a.longitude
            let ey = p.latitude  - a.latitude
            return sqrt(ex * ex + ey * ey)
        }
        let t = max(0, min(1,
            ((p.longitude - a.longitude) * dx + (p.latitude - a.latitude) * dy) / len2
        ))
        let cx = a.longitude + t * dx
        let cy = a.latitude  + t * dy
        let ex = p.longitude - cx
        let ey = p.latitude  - cy
        return sqrt(ex * ex + ey * ey)
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        if elementName == "trkpt" || elementName == "rtept" {
            isInTrackPoint = true
            if let latStr = attributeDict["lat"], let lonStr = attributeDict["lon"],
               let lat = Double(latStr), let lon = Double(lonStr) {
                coordinates.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
            }
        } else if elementName == "time" && isInTrackPoint {
            isInTime = true
            timeBuffer = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isInTime { timeBuffer += string }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        if elementName == "trkpt" || elementName == "rtept" {
            isInTrackPoint = false
        } else if elementName == "time" && isInTime {
            let raw = timeBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if let date = Self.isoFull.date(from: raw) ?? Self.isoBasic.date(from: raw) {
                times.append(date)
            }
            isInTime = false
        }
    }
}
