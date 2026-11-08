public import Foundation
public import simd

/// One FlightGear model animation that moves geometry: a rotation about an axis through a
/// centre, or a translation along an axis, driven by a property. Read from the model's
/// PropertyList XML; kept in the AC3D file's frame (x aft, y up, z left) so it applies to the
/// parsed vertices directly.
public struct FGAnimation: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case rotate, translate }
    public var kind: Kind
    public var objects: [String]
    /// Property path without a leading slash ("instrumentation/altimeter/indicated-altitude-ft").
    public var property: String
    public var factor = 1.0
    public var offset = 0.0
    public var minimum: Double?
    public var maximum: Double?
    /// Interpolation table (input, output); replaces factor and offset when present.
    public var table: [SIMD2<Double>] = []
    public var axis = SIMD3<Double>(0, 1, 0)
    public var center = SIMD3<Double>.zero

    /// Degrees (rotate) or metres (translate) for a property value.
    public func output(_ input: Double) -> Double {
        var v: Double
        if let first = table.first, let last = table.last {
            if input <= first.x { v = first.y } else if input >= last.x { v = last.y } else {
                v = last.y
                for i in 1..<table.count where input <= table[i].x {
                    let a = table[i - 1], b = table[i]
                    v = a.y + (b.y - a.y) * (input - a.x) / max(b.x - a.x, 1e-12)
                    break
                }
            }
        } else {
            v = input * factor + offset
        }
        if let minimum { v = max(v, minimum) }
        if let maximum { v = min(v, maximum) }
        return v
    }

    public func matrix(_ input: Double) -> simd_double4x4 {
        let v = output(input)
        let n = simd_length(axis) > 1e-12 ? simd_normalize(axis) : SIMD3(0, 1, 0)
        switch kind {
        case .translate:
            return FGAnimation.translation(n * v)
        case .rotate:
            let r = simd_double4x4(simd_quatd(angle: v * .pi / 180, axis: n))
            return FGAnimation.translation(center) * r * FGAnimation.translation(-center)
        }
    }

    static func translation(_ t: SIMD3<Double>) -> simd_double4x4 {
        var m = matrix_identity_double4x4
        m.columns.3 = SIMD4(t, 1)
        return m
    }

    /// FlightGear XML axes (x aft, y right, z up) to the AC3D file's (x aft, y up, z left).
    static func acFrame(_ v: SIMD3<Double>) -> SIMD3<Double> { SIMD3(v.x, v.z, -v.y) }

    /// The rotate and translate animations in a PropertyList (others, and those driven by
    /// expressions rather than a property, are skipped). `<property alias=...>` resolves
    /// through the file's `<params>`.
    static func parse(_ root: XMLElementNode) -> [FGAnimation] {
        root.children(named: "animation").compactMap { a -> FGAnimation? in
            let kind: Kind
            switch a.text(of: "type") {
            case "rotate": kind = .rotate
            case "translate": kind = .translate
            default: return nil
            }
            guard let p = a.child(named: "property") else { return nil }
            var property = p.text
            if let alias = p.attributes["alias"] {
                let path = alias.split(separator: "/").filter { $0 != ".." && !$0.isEmpty }.map(String.init)
                guard let target = root.descendant(path: path) else { return nil }
                property = target.text
            }
            property = property.trimmingCharacters(in: .whitespacesAndNewlines)
            while property.hasPrefix("/") { property.removeFirst() }
            guard !property.isEmpty else { return nil }
            var anim = FGAnimation(kind: kind, objects: a.children(named: "object-name").map(\.text), property: property)
            func number(_ name: String) -> Double? { a.text(of: name).flatMap { Double($0) } }
            anim.factor = number("factor") ?? 1
            anim.offset = number(kind == .rotate ? "offset-deg" : "offset-m") ?? 0
            anim.minimum = number(kind == .rotate ? "min-deg" : "min-m")
            anim.maximum = number(kind == .rotate ? "max-deg" : "max-m")
            if let interp = a.child(named: "interpolation") {
                anim.table = interp.children(named: "entry").compactMap { e in
                    guard let i = e.text(of: "ind").flatMap(Double.init), let d = e.text(of: "dep").flatMap(Double.init) else { return nil }
                    return SIMD2(i, d)
                }
            }
            if let ax = a.child(named: "axis") {
                func c(_ n: String) -> Double { ax.text(of: n).flatMap(Double.init) ?? 0 }
                if ax.child(named: "x1-m") != nil {
                    let p1 = SIMD3(c("x1-m"), c("y1-m"), c("z1-m")), p2 = SIMD3(c("x2-m"), c("y2-m"), c("z2-m"))
                    anim.center = acFrame(p1)
                    anim.axis = acFrame(p2 - p1)
                } else {
                    anim.axis = acFrame(SIMD3(c("x"), c("y"), c("z")))
                }
            }
            if let ce = a.child(named: "center") {
                func c(_ n: String) -> Double { ce.text(of: n).flatMap(Double.init) ?? 0 }
                anim.center = acFrame(SIMD3(c("x-m"), c("y-m"), c("z-m")))
            }
            return anim
        }
    }
}

/// A FlightGear model assembled from PropertyList files: the geometry of every sub-model in one
/// AC3D model, and the animations that move its named objects. Animated objects get parts named
/// "anim:<model>|<object>/<child object>", so a renderer can draw them with `transform(part:values:)`;
/// fixed ones are "cabin".
public struct AnimatedModel: Sendable {
    public var model = AC3DModel()
    /// Animations by "<model>|<object>", in file order.
    public var animations: [String: [FGAnimation]] = [:]
    /// Where each sub-model sits (its `<offsets>`), by model name.
    public var placements: [String: simd_double4x4] = [:]
    /// The first model loaded (the airframe, whose animated parts are outside).
    public var root = ""
    /// Values used for properties the caller does not supply.
    public var defaults: [String: Double] = [:]
    /// Objects left out (their part becomes "hidden"), by name, in every sub-model.
    public var hiddenObjects: Set<String> = []

    public init() {}

    /// Every property some animation reads.
    public var properties: Set<String> { Set(animations.values.flatMap { $0.map(\.property) }) }

    /// Whether a part is inside the cabin (fixed cabin geometry, or animated parts of a sub-model).
    public func isInterior(part: String) -> Bool {
        part == "cabin" || (part.hasPrefix("anim:") && !part.hasPrefix("anim:\(root)|"))
    }

    /// Model-space transform for a part, or nil for a part that never moves.
    public func transform(part: String, values: [String: Double]) -> simd_float4x4? {
        guard part.hasPrefix("anim:"), let bar = part.firstIndex(of: "|") else { return nil }
        let name = String(part[part.index(part.startIndex, offsetBy: 5)..<bar])
        var m = placements[name] ?? matrix_identity_double4x4
        for object in part[part.index(after: bar)...].split(separator: "/") {
            // FlightGear wraps each animation around the object in turn: the first listed is
            // innermost.
            for anim in (animations["\(name)|\(object)"] ?? []).reversed() {
                m = m * anim.matrix(values[anim.property] ?? defaults[anim.property] ?? 0)
            }
        }
        return simd_float4x4(SIMD4<Float>(m.columns.0), SIMD4<Float>(m.columns.1), SIMD4<Float>(m.columns.2), SIMD4<Float>(m.columns.3))
    }

    /// Loads a PropertyList model from `directory` (all files flat in one folder) and the
    /// sub-models it lists, skipping any whose path contains a string in `excluding`.
    /// `staticPart` names this file's fixed geometry (sub-models' is always "cabin": a model
    /// inside the airframe); `special` may give an object a part of its own ("hidden",
    /// "prop-fast") ahead of the rest.
    public mutating func load(xml file: String, directory: URL, placement: simd_double4x4 = matrix_identity_double4x4,
                              excluding: [String] = [], staticPart: String = "cabin",
                              special: (String) -> String? = { _ in nil }) throws {
        let root = try XMLElementNode.parse(contentsOf: directory.appendingPathComponent(file))
        let name = (file as NSString).deletingPathExtension
        if self.root.isEmpty { self.root = name }
        let anims = FGAnimation.parse(root)
        var animated = Set<String>()
        for a in anims {
            for o in a.objects {
                animations["\(name)|\(o)", default: []].append(a)
                animated.insert(o)
            }
        }
        if placement != matrix_identity_double4x4 { placements[name] = placement }
        if let path = root.text(of: "path"), path.hasSuffix(".ac") {
            let ac = (path as NSString).lastPathComponent
            let text = try String(contentsOf: directory.appendingPathComponent(ac), encoding: .isoLatin1)
            let base = placement != matrix_identity_double4x4 ? "anim:\(name)|" : ""
            let hidden = hiddenObjects
            var parsed = try AC3DParser.parse(text, objectPart: { object, parent in
                if hidden.contains(object) { return "hidden" }
                if let own = special(object) { return own }
                guard animated.contains(object) else { return "" }
                if parent.hasPrefix("anim:\(name)|") { return parent.hasSuffix("|") ? parent + object : parent + "/" + object }
                return "anim:\(name)|" + object
            })
            // Fixed geometry is "cabin" (a model inside the airframe); placed sub-models are
            // moved as a whole.
            for i in parsed.groups.indices where parsed.groups[i].part.isEmpty { parsed.groups[i].part = base.isEmpty ? staticPart : base }
            model = model.groups.isEmpty ? parsed : model.merged(with: parsed)
        }
        for sub in root.children(named: "model") {
            guard let path = sub.text(of: "path"), path.hasSuffix(".xml"),
                  !excluding.contains(where: { path.contains($0) }) else { continue }
            let subFile = (path as NSString).lastPathComponent
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(subFile).path) else { continue }
            var m = placement
            if let o = sub.child(named: "offsets") {
                func c(_ n: String) -> Double { o.text(of: n).flatMap(Double.init) ?? 0 }
                m = m * FGAnimation.translation(FGAnimation.acFrame(SIMD3(c("x-m"), c("y-m"), c("z-m"))))
            }
            try load(xml: subFile, directory: directory, placement: m, excluding: excluding)
        }
    }
}

/// A minimal XML element tree for FlightGear PropertyList files.
final class XMLElementNode {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [XMLElementNode] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    func child(named n: String) -> XMLElementNode? { children.first { $0.name == n } }
    func children(named n: String) -> [XMLElementNode] { children.filter { $0.name == n } }
    func text(of n: String) -> String? { child(named: n)?.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    func descendant(path: [String]) -> XMLElementNode? {
        var node: XMLElementNode? = self
        for p in path { node = node?.child(named: p) }
        return node
    }

    static func parse(contentsOf url: URL) throws -> XMLElementNode {
        let data = try Data(contentsOf: url)
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            throw AC3DError.malformed(line: parser.lineNumber, "XML \(url.lastPathComponent): \(parser.parserError?.localizedDescription ?? "")")
        }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var stack: [XMLElementNode] = []
        var root: XMLElementNode?
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            let node = XMLElementNode(name: elementName, attributes: attributes)
            stack.last?.children.append(node)
            if root == nil { root = node }
            stack.append(node)
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            stack.removeLast()
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }
    }
}
