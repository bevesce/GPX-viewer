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
        return String(format: km >= 100 ? "%.0f km" : "%.1f km", km)
    } else {
        return String(format: "%.0f m", metres)
    }
}

// MARK: - RouteListView

struct RouteListView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""

    private var filteredRoutes: [GPXRoute] {
        let base: [GPXRoute]
        if searchText.isEmpty {
            base = appState.routes
        } else {
            let q = searchText.lowercased()
            base = appState.routes.filter { route in
                if route.fileName.lowercased().contains(q) { return true }
                if let date = route.startTime, dateFormatter.string(from: date).contains(q) { return true }
                return false
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
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(searchBarBackground, in: RoundedRectangle(cornerRadius: 6))

                Button(action: { appState.openFilePicker() }) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .regular))
                }
                .buttonStyle(.plain)
                .help("Open GPX files")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(headerBackground)

            Divider()

            if appState.routes.isEmpty {
                emptyState
            } else {
                routeList
            }
        }
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
        Color.clear
        #endif
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
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
            Spacer()
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
                        Text("No results")
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
    @State private var isHovering = false
    #if os(macOS)
    @State private var showingRename = false
    #endif

    private var isSelected: Bool { appState.selectedRouteIds.contains(route.id) }
    private var isHighlighted: Bool { appState.hoveredRouteId == route.id }

    var body: some View {
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

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(route.color.swiftUI)
                        .font(.system(size: 14))
                }
            }

            // Stats row
            if route.startTime != nil || route.totalDistance > 0 {
                statsView
                    .padding(.leading, 24)
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
            Button("Zoom to Route") {
                NotificationCenter.default.post(name: .zoomToRoute, object: route.id)
            }
            #if os(macOS)
            Button("Edit") {
                showingRename = true
            }
            #endif
            Button("Remove") {
                appState.removeRoute(id: route.id)
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
