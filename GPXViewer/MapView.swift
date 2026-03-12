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
            coordinator?.handleClick(at: pt, in: self)
        }
        mouseDownPoint = nil
        didDrag = false
    }
}

// MARK: - Coordinator

final class MapViewCoordinator: NSObject, MKMapViewDelegate {
    let appState: AppState
    weak var mapView: HoverableMapView?

    // Tracks what was last rendered to avoid redundant work
    var lastRouteIds: [UUID] = []
    var lastSelectedId: UUID? = nil
    var lastHoveredId: UUID? = nil

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: Overlay management

    func rebuildOverlays(on mapView: MKMapView) {
        mapView.removeOverlays(mapView.overlays)
        for route in appState.routes {
            let polyline = MKPolyline(coordinates: route.coordinates, count: route.coordinates.count)
            polyline.title = route.id.uuidString
            mapView.addOverlay(polyline, level: .aboveRoads)
        }
        if appState.routes.count > lastRouteIds.count {
            fitMap(mapView)
        }
        lastRouteIds = appState.routes.map { $0.id }
    }

    func refreshRenderers(on mapView: MKMapView) {
        for overlay in mapView.overlays {
            guard
                let polyline = overlay as? MKPolyline,
                let routeId = UUID(uuidString: polyline.title ?? ""),
                let renderer = mapView.renderer(for: overlay) as? MKPolylineRenderer,
                let route = appState.routes.first(where: { $0.id == routeId })
            else { continue }

            let active = appState.selectedRouteId == routeId || appState.hoveredRouteId == routeId
            applyStyle(renderer: renderer, route: route, active: active)
            renderer.setNeedsDisplay()
        }
        lastSelectedId = appState.selectedRouteId
        lastHoveredId = appState.hoveredRouteId
    }

    private func applyStyle(renderer: MKPolylineRenderer, route: GPXRoute, active: Bool) {
        renderer.strokeColor = route.color.nsColor.withAlphaComponent(active ? 1.0 : 0.65)
        renderer.lineWidth = active ? 5.5 : 3.0
        renderer.lineCap = .round
        renderer.lineJoin = .round
    }

    // MARK: MKMapViewDelegate

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        guard let polyline = overlay as? MKPolyline else {
            return MKOverlayRenderer(overlay: overlay)
        }
        let renderer = MKPolylineRenderer(polyline: polyline)
        if let routeId = UUID(uuidString: polyline.title ?? ""),
           let route = appState.routes.first(where: { $0.id == routeId }) {
            let active = appState.selectedRouteId == routeId || appState.hoveredRouteId == routeId
            applyStyle(renderer: renderer, route: route, active: active)
        }
        return renderer
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

    func handleClick(at point: CGPoint, in mapView: MKMapView) {
        let routeId = nearestRoute(to: point, in: mapView, threshold: 12)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.appState.selectedRouteId == routeId {
                self.appState.selectedRouteId = nil
            } else {
                self.appState.selectedRouteId = routeId
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
        if let mapView = mapView { fitMap(mapView) }
    }

    @objc func handleZoomToRoute(_ notification: Notification) {
        guard let routeId = notification.object as? UUID,
              let route = appState.routes.first(where: { $0.id == routeId }),
              let mapView = mapView else { return }
        fitMap(mapView, coords: route.coordinates)
    }

    func fitMap(_ mapView: MKMapView) {
        let allCoords = appState.routes.flatMap { $0.coordinates }
        fitMap(mapView, coords: allCoords)
    }

    private func fitMap(_ mapView: MKMapView, coords: [CLLocationCoordinate2D]) {
        let allCoords = coords
        guard !allCoords.isEmpty else { return }

        let lats = allCoords.map { $0.latitude }
        let lons = allCoords.map { $0.longitude }
        let minLat = lats.min()!, maxLat = lats.max()!
        let minLon = lons.min()!, maxLon = lons.max()!

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let region = MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLat - minLat) * 1.4, 0.005),
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
            coord.rebuildOverlays(on: mapView)
        } else if appState.selectedRouteId != coord.lastSelectedId
                    || appState.hoveredRouteId != coord.lastHoveredId {
            coord.refreshRenderers(on: mapView)
        }
    }
}
