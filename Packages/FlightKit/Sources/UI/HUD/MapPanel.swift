import Autopilot
import MapKit
import Nav
import SwiftUI

/// The moving map: satellite imagery with the aircraft, the route in magenta and the point NAV
/// is flying to. Tap the map to add a point to the route; NAV (here or on the autopilot) flies it.
struct MapPanel: View {
    @Bindable var model: HUDModel
    let onClose: () -> Void
    @State private var camera: MapCameraPosition = .automatic
    @State private var follow = true
    @State private var distance: Double = 40_000
    @State private var region: MKCoordinateRegion?

    /// Navaids and fixes in view, when zoomed in far enough to read them.
    private var shown: (navaids: [Navaid], fixes: [Fix]) {
        guard let nav = model.navData, let r = region, r.span.latitudeDelta < 2.5 else { return ([], []) }
        let c = r.center, s = r.span
        let all = nav.inside(south: c.latitude - s.latitudeDelta / 2, west: c.longitude - s.longitudeDelta / 2,
                             north: c.latitude + s.latitudeDelta / 2, east: c.longitude + s.longitudeDelta / 2, limit: 80)
        // Fixes only when closer in: there are many.
        return (all.navaids, s.latitudeDelta < 1.0 ? all.fixes : [])
    }

    private var aircraft: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: model.latitude, longitude: model.longitude) }

    /// Index of the first route point still ahead.
    private var active: Int { model.navEngaged ? (model.activeWaypoint ?? model.route.count) : 0 }

    var body: some View {
        MapReader { proxy in
            Map(position: $camera) {
                let visible = shown
                ForEach(visible.fixes, id: \.self) { f in
                    Annotation(f.id, coordinate: CLLocationCoordinate2D(latitude: f.latitude, longitude: f.longitude), anchor: .center) {
                        Image(systemName: "triangle")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.85))
                            .allowsHitTesting(false)
                    }
                }
                ForEach(visible.navaids, id: \.self) { n in
                    Annotation(n.id, coordinate: CLLocationCoordinate2D(latitude: n.latitude, longitude: n.longitude), anchor: .center) {
                        Image(systemName: n.isNDB ? "circle.dotted" : "hexagon")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(n.isNDB ? Color(red: 0.85, green: 0.55, blue: 1.0) : HUDStyle.selected)
                            .allowsHitTesting(false)
                    }
                }
                let route = model.route
                if !route.isEmpty {
                    if active > 0 {
                        MapPolyline(coordinates: route.prefix(active).map(coordinate))
                            .stroke(.white.opacity(0.45), style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                    }
                    if active < route.count {
                        MapPolyline(coordinates: [aircraft] + route[active...].map(coordinate))
                            .stroke(HUDStyle.route, lineWidth: 3)
                    }
                    ForEach(Array(route.enumerated()), id: \.offset) { i, p in
                        Annotation(p.name, coordinate: coordinate(p), anchor: .center) {
                            Circle()
                                .fill(i == active ? HUDStyle.route : .white)
                                .frame(width: 12, height: 12)
                                .overlay(Circle().stroke(.black.opacity(0.5), lineWidth: 1))
                        }
                    }
                }
                Annotation("", coordinate: aircraft, anchor: .center) {
                    AircraftMarker(track: model.track)
                }
            }
            .mapStyle(.hybrid(elevation: .flat, pointsOfInterest: .excludingAll))
            .mapControls { MapScaleView() }
            .onTapGesture { point in
                // A tap near a navaid or fix takes it, by name; elsewhere it makes a new point.
                let visible = shown
                let candidates = visible.navaids.map { NavPoint(name: $0.id, latitude: $0.latitude, longitude: $0.longitude) }
                    + visible.fixes.map { NavPoint(name: $0.id, latitude: $0.latitude, longitude: $0.longitude) }
                let near = candidates.compactMap { p -> (NavPoint, CGFloat)? in
                    guard let q = proxy.convert(CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude), to: .local) else { return nil }
                    let d = hypot(q.x - point.x, q.y - point.y)
                    return d < 24 ? (p, d) : nil
                }.min { $0.1 < $1.1 }?.0
                if let near {
                    model.route.append(near)
                } else if let c = proxy.convert(point, from: .local) {
                    model.route.append(NavPoint(name: "WPT\(model.route.count + 1)", latitude: c.latitude, longitude: c.longitude))
                }
            }
            .simultaneousGesture(DragGesture(minimumDistance: 10).onChanged { _ in follow = false })
            .onMapCameraChange(frequency: .onEnd) { context in
                distance = context.camera.distance
                region = context.region
            }
        }
        .clipShape(.rect(cornerRadius: 24, style: .continuous))
        .overlay(alignment: .top) { header }
        .overlay(alignment: .bottom) { controls }
        .onAppear { centre(animated: false) }
        .onChange(of: model.latitude) { if follow { centre(animated: false) } }
    }

    private func coordinate(_ p: NavPoint) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude)
    }

    private func centre(animated: Bool) {
        let c = MapCameraPosition.camera(MapCamera(centerCoordinate: aircraft, distance: distance, heading: 0, pitch: 0))
        if animated { withAnimation(.easeInOut(duration: 0.4)) { camera = c } } else { camera = c }
    }

    /// Where NAV is going: the next point, its distance and the time to it.
    private var summary: String {
        guard !model.route.isEmpty else { return "Tap the map to add a point to the route" }
        guard model.navEngaged else { return "\(model.route.count) point\(model.route.count == 1 ? "" : "s") · NAV off" }
        guard let i = model.activeWaypoint, let d = model.distanceToActive, i < model.route.count else {
            return "Past the last point, holding its course"
        }
        let nm = d / 1_852
        let minutes = model.groundSpeed > 30 ? nm / Double(model.groundSpeed) * 60 : 0
        return String(format: "%@ · %.1f nm · %d min", model.route[i].name, nm, Int(minutes.rounded()))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Map")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(summary)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(model.navEngaged && !model.route.isEmpty ? HUDStyle.route : HUDStyle.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(.white.opacity(0.18), in: .circle)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Map")
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(height: 50)
        .glassEffect(HUDStyle.glass, in: .rect(cornerRadius: 24, style: .continuous))
        .padding(8)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            pill(symbol: "location.fill", text: "Follow", iconOnly: true, isOn: follow) {
                follow = true
                centre(animated: true)
            }
            ForEach(model.airports, id: \.self) { airport in
                pill(symbol: nil, text: airport.name, isOn: false) {
                    model.route.append(airport)
                }
            }
            Spacer(minLength: 0)
            pill(symbol: "arrow.uturn.backward", text: "Undo", iconOnly: true, isOn: false) {
                if !model.route.isEmpty { model.route.removeLast() }
            }
            .disabled(model.route.isEmpty)
            pill(symbol: "trash", text: "Clear route", iconOnly: true, isOn: false) { model.route = [] }
                .disabled(model.route.isEmpty)
            pill(symbol: nil, text: "NAV", isOn: model.navEngaged) {
                model.navEngaged.toggle()
                // NAV steers through the autopilot, so engaging it turns the autopilot on.
                if model.navEngaged { model.apMaster = true }
            }
            .disabled(model.route.isEmpty && !model.navEngaged)
        }
        .padding(8)
        .glassEffect(HUDStyle.glass, in: .rect(cornerRadius: 24, style: .continuous))
        .padding(8)
    }

    /// A map control: an icon (labelled for VoiceOver) or a short word.
    private func pill(symbol: String?, text: String, iconOnly: Bool = false, isOn: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let symbol, iconOnly {
                    Image(systemName: symbol).accessibilityLabel(text)
                } else {
                    Text(text)
                }
            }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOn ? Color.black : Color.white)
                .padding(.horizontal, iconOnly ? 0 : 12)
                .frame(minWidth: 36)
                .frame(height: 36)
                .background(isOn ? AnyShapeStyle(HUDStyle.engaged) : AnyShapeStyle(.white.opacity(0.16)), in: .capsule)
                .frame(minHeight: 44)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isOn)
    }
}

/// The aircraft on the map: a silhouette drawn nose-up (north), turned to the ground track.
struct AircraftMarker: View {
    let track: Double

    var body: some View {
        AircraftShape()
            .fill(.white)
            .overlay(AircraftShape().stroke(.black.opacity(0.55), lineWidth: 1))
            .frame(width: 30, height: 30)
            .rotationEffect(.degrees(track))
            .shadow(color: .black.opacity(0.5), radius: 2)
            .accessibilityLabel("Your aircraft")
    }
}

nonisolated struct AircraftShape: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: r.minX + x * w, y: r.minY + y * h) }
        var path = Path()
        // Fuselage nose at the top, swept wings, tailplane.
        path.move(to: p(0.5, 0.02))
        path.addQuadCurve(to: p(0.56, 0.2), control: p(0.56, 0.05))
        path.addLine(to: p(0.56, 0.38))
        path.addLine(to: p(0.98, 0.58))
        path.addLine(to: p(0.98, 0.65))
        path.addLine(to: p(0.56, 0.54))
        path.addLine(to: p(0.55, 0.8))
        path.addLine(to: p(0.72, 0.92))
        path.addLine(to: p(0.72, 0.97))
        path.addLine(to: p(0.5, 0.92))
        path.addLine(to: p(0.28, 0.97))
        path.addLine(to: p(0.28, 0.92))
        path.addLine(to: p(0.45, 0.8))
        path.addLine(to: p(0.44, 0.54))
        path.addLine(to: p(0.02, 0.65))
        path.addLine(to: p(0.02, 0.58))
        path.addLine(to: p(0.44, 0.38))
        path.addLine(to: p(0.44, 0.2))
        path.addQuadCurve(to: p(0.5, 0.02), control: p(0.44, 0.05))
        path.closeSubpath()
        return path
    }
}
