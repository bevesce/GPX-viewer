import SwiftUI
import MapKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import CoreLocation

// MARK: - HoverableMapView (macOS only)

#if os(macOS)
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
            coordinator?.handleClick(at: pt, in: self, event: event)
        }
        mouseDownPoint = nil
        didDrag = false
    }
}
#endif

// MARK: - Coordinator

final class MapViewCoordinator: NSObject, MKMapViewDelegate, CLLocationManagerDelegate {
    let appState: AppState
    weak var mapView: MKMapView?

    var lastRouteIds: [UUID] = []
    var lastFilteredRouteIds: Set<UUID> = []
    var lastSelectedIds: Set<UUID> = []
    var lastHoveredId: UUID? = nil

    // Route data lookup
    private var routeIndex: [UUID: GPXRoute] = [:]

    // Per-route MKPolyline objects (used as children of MKMultiPolyline; never added directly)
    private var polylineStore: [UUID: MKPolyline] = [:]

    // P4: 10 group overlays (keyed by colorIndex % palette.count) — on the map, inactive style
    private var groupOverlays: [Int: MKMultiPolyline] = [:]
    // P3: cached group renderers — populated by mapView(_:rendererFor:)
    private var groupRenderers: [Int: MKMultiPolylineRenderer] = [:]

    // P4: individual overlays for active (hovered/selected) routes — added on top of groups
    private var activePolylines: [UUID: MKPolyline] = [:]
    // P3: cached active renderers
    private var activeRenderers: [UUID: MKPolylineRenderer] = [:]

    // Currently active route IDs (hovered OR selected)
    private var activeIds: Set<UUID> = []

    // P1: last rendered span — skip renderer refresh when span is unchanged (pure pan)
    private var currentSpan: Double = 0.05

    // Location
    private lazy var locationManager: CLLocationManager = {
        let mgr = CLLocationManager()
        mgr.delegate = self
        return mgr
    }()

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: Overlay management

    func updateOverlays(on mapView: MKMapView) {
        let currentIds = Set(appState.routes.map { $0.id })
        let previousIds = Set(polylineStore.keys)

        let removedIds = previousIds.subtracting(currentIds)
        let addedIds   = currentIds.subtracting(previousIds)
        guard !removedIds.isEmpty || !addedIds.isEmpty else { return }

        var dirtySlots = Set<Int>()

        // Remove deleted routes
        for id in removedIds {
            if let route = routeIndex[id] {
                dirtySlots.insert(route.colorIndex % routeColorPalette.count)
            }
            polylineStore.removeValue(forKey: id)
            routeIndex.removeValue(forKey: id)
            activeIds.remove(id)
            if let poly = activePolylines.removeValue(forKey: id) {
                mapView.removeOverlay(poly)
            }
            activeRenderers.removeValue(forKey: id)
        }

        // Add new routes
        for route in appState.routes where addedIds.contains(route.id) {
            let poly = MKPolyline(coordinates: route.simplified, count: route.simplified.count)
            poly.title = route.id.uuidString
            polylineStore[route.id] = poly
            routeIndex[route.id] = route
            dirtySlots.insert(route.colorIndex % routeColorPalette.count)
        }

        // Rebuild only the color groups that gained or lost routes
        let filtered = appState.filteredRouteIds
        for slot in dirtySlots {
            if let old = groupOverlays.removeValue(forKey: slot) {
                mapView.removeOverlay(old)
            }
            groupRenderers.removeValue(forKey: slot)

            let members = routeIndex.values
                .filter { $0.colorIndex % routeColorPalette.count == slot && filtered.contains($0.id) }
                .compactMap { polylineStore[$0.id] }

            guard !members.isEmpty else { continue }

            let multi = MKMultiPolyline(members)
            multi.title = String(slot)
            groupOverlays[slot] = multi

            // Insert below any existing active overlays so they stay on top
            if let lowestActive = mapView.overlays.first(where: { overlay in
                guard let poly = overlay as? MKPolyline else { return false }
                return activePolylines.values.contains { $0 === poly }
            }) {
                mapView.insertOverlay(multi, below: lowestActive)
            } else {
                mapView.addOverlay(multi, level: .aboveRoads)
            }
        }

        lastRouteIds = appState.routes.map { $0.id }
        lastFilteredRouteIds = filtered
    }

    func rebuildAllGroupOverlays(on mapView: MKMapView) {
        let filtered = appState.filteredRouteIds
        let allSlots = Set(routeIndex.values.map { $0.colorIndex % routeColorPalette.count })

        for slot in allSlots {
            if let old = groupOverlays.removeValue(forKey: slot) {
                mapView.removeOverlay(old)
            }
            groupRenderers.removeValue(forKey: slot)

            let members = routeIndex.values
                .filter { $0.colorIndex % routeColorPalette.count == slot && filtered.contains($0.id) }
                .compactMap { polylineStore[$0.id] }

            guard !members.isEmpty else { continue }

            let multi = MKMultiPolyline(members)
            multi.title = String(slot)
            groupOverlays[slot] = multi

            if let lowestActive = mapView.overlays.first(where: { overlay in
                guard let poly = overlay as? MKPolyline else { return false }
                return activePolylines.values.contains { $0 === poly }
            }) {
                mapView.insertOverlay(multi, below: lowestActive)
            } else {
                mapView.addOverlay(multi, level: .aboveRoads)
            }
        }

        // Remove active overlays for routes now outside the filter
        let toRemove = activeIds.filter { !filtered.contains($0) }
        for id in toRemove {
            activeIds.remove(id)
            if let poly = activePolylines.removeValue(forKey: id) {
                mapView.removeOverlay(poly)
            }
            activeRenderers.removeValue(forKey: id)
        }

        lastFilteredRouteIds = filtered
        lastSelectedIds = appState.selectedRouteIds
        lastHoveredId = appState.hoveredRouteId
    }

    // MARK: Active state (hover / selection)

    func updateActiveState(on mapView: MKMapView) {
        let hoveredSet: Set<UUID> = appState.hoveredRouteId.map { [$0] } ?? []
        let newActiveIds = appState.selectedRouteIds.union(hoveredSet)
        guard newActiveIds != activeIds else {
            lastSelectedIds = appState.selectedRouteIds
            lastHoveredId   = appState.hoveredRouteId
            return
        }

        let becameActive   = newActiveIds.subtracting(activeIds)
        let becameInactive = activeIds.subtracting(newActiveIds)
        activeIds = newActiveIds

        // Remove overlays for routes that are no longer active
        for id in becameInactive {
            if let poly = activePolylines.removeValue(forKey: id) {
                mapView.removeOverlay(poly)
            }
            activeRenderers.removeValue(forKey: id)
        }

        // Add overlays for newly active routes (on top — addOverlay appends to z-order)
        for id in becameActive {
            guard let route = routeIndex[id] else { continue }
            let poly = MKPolyline(coordinates: route.simplified, count: route.simplified.count)
            poly.title = id.uuidString
            activePolylines[id] = poly
            mapView.addOverlay(poly, level: .aboveRoads)
        }

        lastSelectedIds = appState.selectedRouteIds
        lastHoveredId   = appState.hoveredRouteId
    }

    // MARK: Styling

    private func applyActiveStyle(renderer: MKPolylineRenderer, route: GPXRoute) {
        renderer.strokeColor = route.color.native
        renderer.lineWidth   = scaledLineWidth(base: 5.5)
        renderer.lineCap     = .round
        renderer.lineJoin    = .round
    }

    private func scaledLineWidth(base: CGFloat) -> CGFloat {
        let logFactor = log10(max(currentSpan, 0.01) / 0.01)
        return base * CGFloat(1.0 + logFactor * 0.5)
    }

    // MARK: MKMapViewDelegate — renderer factory

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        // Active individual route polyline
        if let polyline = overlay as? MKPolyline,
           let routeId  = UUID(uuidString: polyline.title ?? ""),
           let route    = routeIndex[routeId] {
            let renderer = MKPolylineRenderer(polyline: polyline)
            applyActiveStyle(renderer: renderer, route: route)
            activeRenderers[routeId] = renderer  // P3: cache
            return renderer
        }

        // Inactive group multi-polyline
        if let multi = overlay as? MKMultiPolyline,
           let slot  = Int(multi.title ?? "") {
            let renderer = MKMultiPolylineRenderer(multiPolyline: multi)
            let color = routeColorPalette[slot % routeColorPalette.count]
            renderer.strokeColor = color.native.withAlphaComponent(0.65)
            renderer.lineWidth   = scaledLineWidth(base: 3.0)
            renderer.lineCap     = .round
            renderer.lineJoin    = .round
            groupRenderers[slot] = renderer  // P3: cache
            return renderer
        }

        return MKOverlayRenderer(overlay: overlay)
    }

    // MARK: Region changes

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        let newSpan = mapView.region.span.latitudeDelta

        // P1: Skip entirely on pure pan — only proceed when zoom level changed (>1%)
        guard abs(newSpan - currentSpan) / max(currentSpan, 1e-9) > 0.01 else { return }
        currentSpan = newSpan

        let region = mapView.region
        let visMinLat = region.center.latitude  - region.span.latitudeDelta  / 2
        let visMaxLat = region.center.latitude  + region.span.latitudeDelta  / 2
        let visMinLon = region.center.longitude - region.span.longitudeDelta / 2
        let visMaxLon = region.center.longitude + region.span.longitudeDelta / 2

        let inactiveWidth = scaledLineWidth(base: 3.0)
        let activeWidth   = scaledLineWidth(base: 5.5)

        // P2: only refresh group renderers whose routes are visible
        // P3: use cached groupRenderers directly (no mapView.renderer(for:) calls)
        for (slot, renderer) in groupRenderers {
            // Check if any route in this slot intersects the visible region
            let visible = routeIndex.values.contains { route in
                guard route.colorIndex % routeColorPalette.count == slot else { return false }
                let b = route.boundingBox
                return b.maxLat >= visMinLat && b.minLat <= visMaxLat
                    && b.maxLon >= visMinLon && b.minLon <= visMaxLon
            }
            guard visible else { continue }
            renderer.lineWidth = inactiveWidth
            renderer.setNeedsDisplay()
        }

        // Active renderers are always few; refresh unconditionally
        for renderer in activeRenderers.values {
            renderer.lineWidth = activeWidth
            renderer.setNeedsDisplay()
        }
    }

    // MARK: Hit testing

    #if os(macOS)
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

    func handleClick(at point: CGPoint, in mapView: MKMapView, event: NSEvent) {
        let routeId = nearestRoute(to: point, in: mapView, threshold: 12)
        let mods = event.modifierFlags
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let routeId {
                if mods.contains(.command) {
                    if self.appState.selectedRouteIds.contains(routeId) {
                        self.appState.selectedRouteIds.remove(routeId)
                    } else {
                        self.appState.selectedRouteIds.insert(routeId)
                        self.appState.lastClickedRouteId = routeId
                    }
                } else {
                    if self.appState.selectedRouteIds == [routeId] {
                        self.appState.selectedRouteIds = []
                    } else {
                        self.appState.selectedRouteIds = [routeId]
                        self.appState.lastClickedRouteId = routeId
                    }
                }
                if !self.appState.selectedRouteIds.isEmpty {
                    NotificationCenter.default.post(name: .scrollToRoute, object: routeId)
                }
            } else if !mods.contains(.command) {
                self.appState.selectedRouteIds = []
            }
        }
    }
    #else
    @objc func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let mapView else { return }
        let point = gesture.location(in: mapView)
        let routeId = nearestRoute(to: point, in: mapView, threshold: 22)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let routeId {
                if self.appState.selectedRouteIds == [routeId] {
                    self.appState.selectedRouteIds = []
                } else {
                    self.appState.selectedRouteIds = [routeId]
                    self.appState.lastClickedRouteId = routeId
                    NotificationCenter.default.post(name: .scrollToRoute, object: routeId)
                }
            } else {
                self.appState.selectedRouteIds = []
            }
        }
    }
    #endif

    private func nearestRoute(to point: CGPoint, in mapView: MKMapView, threshold: CGFloat) -> UUID? {
        let coord   = mapView.convert(point, toCoordinateFrom: mapView)
        let spanLat = mapView.region.span.latitudeDelta
        let spanLon = mapView.region.span.longitudeDelta
        let h = max(1.0, Double(mapView.bounds.height))
        let w = max(1.0, Double(mapView.bounds.width))
        let padLat = Double(threshold) * spanLat / h
        let padLon = Double(threshold) * spanLon / w

        var best: (id: UUID, dist: CGFloat)? = nil
        let filtered = appState.filteredRouteIds

        for (routeId, route) in routeIndex where filtered.contains(routeId) {
            let b = route.boundingBox
            guard coord.latitude  >= b.minLat - padLat,
                  coord.latitude  <= b.maxLat + padLat,
                  coord.longitude >= b.minLon - padLon,
                  coord.longitude <= b.maxLon + padLon
            else { continue }

            guard let polyline = polylineStore[routeId] else { continue }
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
        let ab   = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let ap   = CGPoint(x: p.x - a.x, y: p.y - a.y)
        let len2 = ab.x * ab.x + ab.y * ab.y
        guard len2 > 0 else { return hypot(ap.x, ap.y) }
        let t       = max(0, min(1, (ap.x * ab.x + ap.y * ab.y) / len2))
        let closest = CGPoint(x: a.x + t * ab.x, y: a.y + t * ab.y)
        return hypot(p.x - closest.x, p.y - closest.y)
    }

    // MARK: Map fitting

    @objc func handleFitAll() {
        guard let mapView, !routeIndex.isEmpty else { return }
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
              let route   = routeIndex[routeId],
              let mapView else { return }
        let b = route.boundingBox
        applyRegion(mapView, minLat: b.minLat, maxLat: b.maxLat, minLon: b.minLon, maxLon: b.maxLon)
    }

    @objc func handleZoomToRoutes(_ notification: Notification) {
        guard let ids = notification.object as? [UUID], let mapView else { return }
        let routes = ids.compactMap { routeIndex[$0] }
        guard !routes.isEmpty else { return }
        var minLat =  Double.infinity, maxLat = -Double.infinity
        var minLon =  Double.infinity, maxLon = -Double.infinity
        for route in routes {
            let b = route.boundingBox
            if b.minLat < minLat { minLat = b.minLat }
            if b.maxLat > maxLat { maxLat = b.maxLat }
            if b.minLon < minLon { minLon = b.minLon }
            if b.maxLon > maxLon { maxLon = b.maxLon }
        }
        applyRegion(mapView, minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon)
    }

    private func isLocationAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        #if os(macOS)
        return status == .authorized || status == .authorizedAlways
        #else
        return status == .authorizedWhenInUse || status == .authorizedAlways
        #endif
    }

    @objc func handleZoomToUserLocation() {
        guard let mapView else { return }
        let status = locationManager.authorizationStatus
        print(status == .notDetermined)
        if status == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        } else if isLocationAuthorized(status) {
            mapView.showsUserLocation = true
            if let location = mapView.userLocation.location {
                let region = MKCoordinateRegion(
                    center: location.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                )
                mapView.setRegion(region, animated: true)
            }
        }
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let authorized = isLocationAuthorized(status)
        if authorized {
            mapView?.showsUserLocation = true
            if let location = mapView?.userLocation.location {
                let region = MKCoordinateRegion(
                    center: location.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                )
                mapView?.setRegion(region, animated: true)
            }
        }
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

#if os(macOS)
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
            object: appState
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(MapViewCoordinator.handleZoomToRoute(_:)),
            name: .zoomToRoute,
            object: nil
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(MapViewCoordinator.handleZoomToRoutes(_:)),
            name: .zoomToRoutes,
            object: nil
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(MapViewCoordinator.handleZoomToUserLocation),
            name: .zoomToUserLocation,
            object: appState
        )
        return mapView
    }

    func updateNSView(_ mapView: HoverableMapView, context: Context) {
        let coord = context.coordinator
        let currentIds = appState.routes.map { $0.id }
        let filtered = appState.filteredRouteIds

        if currentIds != coord.lastRouteIds {
            coord.updateOverlays(on: mapView)
        } else if filtered != coord.lastFilteredRouteIds {
            coord.rebuildAllGroupOverlays(on: mapView)
        } else if appState.selectedRouteIds != coord.lastSelectedIds
                    || appState.hoveredRouteId != coord.lastHoveredId {
            coord.updateActiveState(on: mapView)
        }
    }
}
#else
struct MapView: UIViewRepresentable {
    @ObservedObject var appState: AppState

    func makeCoordinator() -> MapViewCoordinator {
        MapViewCoordinator(appState: appState)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        context.coordinator.mapView = mapView
        mapView.delegate = context.coordinator
        mapView.showsCompass = true
        mapView.showsScale = true

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(MapViewCoordinator.handleTap(_:))
        )
        mapView.addGestureRecognizer(tap)

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(MapViewCoordinator.handleFitAll),
            name: .fitAllRoutes,
            object: appState
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(MapViewCoordinator.handleZoomToRoute(_:)),
            name: .zoomToRoute,
            object: nil
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(MapViewCoordinator.handleZoomToRoutes(_:)),
            name: .zoomToRoutes,
            object: nil
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(MapViewCoordinator.handleZoomToUserLocation),
            name: .zoomToUserLocation,
            object: appState
        )
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        let coord = context.coordinator
        let currentIds = appState.routes.map { $0.id }
        let filtered = appState.filteredRouteIds

        if currentIds != coord.lastRouteIds {
            coord.updateOverlays(on: mapView)
        } else if filtered != coord.lastFilteredRouteIds {
            coord.rebuildAllGroupOverlays(on: mapView)
        } else if appState.selectedRouteIds != coord.lastSelectedIds
                    || appState.hoveredRouteId != coord.lastHoveredId {
            coord.updateActiveState(on: mapView)
        }
    }
}
#endif
