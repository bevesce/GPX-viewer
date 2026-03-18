# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Install

```bash
./build/install.sh        # Build Release + install to /Applications/Gpxex.app
```

Manual build:
```bash
xcodebuild -project Gpxex.xcodeproj -scheme Gpxex -configuration Release -destination 'platform=macOS'
```

No test suite is configured. No external dependencies — pure Swift + Foundation + MapKit.

## Architecture

A cross-platform (macOS 13+, iOS 18+) GPX track viewer built in SwiftUI + MapKit. Performance-optimized to handle 400+ GPX files.

### Data flow

1. User drops/opens `.gpx` files → `AppState` loads them concurrently on a background queue
2. `GPXParser` parses XML (SAX-style), simplifies coordinates (Douglas-Peucker ε=0.0001°), and writes a binary cache keyed by file mod-date
3. Parsed `GPXRoute` structs (with full + simplified coords, bounding box, metadata) are batch-inserted to the main thread (40 at a time)
4. `MapView` renders routes as `MKPolyline` overlays, grouped into 10 `MKMultiPolyline` overlays (one per color) for inactive routes plus individual overlays for hovered/selected routes

### Key files

| File | Role |
|------|------|
| `AppState.swift` | Central `@StateObject`; manages routes array, selection set, loading progress, file persistence |
| `GPXParser.swift` | SAX XML parsing, Douglas-Peucker decimation, binary cache read/write |
| `GPXRoute.swift` | Route data model; 10-color palette, bounding box, distance/duration |
| `MapView.swift` | `MKMapView` wrapper, coordinator (delegate), overlay management, renderer caching |
| `ContentView.swift` | Top-level layout: `NavigationSplitView` (macOS) / sheet drawer (iOS) |
| `RouteListView.swift` | Filterable/sortable sidebar list with shift-click multi-select |

### Performance model

`plan.md` tracks the optimization roadmap. The main structural optimization is **P4** (MKMultiPolyline grouping): 10 color-group overlays for inactive routes + individual overlays for active routes, reducing MapKit overlay count from O(n) to O(12). Other active optimizations: renderer caching (P3), pan detection to skip redraws (P1), spatial bounding-box pre-filter for hit-testing, parallel parsing with `concurrentPerform`, and binary parse cache.

### Platform conditionals

Heavy use of `#if os(macOS)` / `#if os(iOS)` throughout. macOS uses `HoverableMapView` (custom `MKMapView` subclass for mouse tracking) and `NSNotification`-based commands (`fitAllRoutes`, `zoomToRoute`, etc.). iOS uses security-scoped bookmarks for file persistence.

### macOS keyboard shortcuts

- `Cmd+O` — open files
- `Cmd+Shift+F` — fit all routes
- `Cmd+Delete` — remove selected routes
