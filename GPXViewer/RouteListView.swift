import SwiftUI

// MARK: - Formatters

private let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .none
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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Routes")
                    .font(.headline)
                Spacer()
                Button(action: { appState.openFilePicker() }) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Open GPX files")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            if appState.routes.isEmpty {
                emptyState
            } else {
                routeList
            }
        }
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
            Text("Drop GPX files here\nor use File → Open")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    private var routeList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(appState.routes) { route in
                    RouteRowView(route: route)
                    Divider().padding(.leading, 32)
                }
            }
        }
    }
}

// MARK: - RouteRowView

struct RouteRowView: View {
    let route: GPXRoute
    @EnvironmentObject var appState: AppState
    @State private var isHovering = false

    private var isSelected: Bool { appState.selectedRouteId == route.id }
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

                Button(action: {
                    withAnimation(.easeOut(duration: 0.15)) {
                        appState.removeRoute(id: route.id)
                    }
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .opacity(isHovering || isSelected ? 1 : 0)
                .help("Remove route")
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
        .onHover { hovering in
            isHovering = hovering
            appState.hoveredRouteId = hovering ? route.id : nil
        }
        .onTapGesture(count: 2) {
            NotificationCenter.default.post(name: .zoomToRoute, object: route.id)
        }
        .onTapGesture(count: 1) {
            appState.selectedRouteId = (appState.selectedRouteId == route.id) ? nil : route.id
        }
        .contextMenu {
            Button("Zoom to Route") {
                NotificationCenter.default.post(name: .zoomToRoute, object: route.id)
            }
            Button("Remove") {
                appState.removeRoute(id: route.id)
            }
            Button("Deselect") {
                appState.selectedRouteId = nil
            }
            .disabled(appState.selectedRouteId != route.id)
        }
    }

    @ViewBuilder
    private var statsView: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let start = route.startTime {
                HStack(spacing: 4) {
                    Text(dateFormatter.string(from: start))
                    Text("·")
                    Text(timeFormatter.string(from: start))
                    if let end = route.endTime, end != start {
                        Text("–")
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
                Color(NSColor.selectedContentBackgroundColor).opacity(0.08)
            } else {
                Color.clear
            }
        }
    }
}
