public import Foundation
public import simd

/// One FlightGear model animation that moves geometry: a rotation about an axis through a
/// centre, or a translation along an axis, driven by a property. Read from the model's
/// PropertyList XML; kept in the AC3D file's frame (x aft, y up, z left) so it applies to the
/// parsed vertices directly.
public struct FGAnimation: Sendable, Equatable {
    /// `spin` turns continuously at the property's value as rpm (times the factor); `select`
    /// shows its objects only while its condition holds.
    public enum Kind: Sendable, Equatable { case rotate, translate, spin, select }
    public var kind: Kind
    public var objects: [String]
    /// Property path without a leading slash ("instrumentation/altimeter/indicated-altitude-ft").
    public var property: String
    public var condition: FGCondition?
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

    /// The transform for a property value; for `spin`, `input` is the revolutions the property
    /// has accumulated (its integral as rpm over minutes), which the factor scales.
    public func matrix(_ input: Double) -> simd_double4x4 {
        let n = simd_length(axis) > 1e-12 ? simd_normalize(axis) : SIMD3(0, 1, 0)
        let degrees: Double
        switch kind {
        case .select:
            return matrix_identity_double4x4
        case .translate:
            return FGAnimation.translation(n * output(input))
        case .rotate:
            degrees = output(input)
        case .spin:
            degrees = (input * factor).truncatingRemainder(dividingBy: 1) * 360
        }
        let r = simd_double4x4(simd_quatd(angle: degrees * .pi / 180, axis: n))
        return FGAnimation.translation(center) * r * FGAnimation.translation(-center)
    }

    static func translation(_ t: SIMD3<Double>) -> simd_double4x4 {
        var m = matrix_identity_double4x4
        m.columns.3 = SIMD4(t, 1)
        return m
    }

    /// FlightGear XML axes (x aft, y right, z up) to the AC3D file's (x aft, y up, z left).
    static func acFrame(_ v: SIMD3<Double>) -> SIMD3<Double> { SIMD3(v.x, v.z, -v.y) }

    /// A property element's path: its text, or its `alias` resolved through the file's
    /// `<params>`; without a leading slash.
    static func propertyPath(_ p: XMLElementNode, root: XMLElementNode) -> String? {
        var property = p.text
        if let alias = p.attributes["alias"] {
            let path = alias.split(separator: "/").filter { $0 != ".." && !$0.isEmpty }.map(String.init)
            guard let target = root.descendant(path: path) else { return nil }
            property = target.child(named: "property")?.text ?? target.text
        }
        property = property.trimmingCharacters(in: .whitespacesAndNewlines)
        while property.hasPrefix("/") { property.removeFirst() }
        return property.isEmpty ? nil : property
    }

    /// The rotate, translate, spin and select animations in a PropertyList (others, and those
    /// driven by expressions rather than a property, are skipped).
    static func parse(_ root: XMLElementNode) -> [FGAnimation] {
        root.children(named: "animation").compactMap { a -> FGAnimation? in
            let kind: Kind
            switch a.text(of: "type") {
            case "rotate": kind = .rotate
            case "translate": kind = .translate
            case "spin": kind = .spin
            case "select": kind = .select
            default: return nil
            }
            let objects = a.children(named: "object-name").map(\.text)
            if kind == .select {
                guard let c = a.child(named: "condition").flatMap({ FGCondition.parse($0, root: root) }) else { return nil }
                var anim = FGAnimation(kind: .select, objects: objects, property: "")
                anim.condition = c
                return anim
            }
            guard let p = a.child(named: "property"), let property = propertyPath(p, root: root) else { return nil }
            var anim = FGAnimation(kind: kind, objects: objects, property: property)
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

/// A FlightGear `<condition>`: comparisons of a property with a value, a property's truth,
/// and not / and / or of those.
public indirect enum FGCondition: Sendable, Equatable {
    case truthy(String)
    case compare(String, Comparison, Double)
    case not(FGCondition)
    case all([FGCondition])
    case any([FGCondition])

    public enum Comparison: Sendable, Equatable { case less, lessOrEqual, greater, greaterOrEqual, equal }

    public func holds(_ value: (String) -> Double) -> Bool {
        switch self {
        case .truthy(let p): return value(p) != 0
        case .compare(let p, let c, let v):
            let x = value(p)
            switch c {
            case .less: return x < v
            case .lessOrEqual: return x <= v
            case .greater: return x > v
            case .greaterOrEqual: return x >= v
            case .equal: return x == v
            }
        case .not(let c): return !c.holds(value)
        case .all(let cs): return cs.allSatisfy { $0.holds(value) }
        case .any(let cs): return cs.contains { $0.holds(value) }
        }
    }

    /// A `<condition>` element (its children are and-ed) or one of its operators; nil for
    /// forms not handled (expressions, two-property comparisons).
    static func parse(_ node: XMLElementNode, root: XMLElementNode) -> FGCondition? {
        func one(_ n: XMLElementNode) -> FGCondition? {
            switch n.name {
            case "property": return FGAnimation.propertyPath(n, root: root).map { .truthy($0) }
            case "not": return n.children.first.flatMap(one).map { .not($0) }
            case "and": let cs = n.children.compactMap(one); return cs.count == n.children.count ? .all(cs) : nil
            case "or": let cs = n.children.compactMap(one); return cs.count == n.children.count ? .any(cs) : nil
            case "less-than", "less-than-equals", "greater-than", "greater-than-equals", "equals":
                guard let p = n.child(named: "property").flatMap({ FGAnimation.propertyPath($0, root: root) }),
                      let v = n.text(of: "value").flatMap(Double.init), n.children(named: "property").count == 1 else { return nil }
                let c: Comparison = ["less-than": .less, "less-than-equals": .lessOrEqual, "greater-than": .greater,
                                     "greater-than-equals": .greaterOrEqual, "equals": .equal][n.name]!
                return .compare(p, c, v)
            default: return nil
            }
        }
        let cs = node.children.compactMap(one)
        guard cs.count == node.children.count, !cs.isEmpty else { return nil }
        return cs.count == 1 ? cs[0] : .all(cs)
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
    /// Models loaded as the inside of the airframe (whose fixed part is "cabin").
    public var interiorModels: Set<String> = []

    public init() {}

    /// Every property some animation reads.
    public var properties: Set<String> { Set(animations.values.flatMap { $0.map(\.property) }).subtracting([""]) }

    /// Properties that drive `spin` animations: the caller supplies their accumulated
    /// revolutions as "spin:<property>" (see `FGAnimation.matrix`).
    public var spinProperties: Set<String> {
        Set(animations.values.flatMap { $0.filter { $0.kind == .spin }.map(\.property) })
    }

    /// Whether a part is inside the cabin (fixed cabin geometry, or animated parts of a model
    /// inside the airframe).
    public func isInterior(part: String) -> Bool {
        if part == "cabin" { return true }
        guard part.hasPrefix("anim:"), let bar = part.firstIndex(of: "|") else { return false }
        return interiorModels.contains(String(part[part.index(part.startIndex, offsetBy: 5)..<bar]))
    }

    /// The centre of the geometry of the parts ending in an object's name (an animated object),
    /// in the model's frame.
    public func centre(ofObject object: String) -> SIMD3<Float>? {
        let p = model.groups.filter { $0.part.hasSuffix("|" + object) || $0.part.hasSuffix("/" + object) }.flatMap(\.positions)
        guard let first = p.first else { return nil }
        let lo = p.reduce(first) { simd_min($0, $1) }, hi = p.reduce(first) { simd_max($0, $1) }
        return (lo + hi) / 2
    }

    /// Whether a part is shown: false while a `select` on it or on an object it hangs from fails.
    public func isVisible(part: String, values: [String: Double]) -> Bool {
        guard part.hasPrefix("anim:"), let bar = part.firstIndex(of: "|") else { return true }
        let name = String(part[part.index(part.startIndex, offsetBy: 5)..<bar])
        for object in part[part.index(after: bar)...].split(separator: "/") {
            for anim in animations["\(name)|\(object)"] ?? [] where anim.kind == .select {
                if let c = anim.condition, !c.holds({ values[$0] ?? defaults[$0] ?? 0 }) { return false }
            }
        }
        return true
    }

    /// Model-space transform for a part, or nil for a part that never moves.
    public func transform(part: String, values: [String: Double]) -> simd_float4x4? {
        guard part.hasPrefix("anim:"), let bar = part.firstIndex(of: "|") else { return nil }
        let name = String(part[part.index(part.startIndex, offsetBy: 5)..<bar])
        var m = placements[name] ?? matrix_identity_double4x4
        for object in part[part.index(after: bar)...].split(separator: "/") {
            // FlightGear wraps each animation around the object in turn: the first listed is
            // innermost.
            for anim in (animations["\(name)|\(object)"] ?? []).reversed() where anim.kind != .select {
                let key = anim.kind == .spin ? "spin:" + anim.property : anim.property
                m = m * anim.matrix(values[key] ?? defaults[key] ?? 0)
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
                              special: (String) -> String? = { _ in nil },
                              animate: (FGAnimation) -> Bool = { _ in true }, fixedSelects: Bool = false) throws {
        let root = try XMLElementNode.parse(contentsOf: directory.appendingPathComponent(file))
        let name = (file as NSString).deletingPathExtension
        if self.root.isEmpty { self.root = name }
        if staticPart == "cabin" { interiorModels.insert(name) }
        var anims = FGAnimation.parse(root)
        // `fixedSelects`: decide every select once, from the defaults (a busy panel's hundreds
        // of lamps), rather than keeping each lamp a separate moving part.
        var hiddenBySelect = Set<String>()
        if fixedSelects {
            let d = defaults
            for a in anims where a.kind == .select {
                if let c = a.condition, !c.holds({ d[$0] ?? 0 }) { hiddenBySelect.formUnion(a.objects) }
            }
            anims.removeAll { $0.kind == .select }
        }
        anims = anims.filter { $0.kind == .select || animate($0) }
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
                if hidden.contains(object) || hiddenBySelect.contains(object) { return "hidden" }
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
