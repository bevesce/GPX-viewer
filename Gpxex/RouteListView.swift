import SwiftUI

// MARK: - Formatters

private let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

private let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .none
    f.timeStyle = .short
    return f
}()

private func formatDuration(_ interval: TimeInterval) -> String {
    let total = Int(interval)
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 {
        return "\(h)h \(m)m"
    } else if m > 0 {
        return "\(m)m \(s)s"
    } else {
        return "\(s)s"
    }
}

private func formatDistance(_ metres: Double) -> String {
    if metres >= 1000 {
        let km = metres / 1000
        if km == km.rounded() { return String(format: "%.0f km", km) }
        return String(format: km >= 100 ? "%.0f km" : "%.1f km", km)
    } else {
        return String(format: "%.0f m", metres)
    }
}

// MARK: - RouteListView

struct RouteListView: View {
    @EnvironmentObject var appState: AppState
    @Binding var searchText: String
    #if os(iOS)
    @Binding var selectedDetent: PresentationDetent
    @FocusState private var searchFocused: Bool
    #endif

    private var maxRouteDistance: Double { appState.maxRouteDistance }

    private var isDistanceFiltered: Bool {
        let maxDist = maxRouteDistance
        return maxDist > 0 && (appState.distanceFilterLow > 1 || appState.distanceFilterHigh < maxDist - 1)
    }

    private var filteredRoutes: [GPXRoute] {
        var base = appState.routes

        if !searchText.isEmpty {
            let q = searchText.lowercased()
            base = base.filter { route in
                if route.fileName.lowercased().contains(q) { return true }
                if let date = route.startTime, dateFormatter.string(from: date).contains(q) { return true }
                return false
            }
        }

        if isDistanceFiltered {
            base = base.filter { $0.totalDistance >= appState.distanceFilterLow && $0.totalDistance <= appState.distanceFilterHigh }
        }

        if appState.showOnlyVisibleRoutes, let bbox = appState.visibleBBox {
            base = base.filter { route in
                let b = route.boundingBox
                return b.maxLat >= bbox.minLat && b.minLat <= bbox.maxLat
                    && b.maxLon >= bbox.minLon && b.minLon <= bbox.maxLon
            }
        }

        return base.sorted { lhs, rhs in
            switch (lhs.startTime, rhs.startTime) {
            case (let a?, let b?): return a > b
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return false
            }
        }
    }

    var body: some View {
        #if os(iOS)
        content
            .safeAreaInset(edge: .top, spacing: 0) { filterHeader }
        #else
        filterHeader
        content
        #endif
    }

    private var filterHeader: some View {
        VStack(spacing: 0) {
            searchBar
            if maxRouteDistance > 0 {
                #if os(iOS)
                if selectedDetent != .height(80) {
                    distanceFilterView
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                #else
                distanceFilterView
                #endif
            }
            // Loading progress bar — sits flush at the bottom of the header
            if let progress = appState.loadingProgress {
                ProgressView(value: max(progress, 0.02))
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .animation(.linear(duration: 0.2), value: progress)
                    #if os(iOS)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 4)
                    #else
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
                    #endif
            }
        }
        #if os(iOS)
        .background(.thinMaterial)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: selectedDetent)
        #endif
        .onChange(of: maxRouteDistance) { _, newMax in
            if newMax > 0 && appState.distanceFilterHigh < 1 {
                appState.distanceFilterHigh = newMax
            } else if newMax > appState.distanceFilterHigh && !isDistanceFiltered {
                appState.distanceFilterHigh = newMax
            }
        }
    }

    private var content: some View {
        #if os(iOS)
        routeList
        #else
        Group {
            if appState.routes.isEmpty {
                emptyState
            } else {
                routeList
            }
        }
        #endif
    }

    private var distanceFilterView: some View {
        DistanceRangeSlider(
            low: Binding(get: { appState.distanceFilterLow }, set: { appState.distanceFilterLow = $0 }),
            high: Binding(get: { appState.distanceFilterHigh }, set: { appState.distanceFilterHigh = $0 }),
            maxDistance: maxRouteDistance
        )
        #if os(iOS)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        #else
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        #endif
    }

    private var searchBar: some View {
        HStack(spacing: 0) {
            TextField("Search", text: $searchText)
                #if os(iOS)
                .focused($searchFocused)
                .onChange(of: searchFocused) { _, focused in
                    if focused { selectedDetent = .large }
                }
                #endif
                .safeAreaInset(edge: .leading, content: {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                })
                .safeAreaInset(edge: .trailing, content: {
                    HStack(spacing: 4) {
                        if !searchText.isEmpty {
                            Button(action: { searchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        Button {
                            appState.showOnlyVisibleRoutes.toggle()
                        } label: {
                            Image(systemName: appState.showOnlyVisibleRoutes ? "map.fill" : "map")
                                .foregroundColor(appState.showOnlyVisibleRoutes ? .accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                })
                #if os(iOS)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.gray.opacity(0.25), in: .capsule)
                #else
                .textFieldStyle(.roundedBorder)
                #endif
        }
        #if os(iOS)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        #else
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        #endif
    }

    private var searchBarBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color.clear
        #endif
    }

    private var headerBackground: some View {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Rectangle().fill(.ultraThinMaterial)
        #endif
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            #if os(macOS)
            Spacer()
            #endif
            Image(systemName: "map")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text("No routes loaded")
                .font(.headline)
                .foregroundColor(.secondary)
            #if os(macOS)
            Text("Drop GPX files here\nor use File \u{2192} Open")
            #else
            Text("Tap + to open GPX files")
            #endif
            #if os(macOS)
            Spacer()
            #endif
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding()
    }

    private var routeList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    let routes = filteredRoutes
                    if routes.isEmpty {
                        Text("No routes")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 32)
                    } else {
                        ForEach(routes) { route in
                            RouteRowView(route: route, allRoutes: routes)
                                .id(route.id)
                            Divider().padding(.leading, 32)
                        }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .scrollToRoute)) { note in
                guard let routeId = note.object as? UUID else { return }
                withAnimation {
                    proxy.scrollTo(routeId, anchor: .center)
                }
            }
        }
    }
}

// MARK: - RouteRowView

struct RouteRowView: View {
    let route: GPXRoute
    let allRoutes: [GPXRoute]
    @EnvironmentObject var appState: AppState
    #if os(macOS)
    @Environment(\.openWindow) var openWindow
    #endif
    @State private var isHovering = false
    #if os(macOS)
    @State private var showingRename = false
    #endif

    private var isSelected: Bool { appState.selectedRouteIds.contains(route.id) }
    private var isHighlighted: Bool { appState.hoveredRouteId == route.id }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                // Title row
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(route.color.swiftUI)
                        .frame(width: 14, height: 14)
                        .shadow(color: route.color.swiftUI.opacity(0.4), radius: 2)

                    Text(route.fileName)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                // Stats row
                if route.startTime != nil || route.totalDistance > 0 {
                    statsView
                        .padding(.leading, 24)
                }
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(route.color.swiftUI)
                    .font(.system(size: 14))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(rowBackground)
        .contentShape(Rectangle())
        #if os(macOS)
        .onHover { hovering in
            isHovering = hovering
            appState.hoveredRouteId = hovering ? route.id : nil
        }
        #endif
        .onTapGesture(count: 2) {
            NotificationCenter.default.post(name: .zoomToRoute, object: route.id)
        }
        .onTapGesture(count: 1) {
            #if os(macOS)
            let mods = NSEvent.modifierFlags
            appState.handleListTap(route: route, modifiers: mods, visibleRoutes: allRoutes)
            #else
            appState.handleListTap(route: route, visibleRoutes: allRoutes)
            #endif
        }
        .contextMenu {
            Button(appState.selectedRouteIds.contains(route.id) && appState.selectedRouteIds.count > 1
                   ? "Zoom to Selected" : "Zoom to Route") {
                if appState.selectedRouteIds.contains(route.id) && appState.selectedRouteIds.count > 1 {
                    NotificationCenter.default.post(name: .zoomToRoutes, object: Array(appState.selectedRouteIds))
                } else {
                    NotificationCenter.default.post(name: .zoomToRoute, object: route.id)
                }
            }
            #if os(macOS)
            Button("Open in New Tab") {
                let selected = appState.selectedRouteIds
                let routesToOpen: [GPXRoute]
                if selected.contains(route.id) {
                    routesToOpen = appState.routes.filter { selected.contains($0.id) }
                } else {
                    routesToOpen = [route]
                }
                PendingTabRoutes.shared.enqueue(routesToOpen)
                openWindow(id: "main")
            }
            Divider()
            Button("Edit") {
                showingRename = true
            }
            #endif
            Button(appState.selectedRouteIds.contains(route.id) && appState.selectedRouteIds.count > 1
                   ? "Remove Selected" : "Remove") {
                if appState.selectedRouteIds.contains(route.id) {
                    appState.removeSelectedRoutes()
                } else {
                    appState.removeRoute(id: route.id)
                }
            }
        }
        #if os(macOS)
        .sheet(isPresented: $showingRename) {
            RenameRouteView(route: route) { newName in
                try appState.renameRoute(id: route.id, newName: newName)
            }
        }
        #endif
    }

    @ViewBuilder
    private var statsView: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let start = route.startTime {
                HStack(spacing: 4) {
                    Text(dateFormatter.string(from: start))
                    Text("\u{00B7}")
                    Text(timeFormatter.string(from: start))
                    if let end = route.endTime, end != start {
                        Text("\u{2013}")
                        Text(timeFormatter.string(from: end))
                    }
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            }

            HStack(spacing: 8) {
                if let dur = route.duration {
                    Label(formatDuration(dur), systemImage: "clock")
                }
                if route.totalDistance > 0 {
                    Label(formatDistance(route.totalDistance), systemImage: "arrow.triangle.swap")
                }
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary)
        }
    }

    private var rowBackground: some View {
        Group {
            if isSelected {
                route.color.swiftUI.opacity(0.15)
            } else if isHighlighted || isHovering {
                Color.accentColor.opacity(0.08)
            } else {
                Color.clear
            }
        }
    }
}

// MARK: - DistanceRangeSlider

struct DistanceRangeSlider: View {
    @Binding var low: Double    // metres
    @Binding var high: Double   // metres
    let maxDistance: Double     // metres

    private let thumbR: CGFloat = 10
    private let trackH: CGFloat = 4

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { geo in
                let W = geo.size.width
                let tH = thumbR * 2
                let tY = tH / 2
                let tStart = thumbR
                let tEnd = W - thumbR
                let tW = tEnd - tStart
                let lowX  = tStart + CGFloat(low  / maxDistance) * tW
                let highX = tStart + CGFloat(high / maxDistance) * tW

                ZStack {
                    // Background track
                    Capsule()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: tW, height: trackH)
                        .position(x: W / 2, y: tY)

                    // Active range
                    Capsule()
                        .fill(Color.accentColor.opacity(0.5))
                        .frame(width: max(highX - lowX, 0), height: trackH)
                        .position(x: (lowX + highX) / 2, y: tY)

                    // Low thumb
                    thumbShape
                        .position(x: lowX, y: tY)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("distSlider"))
                            .onChanged { v in
                                let cHighX = tStart + CGFloat(high / maxDistance) * tW
                                let newX = min(max(v.location.x, tStart), cHighX - 2)
                                let raw = max(0.0, Double((newX - tStart) / tW) * maxDistance)
                                low = (raw / 1000).rounded() * 1000
                            }
                        )

                    // High thumb
                    thumbShape
                        .position(x: highX, y: tY)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("distSlider"))
                            .onChanged { v in
                                let cLowX = tStart + CGFloat(low / maxDistance) * tW
                                let newX = min(max(v.location.x, cLowX + 2), tEnd)
                                let raw = min(maxDistance, Double((newX - tStart) / tW) * maxDistance)
                                high = raw >= maxDistance - 500 ? maxDistance : (raw / 1000).rounded() * 1000
                            }
                        )
                }
                .coordinateSpace(name: "distSlider")
                .frame(width: W, height: tH)
            }
            .frame(height: thumbR * 2)

            HStack {
                Text(formatDistance(low))
                Spacer()
                Text(formatDistance(high))
            }
            .font(.system(size: 10))
            .foregroundColor(.secondary)
        }
    }

    private var thumbShape: some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            .frame(width: thumbR * 2, height: thumbR * 2)
    }
}

// MARK: - RouteDetailSheet (iOS long-press popup)

#if !os(macOS)
struct RouteDetailSheet: View {
    let route: GPXRoute
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(route.color.swiftUI)
                    .frame(width: 18, height: 18)
                Text(route.fileName)
                    .font(.headline)
                    .lineLimit(2)
            }

            Divider()

            HStack(spacing: 24) {
                if route.totalDistance > 0 {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(formatDistance(route.totalDistance), systemImage: "arrow.triangle.swap")
                            .font(.system(size: 15))
                    }
                }
                if let dur = route.duration {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(formatDuration(dur), systemImage: "clock")
                            .font(.system(size: 15))
                    }
                }
            }
            .foregroundColor(.primary)

            if let start = route.startTime {
                HStack(spacing: 4) {
                    Text(dateFormatter.string(from: start))
                    Text("\u{00B7}")
                    Text(timeFormatter.string(from: start))
                    if let end = route.endTime, end != start {
                        Text("\u{2013}")
                        Text(timeFormatter.string(from: end))
                    }
                }
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            }

            HStack(spacing: 12) {
                Button {
                    NotificationCenter.default.post(name: .zoomToRoute, object: route.id)
                    appState.longPressedRoute = nil
                } label: {
                    Label("Zoom to Route", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif

// MARK: - RenameRouteView

#if os(macOS)
struct RenameRouteView: View {
    let route: GPXRoute
    let onRename: (String) throws -> Void

    @State private var name: String
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(route: GPXRoute, onRename: @escaping (String) throws -> Void) {
        self.route = route
        self.onRename = onRename
        self._name = State(initialValue: route.fileName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Route")
                .font(.headline)

            TextField("File name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit { commit() }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Rename") { commit() }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name == route.fileName)
            }
        }
        .padding(24)
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != route.fileName else { return }
        do {
            try onRename(trimmed)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
#endif
