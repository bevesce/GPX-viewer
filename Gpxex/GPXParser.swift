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

    // MARK: - Public API

    /// Parse with cache: returns a cached result if the source file is unchanged,
    /// otherwise parses from scratch and writes a new cache entry.
    static func cachedParse(url: URL) -> ParsedGPX? {
        guard let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        else { return parse(url: url) }

        let cachePath = cacheDir.appendingPathComponent(url.lastPathComponent + ".cache")

        if let cached = readCache(at: cachePath, expectedModDate: modDate) {
            return cached
        }

        guard let result = parse(url: url) else { return nil }
        writeCache(result, to: cachePath, modDate: modDate)
        return result
    }

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

    // MARK: - Cache

    private static let cacheDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Gpxex", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // Binary cache format (little-endian):
    //   4 bytes  magic "GPXC"
    //   1 byte   version (1)
    //   8 bytes  modDate (Double, timeIntervalSinceReferenceDate)
    //   8 bytes  totalDistance (Double)
    //   1 byte   hasStartTime flag
    //   8 bytes  startTime if flag == 1
    //   1 byte   hasEndTime flag
    //   8 bytes  endTime if flag == 1
    //   4 bytes  simplified point count (UInt32)
    //   N×16     simplified CLLocationCoordinate2D (lat Double, lon Double)
    //   4 bytes  full point count (UInt32)
    //   N×16     full CLLocationCoordinate2D

    private static let magic: UInt32 = 0x43585047  // "GPXC" little-endian

    private static func writeCache(_ result: ParsedGPX, to path: URL, modDate: Date) {
        var data = Data()

        func appendValue<T>(_ value: T) {
            var v = value
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }

        appendValue(magic)
        appendValue(UInt8(1))  // version
        appendValue(modDate.timeIntervalSinceReferenceDate)
        appendValue(result.totalDistance)

        if let t = result.startTime {
            appendValue(UInt8(1))
            appendValue(t.timeIntervalSinceReferenceDate)
        } else {
            appendValue(UInt8(0))
        }
        if let t = result.endTime {
            appendValue(UInt8(1))
            appendValue(t.timeIntervalSinceReferenceDate)
        } else {
            appendValue(UInt8(0))
        }

        appendCoords(result.simplified, into: &data)
        appendCoords(result.coordinates, into: &data)

        try? data.write(to: path, options: .atomic)
    }

    private static func appendCoords(_ coords: [CLLocationCoordinate2D], into data: inout Data) {
        var count = UInt32(coords.count)
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        coords.withUnsafeBytes { data.append(contentsOf: $0) }
    }

    private static func readCache(at path: URL, expectedModDate: Date) -> ParsedGPX? {
        guard let data = try? Data(contentsOf: path, options: .mappedIfSafe),
              data.count > 22
        else { return nil }

        var offset = 0

        func read<T: FixedWidthInteger>(_ type: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else { return nil }
            let val = data[offset..<offset + size].withUnsafeBytes { $0.loadUnaligned(as: T.self) }
            offset += size
            return val
        }
        func readDouble() -> Double? {
            guard offset + 8 <= data.count else { return nil }
            let val = data[offset..<offset + 8].withUnsafeBytes { $0.loadUnaligned(as: Double.self) }
            offset += 8
            return val
        }
        func readOptionalDate() -> Date? {
            guard let flag = read(UInt8.self) else { return nil }
            guard flag == 1 else { return nil }
            guard let t = readDouble() else { return nil }
            return Date(timeIntervalSinceReferenceDate: t)
        }
        func readCoords() -> [CLLocationCoordinate2D]? {
            guard let count = read(UInt32.self) else { return nil }
            let byteCount = Int(count) * MemoryLayout<CLLocationCoordinate2D>.stride
            guard offset + byteCount <= data.count else { return nil }
            let coords = data[offset..<offset + byteCount].withUnsafeBytes {
                Array($0.bindMemory(to: CLLocationCoordinate2D.self))
            }
            offset += byteCount
            return coords
        }

        guard read(UInt32.self) == magic,
              read(UInt8.self) == 1,
              let storedInterval = readDouble(),
              Date(timeIntervalSinceReferenceDate: storedInterval) == expectedModDate,
              let dist      = readDouble()
        else { return nil }

        let startTime = readOptionalDate()
        let endTime   = readOptionalDate()

        guard let simplified = readCoords(),
              let full       = readCoords()
        else { return nil }

        return ParsedGPX(
            coordinates: full,
            simplified: simplified,
            startTime: startTime,
            endTime: endTime,
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
