# GPX Viewer — Performance Improvement Plan

Dataset baseline: 474 files, ~84 MB on disk, ~870 000 total track points.

---

## Completed

| Item | Change |
|------|--------|
| 1 | Background loading with batching |
| 2 | Coordinate decimation (Douglas-Peucker, ε = 0.0001°) |
| 4 | Incremental overlay management (`[UUID: MKPolyline]` dict) |
| 5 | Lazy renderer refresh (only touch changed IDs on hover/select) |
| A | Spatial index for hover hit-testing (bounding-box pre-filter) |
| B | Route lookup dictionary (`routeIndex`) — O(1) everywhere |
| C | `RouteBoundingBox` on `GPXRoute`; `fitMap` uses bounding boxes |
| Parallel | `concurrentPerform` across all cores for parsing |
| Cache | Binary parse cache validated by file modification date |

---

## Zoom and pan performance (new section)

The map becomes sluggish with 474 routes because of how MapKit processes overlays.
The problems are distinct for pan vs zoom.

---

### P1. `regionDidChangeAnimated` refreshes all 474 renderers on every pan (quick win)

**Root cause:** `regionDidChangeAnimated` fires after both pan and zoom. The current code
unconditionally calls `applyStyle` + `setNeedsDisplay()` on all 474 renderers every time.
After a pure pan the span has not changed, so `scaledLineWidth` returns the same value as
before — the 474 redraws are completely wasted.

**Fix:**
```swift
private var lastSpan: Double = 0

func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
    let newSpan = mapView.region.span.latitudeDelta
    guard abs(newSpan - lastSpan) / max(lastSpan, 1e-9) > 0.01 else { return } // <1% change
    lastSpan = newSpan
    currentSpan = newSpan
    // ... existing renderer refresh loop
}
```
A 1 % threshold means line widths only update when the user actually zooms; panning is free.

**Expected gain:** Zero renderer work during pan. Eliminates 474 × `setNeedsDisplay()` after
every drag gesture end.

---

### P2. `setNeedsDisplay()` called on off-screen overlays after zoom

**Root cause:** After a zoom, we refresh all 474 renderers even when the viewport shows only
a small area (e.g. one city). Routes in other cities have no rendered tiles in the current
view, so their `setNeedsDisplay()` causes MapKit to schedule tile invalidation work that
produces no visible change.

**Fix:** Filter by the visible region before refreshing. In `regionDidChangeAnimated`, skip
any route whose `boundingBox` does not intersect the current `mapView.region`:

```swift
let region = mapView.region
let visMinLat = region.center.latitude  - region.span.latitudeDelta  / 2
let visMaxLat = region.center.latitude  + region.span.latitudeDelta  / 2
let visMinLon = region.center.longitude - region.span.longitudeDelta / 2
let visMaxLon = region.center.longitude + region.span.longitudeDelta / 2

for (routeId, polyline) in overlayMap {
    guard let route = routeIndex[routeId] else { continue }
    let b = route.boundingBox
    guard b.maxLat >= visMinLat, b.minLat <= visMaxLat,
          b.maxLon >= visMinLon, b.minLon <= visMaxLon
    else { continue }   // off-screen — skip
    // applyStyle + setNeedsDisplay
}
```

**Expected gain:** When zoomed into one city out of 474 routes spread across a country,
only the ~10–30 visible routes are refreshed instead of all 474.

---

### P3. `mapView.renderer(for:)` called 474 times per zoom end

**Root cause:** `mapView.renderer(for: polyline)` is a MapKit API call with non-trivial
internal overhead (it looks up a renderer registry). We call it 474 times every time
the region changes.

**Fix:** Cache renderer references alongside `overlayMap`:
```swift
private var rendererCache: [UUID: MKPolylineRenderer] = [:]
```
Populate in `mapView(_:rendererFor:)` (called once per overlay on first render):
```swift
func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
    let renderer = MKPolylineRenderer(polyline: polyline)
    // ... applyStyle ...
    rendererCache[routeId] = renderer   // store reference
    return renderer
}
```
Evict in `updateOverlays` when overlays are removed. In `regionDidChangeAnimated` and
`refreshRenderers`, use `rendererCache[routeId]` instead of `mapView.renderer(for:)`.

**Expected gain:** 474 MapKit API calls per gesture → 474 direct dictionary lookups.
Measurable reduction in the post-zoom spike, especially on older hardware.

---

### P4. 474 independent `MKPolyline` overlays — the fundamental bottleneck

**Root cause:** MapKit's rendering pipeline processes each overlay independently. For every
map tile that enters the viewport during a pan, MapKit checks all 474 overlays for
intersection, rasterizes the intersecting ones, and composites them. With 474 overlays
this work is O(N) per tile per frame. Apple's own guidance is to keep overlay counts below
~100 for smooth scrolling.

**Fix — `MKMultiPolyline` grouping:**

Group inactive routes by their color slot (the palette has 10 colors) into 10
`MKMultiPolyline` overlays instead of 474 individual `MKPolyline` overlays. `MKMultiPolyline`
was introduced in macOS 10.15 and is rendered as a single draw call per group.

- Steady-state overlay count: **10 group overlays + 0–2 individual overlays** for the active
  (hovered/selected) route(s), which need distinct styling.
- On hover/selection: pull the route out of its group multi-polyline, replace the group with
  a version that excludes it, and add a styled individual polyline on top. Reverse on
  deselect.
- Requires rebuilding the multi-polyline for the affected color group (~47 routes) on each
  state change — acceptable since it only happens on click/hover.

**Expected gain:** MapKit tile-intersection and rasterization work drops from O(474) to O(12)
per tile. Pan and zoom become significantly smoother, especially at country-level zoom where
all routes are visible.

---

### P5. Viewport culling — remove off-screen overlays entirely

**Root cause:** Even overlays that are completely outside the visible region remain registered
with MapKit and contribute to its internal spatial bookkeeping. When the user pans, MapKit
re-evaluates all 474 overlays to decide which tiles to render.

**Fix:**
- In `regionDidChangeAnimated`, compute the visible region (with a 20 % buffer for
  pre-loading).
- Remove overlays whose `boundingBox` falls entirely outside the buffered region.
- Re-add them when the user pans toward them.
- Use the existing `overlayMap` / `routeIndex` to track which routes are currently
  "mounted" vs "dormant".

This requires careful bookkeeping (a third set, `dormantRoutes`, alongside `overlayMap`)
but the logic is straightforward.

**Expected gain:** If the user is viewing one city, ~30 routes are mounted in MapKit instead
of 474. Tile-intersection work and rasterization are proportional to mounted count.
Complements P4 well — P4 reduces overlay count structurally, P5 reduces it dynamically.

---

### P6. Ultra-simplified coordinates at low zoom (LOD)

**Root cause:** At country/world zoom (span > 2°), the 200-point simplified polylines still
have segments shorter than 1 pixel. MapKit rasterizes all of them anyway.

**Fix:**
- Pre-compute a second `ultraSimplified` array at parse time with `epsilon = 0.002°` (~220 m).
  Typical route shrinks from ~200 pts to ~20 pts.
- In `regionDidChangeAnimated`, when span crosses the 2° threshold, rebuild affected overlays
  using `ultraSimplified` instead of `simplified`. Reverse when zooming back in.
- The swap is triggered at most twice per zoom gesture (once crossing the threshold each way).

**Expected gain:** At country zoom, rasterized segment count drops 10× again (200 → 20 pts
per route). GPU tile generation becomes proportionally cheaper.

---

### P7. Custom tile overlay — long-term solution

**Root cause:** All of the above are mitigations. The fundamental problem is that
`MKPolylineRenderer` renders each route separately into MapKit's tile system. There is no
batch path.

**Fix:** Replace all `MKPolyline` overlays with a single `MKTileOverlay` subclass that
rasterizes all routes using Core Graphics directly into 256×256 tile images.

- MapKit caches rasterized tiles; pan is just compositing pre-rendered bitmaps — essentially
  free.
- Zoom triggers tile regeneration at the new scale, but only for the visible viewport.
- Selected/hovered routes are drawn on top using a normal `MKPolylineRenderer` (1–2 overlays).
- Tile invalidation on route add/remove: call `reloadData()` on the tile overlay.

This is the largest refactor (~200 lines new code, replace overlay management entirely) but
eliminates the O(N) overlay overhead permanently. Pan becomes native-speed regardless of
route count.

---

## Other remaining items

### E. Mouse event throttling + off-thread hit testing

**Problem:** `mouseMoved` fires at 60–120 Hz. The bounding-box filter + segment scan
(now fast after A) still runs on the main thread, competing with MapKit tile compositing
during pan.

**Fix:**
- Throttle: skip events if a hit-test is already in flight (`var pendingHitTest = false`).
- Dispatch `nearestRoute` to a dedicated serial queue (`qos: .userInteractive`), dispatch
  back to main only to write `hoveredRouteId`.

**Expected gain:** Main thread never stalls on hit-testing during map interaction.

---

### F. Virtual list in the sidebar

**Problem:** `LazyVStack` in `ScrollView` still creates all 474 rows on first render.

**Fix:** Replace with `List` (true `NSTableView` cell reuse on macOS 13+).

**Expected gain:** Sidebar render and memory cost drop from O(N) to O(visible rows).

---

### G. Haversine distance replaces `CLLocation` allocations

**Fix:** Replace `CLLocation.distance(from:)` with the haversine formula on `Double`.
No allocations, same accuracy.

**Expected gain:** ~30–40% faster parse for large files.

---

### H. Drop full-resolution `coordinates` array

**Fix (after C):** Remove `GPXRoute.coordinates`; store only `simplified` + `boundingBox`.
Full coords are no longer used anywhere after the `fitMap` refactor.

**Expected gain:** ~12 MB freed (~870 k × 16 bytes).

---

## Priority order

| Priority | Item | Effort | Impact |
|----------|------|--------|--------|
| 1 | **P1** Skip renderer refresh on pan | Very low | High — zero work per drag |
| 2 | **P2** Visible-region filter in `regionDidChangeAnimated` | Low | High — only refresh visible routes |
| 3 | **P3** Cache renderer references | Low | Medium — removes 474 API calls per zoom |
| 4 | **P4** `MKMultiPolyline` grouping | Medium | Very high — 474 → 12 overlays structurally |
| 5 | **E** Mouse throttle + off-thread hittest | Low | High — clean up main thread |
| 6 | **P5** Viewport culling | Medium | High — complements P4 dynamically |
| 7 | **P6** Ultra-simplified LOD | Low | Medium — fewer GPU segments at low zoom |
| 8 | **F** Virtual list | Medium | Medium — sidebar |
| 9 | **G** Haversine distance | Low | Low-medium — parse speed |
| 10 | **H** Drop full coordinates | Low | Low-medium — memory |
| 11 | **P7** Custom tile overlay | High | Very high — permanent fix, big refactor |

P1–P3 are all cheap and can be done together in one pass. P4 is the highest-leverage
structural fix. P7 is the endgame if P4 is still not smooth enough.
