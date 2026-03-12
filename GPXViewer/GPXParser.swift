import Foundation
import CoreLocation

struct ParsedGPX {
    let coordinates: [CLLocationCoordinate2D]
    let startTime: Date?
    let endTime: Date?
    let totalDistance: Double  // metres
}

class GPXParser: NSObject, XMLParserDelegate {
    private var coordinates: [CLLocationCoordinate2D] = []
    private var times: [Date] = []

    private var isInTrackPoint = false
    private var isInName = false
    private var isInTime = false
    private var nameBuffer = ""
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

        return ParsedGPX(
            coordinates: instance.coordinates,
            startTime: instance.times.first,
            endTime: instance.times.last,
            totalDistance: dist
        )
    }

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
