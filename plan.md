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

Simplified routes average ~200 pts (was ~1 840). This reduced the hit-test scan ~10× and dropped
the "all renderers on hover" redraws from 474 to 2.

---

## Remaining bottlenecks (re-evaluated)

---

### A. Spatial index for hover hit-testing (was #3 — still the biggest bottleneck)

**Problem:** `nearestRoute` still does an O(N × M) scan on every `mouseMoved` event.
With simplified routes the numbers are now 474 routes × ~200 pts × 60 Hz ≈ **5.7 M segment
comparisons/second** on the main thread. The original 52 M is gone, but 5.7 M is still
enough to cause stutter, especially while the list is also scrolling or SwiftUI is animating.

**Fix:**
- After each `updateOverlays`, build a flat array of axis-aligned bounding boxes (one per route).
- On `mouseMoved`, convert the cursor to map coordinates, expand it by the hit threshold (≈ 20 m),
  and reject any route whose bounding box does not intersect that expanded point.
- Only run the segment scan on the small candidate set (typically 1–5 routes out of 474).
- Bounding boxes are just `(minLat, maxLat, minLon, maxLon)` — trivial to compute from the
  existing `simplified` arrays; no third-party library needed.

**Expected gain:** Hit-test per frame drops from O(N × M) to O(N) bounding-box tests +
O(k × M) precise tests where k ≈ 1–5. Mouse lag disappears.

---

### B. Route lookup dictionary (new — O(N) linear scans in hot paths)

**Problem:** `appState.routes.first(where: { $0.id == routeId })` appears in four hot paths:

1. `mapView(_:rendererFor:)` — called 474 times during initial load → O(N²) total
2. `regionDidChangeAnimated` — called after every pan/zoom, iterates all overlays and
   calls `routes.first` for each → O(N²) per gesture end
3. `refreshRenderers` — O(N) per changed ID (minor, at most 4 IDs)
4. `handleZoomToRoute` — one-off, negligible

With 474 routes, items 1 and 2 are each ~224 k comparisons per call.

**Fix:**
- Add `var routeIndex: [UUID: GPXRoute] = [:]` to `MapViewCoordinator`.
- Keep it in sync in `updateOverlays` (insert on add, remove on delete).
- Replace every `routes.first(where:)` call in the coordinator with a direct dictionary lookup.

**Expected gain:** `rendererFor` and `regionDidChangeAnimated` drop from O(N²) to O(N).
Combined with fix A, `regionDidChangeAnimated` becomes a tight O(N) loop with no allocations.

---

### C. `fitMap` reads all full-resolution coordinates (new)

**Problem:** `fitMap(_ mapView:)` calls `appState.routes.flatMap { $0.coordinates }` —
flattening all **870 000 original** (non-simplified) coordinates just to find four min/max
values. This runs on the main thread and is called after every load batch completes.

**Fix:**
- Store a `boundingBox: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)` on
  `GPXRoute`, computed at parse time from `simplified` (bounding box is lossless under
  decimation).
- `fitMap` reduces to a single pass over 474 `boundingBox` structs — 474 comparisons instead
  of 870 000 coordinate reads.

**Expected gain:** `fitMap` goes from ~870 k iterations to 474. Noticeable on slower machines
and eliminates a spike at the end of the load batch.

---

### D. `regionDidChangeAnimated` calls `setNeedsDisplay` on all 474 renderers (refinement)

**Problem:** Every pan or zoom end currently iterates all overlays, does an O(N) route lookup
per overlay (see B above), and calls `setNeedsDisplay()` on every renderer. With fix B the
lookup becomes O(1), but all 474 `setNeedsDisplay()` calls remain.

This is **correct behaviour** (line width changes with zoom), but the implementation can be
tightened:

**Fix (after B is done):**
- Use `overlayMap.values` instead of `mapView.overlays` to avoid casting each overlay.
- Use the `routeIndex` dictionary instead of `routes.first`.
- Consider calling `mapView.setNeedsDisplay()` (the whole tile) rather than per-renderer if
  MapKit batches that more efficiently — profile to confirm.

**Expected gain:** Removes the O(N²) lookup overhead. The 474 `setNeedsDisplay()` calls remain
but are cheap GPU work; the CPU cost drops to a single tight O(N) loop.

---

### E. Mouse event throttling + off-thread hit testing (new)

**Problem:** `mouseMoved` fires at the display refresh rate (60–120 Hz). Even after fix A,
the hit-test (bounding box filter + segment scan) runs synchronously on the main thread before
each frame. This competes with SwiftUI layout, MapKit tile loading, and list scrolling.

**Fix (two-part):**
1. **Throttle:** Skip `mouseMoved` events if a hit-test is already queued. A simple
   `var pendingHitTest = false` flag on the coordinator is enough — set it on entry,
   clear it on completion.
2. **Background dispatch:** Move the `nearestRoute` computation to a dedicated serial queue
   (e.g. `DispatchQueue(label: "gpx.hittest", qos: .userInteractive)`). Only dispatch back to
   main to write `hoveredRouteId`.

**Expected gain:** Main thread is never blocked by hit-testing. At 120 Hz, skipped frames cost
nothing; the hover still updates faster than the eye can track.

---

### F. Virtual list in the sidebar (was #6)

**Problem:** `LazyVStack` inside `ScrollView` does not fully defer view creation. SwiftUI
still measures and lays out all 474 rows when the list first appears, consuming CPU and memory
proportional to N.

**Fix:**
- Replace `ScrollView + LazyVStack` with `List`. On macOS 13+ `List` uses true NSTableView
  cell reuse under the hood — only visible rows (~20) are live at any time.
- The `ScrollViewReader` / `.scrollTo` mechanism works identically with `List`.

**Expected gain:** Initial list render and memory cost drop from O(N) to O(visible rows).
Sidebar becomes instant regardless of route count.

---

### G. Haversine distance replaces CLLocation allocs (was #7)

**Problem:** `GPXParser` allocates one `CLLocation` object per point pair to call
`distance(from:)`. For a 28 000-point file this is 28 000 object allocations + ARC overhead,
all during background parsing.

**Fix:**
- Replace with the haversine formula operating directly on `Double` lat/lon:
  ```swift
  func haversine(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
      let R = 6_371_000.0
      let dLat = (b.latitude  - a.latitude)  * .pi / 180
      let dLon = (b.longitude - a.longitude) * .pi / 180
      let sinLat = sin(dLat / 2), sinLon = sin(dLon / 2)
      let h = sinLat*sinLat + cos(a.latitude * .pi/180) * cos(b.latitude * .pi/180) * sinLon*sinLon
      return 2 * R * asin(min(1, sqrt(h)))
  }
  ```
- No allocations, same accuracy, compiler can auto-vectorise the loop.

**Expected gain:** Parse time for large files reduced ~30–40%. More relevant as dataset grows.

---

### H. On-demand full-resolution coordinates (was #8 — lower priority)

**Problem:** All 870 000 original `coordinates` are held in memory even though the map only
ever renders `simplified`. The full arrays are only used for `handleZoomToRoute` (bounding
box fit), which after fix C only needs the bounding box anyway.

**Fix (after C):**
- Remove `coordinates` from `GPXRoute`. Keep only `simplified` and `boundingBox`.
- Re-parse `coordinates` on demand (or use `mmap`) only if a "show full resolution" feature
  is added later.

**Expected gain:** ~12 MB of coordinate data freed (~870 k × 16 bytes). Useful if dataset
grows to thousands of files or on low-memory machines.

---

### I. Cluster/hide overlays at low zoom (was #9)

**Problem:** At world/country zoom, 474 polylines collapsed to near-zero pixel size produce
GPU overdraw with no visual value, and MapKit still processes all tile intersections for them.

**Fix:**
- In `regionDidChangeAnimated`, when span > threshold (e.g. 8°), hide overlays whose
  bounding box diagonal is < 2 px at the current scale.
- Re-show them when the user zooms back in.
- Use `MKOverlay.canReplaceMapContent` = false and swap between a thin summary polyline and
  the full simplified one.

**Expected gain:** GPU load and MapKit tile-intersection work drop significantly at low zoom.
Most impactful when routes are geographically spread (e.g. one per city across a country).

---

## Updated priority order

| Priority | Item | Effort | Impact |
|----------|------|--------|--------|
| 1 | **B** Route lookup dictionary | Low | High — removes O(N²) in two hot paths |
| 2 | **C** Bounding box on GPXRoute | Low | Medium — eliminates 870k coord scan on fit |
| 3 | **A** Spatial index for hover | Medium | Very high — kills remaining main-thread hittest spike |
| 4 | **E** Mouse throttle + off-thread hittest | Low | High — main thread never blocks on mouse |
| 5 | **D** `regionDidChangeAnimated` tighten | Low | Medium — only effective after B |
| 6 | **F** Virtual list | Medium | Medium — sidebar with 474+ routes |
| 7 | **G** Haversine distance | Low | Low-medium — parse speed |
| 8 | **H** Drop full coordinates | Low (after C) | Low-medium — memory |
| 9 | **I** Cluster at low zoom | High | Low-medium — GPU polish |

B and C are cheap wins that unblock the bigger gains in A and D. Do B → C → A → E in order.
