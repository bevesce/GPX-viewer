import SwiftUI
import MapKit
import AppKit

// MARK: - HoverableMapView

final class HoverableMapView: MKMapView {
    weak var coordinator: MapViewCoordinator?

    private var mouseDownPoint: CGPoint?
    private var didDrag = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let pt = convert(event.locationInWindow, from: nil)
        coordinator?.handleMouseMoved(at: pt, in: self)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        coordinator?.handleMouseExited()
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        didDrag = false
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        didDrag = true
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if !didDrag, let pt = mouseDownPoint {
            coordinator?.handleClick(at: pt, in: self, clickCount: event.clickCount)
        }
        mouseDownPoint = nil
        didDrag = false
    }
}

// MARK: - Coordinator

final class MapViewCoordinator: NSObject, MKMapViewDelegate {
    let appState: AppState
    weak var mapView: HoverableMapView?

    var lastRouteIds: [UUID] = []
    var lastSelectedId: UUID? = nil
    var lastHoveredId: UUID? = nil

    // O(1) lookups by route ID
    private var overlayMap: [UUID: MKPolyline] = [:]
    private var routeIndex: [UUID: GPXRoute] = [:]

    // Current map span, updated on region changes
    private var currentSpan: Double = 0.05

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: Overlay management

    func updateOverlays(on mapView: MKMapView) {
        let currentIds = Set(appState.routes.map { $0.id })
        let previousIds = Set(overlayMap.keys)

        // Remove overlays for deleted routes
        let removedIds = previousIds.subtracting(currentIds)
        if !removedIds.isEmpty {
            let toRemove = removedIds.compactMap { overlayMap[$0] }
            mapView.removeOverlays(toRemove)
            removedIds.forEach {
                overlayMap.removeValue(forKey: $0)
                routeIndex.removeValue(forKey: $0)
            }
        }

        // Add overlays for new routes
        let addedIds = currentIds.subtracting(previousIds)
        if !addedIds.isEmpty {
            var newOverlays: [MKPolyline] = []
            for route in appState.routes where addedIds.contains(route.id) {
                let coords = route.simplified
                let polyline = MKPolyline(coordinates: coords, count: coords.count)
                polyline.title = route.id.uuidString
                overlayMap[route.id] = polyline
                routeIndex[route.id] = route
                newOverlays.append(polyline)
            }
            mapView.addOverlays(newOverlays, level: .aboveRoads)
        }

        lastRouteIds = appState.routes.map { $0.id }
    }

    func refreshRenderers(on mapView: MKMapView) {
        // Only touch the renderers whose active state actually changed
        var changedIds: Set<UUID> = []
        if let id = lastSelectedId      { changedIds.insert(id) }
        if let id = appState.selectedRouteId { changedIds.insert(id) }
        if let id = lastHoveredId       { changedIds.insert(id) }
        if let id = appState.hoveredRouteId  { changedIds.insert(id) }

        for id in changedIds {
            guard let polyline = overlayMap[id],
                  let renderer = mapView.renderer(for: polyline) as? MKPolylineRenderer,
                  let route = routeIndex[id]
            else { continue }
            let active = appState.selectedRouteId == id || appState.hoveredRouteId == id
            applyStyle(renderer: renderer, route: route, active: active)
            renderer.setNeedsDisplay()
        }

        lastSelectedId = appState.selectedRouteId
        lastHoveredId = appState.hoveredRouteId
    }

    private func applyStyle(renderer: MKPolylineRenderer, route: GPXRoute, active: Bool) {
        renderer.strokeColor = route.color.nsColor.withAlphaComponent(active ? 1.0 : 0.65)
        renderer.lineWidth = scaledLineWidth(base: active ? 5.5 : 3.0)
        renderer.lineCap = .round
        renderer.lineJoin = .round
    }

    // Widens lines logarithmically as the map zooms out.
    // At span ~0.01°: 1× base. Each 10× increase in span adds 0.5× base.
    private func scaledLineWidth(base: CGFloat) -> CGFloat {
        let logFactor = log10(max(currentSpan, 0.01) / 0.01)
        return base * CGFloat(1.0 + logFactor * 0.5)
    }

    // MARK: MKMapViewDelegate

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        guard let polyline = overlay as? MKPolyline else {
            return MKOverlayRenderer(overlay: overlay)
        }
        let renderer = MKPolylineRenderer(polyline: polyline)
        if let routeId = UUID(uuidString: polyline.title ?? ""),
           let route = routeIndex[routeId] {
            let active = appState.selectedRouteId == routeId || appState.hoveredRouteId == routeId
            applyStyle(renderer: renderer, route: route, active: active)
        }
        return renderer
    }

    // MARK: Region changes

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        currentSpan = mapView.region.span.latitudeDelta
        for (routeId, polyline) in overlayMap {
            guard let renderer = mapView.renderer(for: polyline) as? MKPolylineRenderer,
                  let route = routeIndex[routeId]
            else { continue }
            let active = appState.selectedRouteId == routeId || appState.hoveredRouteId == routeId
            applyStyle(renderer: renderer, route: route, active: active)
            renderer.setNeedsDisplay()
        }
    }

    // MARK: Hit testing

    func handleMouseMoved(at point: CGPoint, in mapView: MKMapView) {
        let routeId = nearestRoute(to: point, in: mapView, threshold: 10)
        if routeId != appState.hoveredRouteId {
            DispatchQueue.main.async { [weak self] in
                self?.appState.hoveredRouteId = routeId
            }
        }
    }

    func handleMouseExited() {
        if appState.hoveredRouteId != nil {
            DispatchQueue.main.async { [weak self] in
                self?.appState.hoveredRouteId = nil
            }
        }
    }

    func handleClick(at point: CGPoint, in mapView: MKMapView, clickCount: Int) {
        let routeId = nearestRoute(to: point, in: mapView, threshold: 12)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.appState.selectedRouteId == routeId {
                self.appState.selectedRouteId = nil
            } else {
                self.appState.selectedRouteId = routeId
                if let routeId {
                    NotificationCenter.default.post(name: .scrollToRoute, object: routeId)
                }
            }
        }
    }

    private func nearestRoute(to point: CGPoint, in mapView: MKMapView, threshold: CGFloat) -> UUID? {
        var best: (id: UUID, dist: CGFloat)? = nil
        for overlay in mapView.overlays {
            guard let polyline = overlay as? MKPolyline,
                  let routeId = UUID(uuidString: polyline.title ?? "") else { continue }

            let pts = (0..<polyline.pointCount).map {
                mapView.convert(polyline.points()[$0].coordinate, toPointTo: mapView)
            }
            for i in 0..<max(0, pts.count - 1) {
                let d = distPointToSegment(p: point, a: pts[i], b: pts[i + 1])
                if d < threshold && (best == nil || d < best!.dist) {
                    best = (routeId, d)
                }
            }
        }
        return best?.id
    }

    private func distPointToSegment(p: CGPoint, a: CGPoint, b: CGPoint) -> CGFloat {
        let ab = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let ap = CGPoint(x: p.x - a.x, y: p.y - a.y)
        let len2 = ab.x * ab.x + ab.y * ab.y
        guard len2 > 0 else {
            return hypot(ap.x, ap.y)
        }
        let t = max(0, min(1, (ap.x * ab.x + ap.y * ab.y) / len2))
        let closest = CGPoint(x: a.x + t * ab.x, y: a.y + t * ab.y)
        return hypot(p.x - closest.x, p.y - closest.y)
    }

    // MARK: Map fitting

    @objc func handleFitAll() {
        guard let mapView else { return }
        guard !routeIndex.isEmpty else { return }
        var minLat =  Double.infinity, maxLat = -Double.infinity
        var minLon =  Double.infinity, maxLon = -Double.infinity
        for route in routeIndex.values {
            let b = route.boundingBox
            if b.minLat < minLat { minLat = b.minLat }
            if b.maxLat > maxLat { maxLat = b.maxLat }
            if b.minLon < minLon { minLon = b.minLon }
            if b.maxLon > maxLon { maxLon = b.maxLon }
        }
        applyRegion(mapView, minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon)
    }

    @objc func handleZoomToRoute(_ notification: Notification) {
        guard let routeId = notification.object as? UUID,
              let route = routeIndex[routeId],
              let mapView else { return }
        let b = route.boundingBox
        applyRegion(mapView, minLat: b.minLat, maxLat: b.maxLat, minLon: b.minLon, maxLon: b.maxLon)
    }

    private func applyRegion(_ mapView: MKMapView,
                              minLat: Double, maxLat: Double,
                              minLon: Double, maxLon: Double) {
        let center = CLLocationCoordinate2D(
            latitude:  (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let region = MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(
                latitudeDelta:  max((maxLat - minLat) * 1.4, 0.005),
                longitudeDelta: max((maxLon - minLon) * 1.4, 0.005)
            )
        )
        mapView.setRegion(region, animated: true)
    }
}

// MARK: - SwiftUI wrapper

struct MapView: NSViewRepresentable {
    @ObservedObject var appState: AppState

    func makeCoordinator() -> MapViewCoordinator {
        MapViewCoordinator(appState: appState)
    }

    func makeNSView(context: Context) -> HoverableMapView {
        let mapView = HoverableMapView()
        mapView.coordinator = context.coordinator
        context.coordinator.mapView = mapView
        mapView.delegate = context.coordinator
        mapView.showsCompass = true
        mapView.showsScale = true

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(MapViewCoordinator.handleFitAll),
            name: .fitAllRoutes,
            object: nil
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(MapViewCoordinator.handleZoomToRoute(_:)),
            name: .zoomToRoute,
            object: nil
        )
        return mapView
    }

    func updateNSView(_ mapView: HoverableMapView, context: Context) {
        let coord = context.coordinator
        let currentIds = appState.routes.map { $0.id }

        if currentIds != coord.lastRouteIds {
            coord.updateOverlays(on: mapView)
        } else if appState.selectedRouteId != coord.lastSelectedId
                    || appState.hoveredRouteId != coord.lastHoveredId {
            coord.refreshRenderers(on: mapView)
        }
    }
}
