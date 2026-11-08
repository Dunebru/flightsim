public import Foundation
public import simd

/// One FlightGear model animation that moves geometry: a rotation about an axis through a
/// centre, or a translation along an axis, driven by a property. Read from the model's
/// PropertyList XML; kept in the AC3D file's frame (x aft, y up, z left) so it applies to the
/// parsed vertices directly.
public struct FGAnimation: Sendable, Equatable {
    /// `spin` turns continuously at the property's value as rpm (times the factor); `select`
    /// shows its objects only while its condition holds.
    public enum Kind: Sendable, Equatable { case rotate, translate, spin, select, textranslate }
    public var kind: Kind
    public var objects: [String]
    /// Property path without a leading slash ("instrumentation/altimeter/indicated-altitude-ft").
    public var property: String
    public var condition: FGCondition?
    /// textranslate: the value is first quantized to `step` (a digit drum showing whole digits).
    public var step = 0.0, bias = 0.0
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
        case .select, .textranslate:
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
            case "textranslate": kind = .textranslate
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
            anim.step = number("step") ?? 0
            anim.bias = number("bias") ?? 0
            anim.offset = number(kind == .rotate ? "offset-deg" : kind == .textranslate ? "offset" : "offset-m") ?? 0
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
                } else if kind == .textranslate {
                    anim.axis = SIMD3(c("x"), c("y"), 0)      // texture axes, not space
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
    /// FlightGear `<text>` readouts turned into screen quads (parts "display:text:<name>"):
    /// what each shows.
    public struct TextLabel: Sendable {
        public var property: String
        /// A fixed string ("----"), or nil to format the property.
        public var literal: String?
        public var format: String
        public var characters: Int
        /// Width over height of the quad (and of the image to draw into it).
        public var aspect: Double
    }
    public var textLabels: [String: TextLabel] = [:]

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

    /// The texture offset of a part's digit drums (textranslate), in AC3D texture space
    /// (v up).
    public func textureOffset(part: String, values: [String: Double]) -> SIMD2<Float> {
        guard part.hasPrefix("anim:"), let bar = part.firstIndex(of: "|") else { return .zero }
        let name = String(part[part.index(part.startIndex, offsetBy: 5)..<bar])
        var off = SIMD2<Double>.zero
        for object in part[part.index(after: bar)...].split(separator: "/") {
            for anim in animations["\(name)|\(object)"] ?? [] where anim.kind == .textranslate {
                var v = values[anim.property] ?? defaults[anim.property] ?? 0
                if anim.step > 0 { v = ((v + anim.bias) / anim.step).rounded(.down) * anim.step }
                v = v * anim.factor + anim.offset
                off += SIMD2(anim.axis.x, anim.axis.y) * v
            }
        }
        return SIMD2<Float>(off)
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
            // SimGear inserts each animation's transform between the object and the transform
            // before it (SGAnimation::installInGroup), so the first listed is outermost and the
            // last innermost: a wheel spins about its axle, then the strut compresses, then the
            // gear swings.
            for anim in animations["\(name)|\(object)"] ?? [] where anim.kind != .select && anim.kind != .textranslate {
                let key = anim.kind == .spin ? "spin:" + anim.property : anim.property
                m = m * anim.matrix(values[key] ?? defaults[key] ?? 0)
            }
        }
        return simd_float4x4(SIMD4<Float>(m.columns.0), SIMD4<Float>(m.columns.1), SIMD4<Float>(m.columns.2), SIMD4<Float>(m.columns.3))
    }

    /// Characters a printf format produces for a typical value ("%03.0f" -> 3, "%05.0f" -> 5).
    static func formatWidth(_ format: String, text: String?) -> Int {
        if format == "%s" { return max(text?.count ?? 0, 4) }
        let digits = format.split(whereSeparator: { !$0.isNumber && $0 != "." })
        if let first = digits.first, let w = Double(first) { return max(Int(w), 3) + (format.contains(".") && !format.hasSuffix(".0f") ? 1 : 0) }
        return 4
    }

    /// Loads a PropertyList model from `directory` (all files flat in one folder) and the
    /// sub-models it lists, skipping any whose path contains a string in `excluding`.
    /// `staticPart` names this file's fixed geometry (sub-models' is always "cabin": a model
    /// inside the airframe); `special` may give an object a part of its own ("hidden",
    /// "prop-fast") ahead of the rest.
    public mutating func load(xml file: String, directory: URL, placement: simd_double4x4 = matrix_identity_double4x4,
                              excluding: [String] = [], staticPart: String = "cabin",
                              special: (String) -> String? = { _ in nil },
                              animate: (FGAnimation) -> Bool = { _ in true }, fixedSelects: Bool = false,
                              texts: Set<String> = []) throws {
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
                // A screen the sim draws is shown whatever the panel's power switches would say.
                if let own = special(object), own.hasPrefix("display:") { return own }
                if hidden.contains(object) || hiddenBySelect.contains(object) { return "hidden" }
                if let own = special(object) { return own }
                guard animated.contains(object) else { return "" }
                if parent.hasPrefix("anim:\(name)|") { return parent.hasSuffix("|") ? parent + object : parent + "/" + object }
                return "anim:\(name)|" + object
            })
            // Fixed geometry is "cabin" (a model inside the airframe); placed sub-models are
            // moved as a whole.
            for i in parsed.groups.indices where parsed.groups[i].part.isEmpty { parsed.groups[i].part = base.isEmpty ? staticPart : base }
            // `<text>` readouts named in `texts`: a quad each, lying where FlightGear draws the
            // text (its plane, facing, and size from the character height and digit count).
            for t in root.children(named: "text") {
                guard let tname = t.text(of: "name"), texts.contains(tname) else { continue }
                let isLiteral = t.text(of: "type") == "literal"
                let format = t.text(of: "format") ?? "%s"
                let sample = isLiteral ? (t.text(of: "text") ?? "") : (t.child(named: "property").flatMap { _ in nil } ?? format)
                let chars = max(2, isLiteral ? sample.count : Self.formatWidth(format, text: t.text(of: "text")))
                let h = Double(t.text(of: "character-size") ?? "0.008") ?? 0.008
                let w = h * 0.62 * Double(chars) + h * 0.3
                var prop = ""
                if let p = t.child(named: "property") { prop = FGAnimation.propertyPath(p, root: root) ?? "" }
                textLabels[tname] = TextLabel(property: prop, literal: isLiteral ? sample : nil, format: format,
                                              characters: chars, aspect: w / (h * 1.3))
                let o = t.child(named: "offsets")
                func c(_ n: String) -> Double { o?.text(of: n).flatMap(Double.init) ?? 0 }
                let rad = Double.pi / 180
                let rz = simd_double3x3(simd_quatd(angle: c("heading-deg") * rad, axis: SIMD3(0, 0, 1)))
                let ry = simd_double3x3(simd_quatd(angle: c("pitch-deg") * rad, axis: SIMD3(0, 1, 0)))
                let rx = simd_double3x3(simd_quatd(angle: c("roll-deg") * rad, axis: SIMD3(1, 0, 0)))
                let r = rz * ry * rx
                let origin = SIMD3(c("x-m"), c("y-m"), c("z-m"))
                let hh = h * 0.65, hw = w / 2
                // Text plane: x along the line, y up, facing +z (FlightGear's xy-plane).
                func corner(_ x: Double, _ y: Double) -> SIMD3<Float> { SIMD3<Float>(FGAnimation.acFrame(origin + r * SIMD3(x, y, 0.008))) }
                let n = SIMD3<Float>(FGAnimation.acFrame(r * SIMD3(0, 0, 1)))
                let a = corner(-hw, -hh), b = corner(hw, -hh), cc = corner(hw, hh), d = corner(-hw, hh)
                var g = AC3DModel.Group(texture: nil, materialIndex: parsed.materials.count, twoSided: true, part: "display:text:" + tname)
                g.positions = [a, b, cc, a, cc, d]
                g.normals = Array(repeating: n, count: 6)
                g.uvs = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 0), SIMD2(1, 1), SIMD2(0, 1)]
                parsed.groups.append(g)
            }
            if parsed.groups.contains(where: { $0.part.hasPrefix("display:text:") }) {
                parsed.materials.append(AC3DModel.Material(name: "text", diffuse: SIMD3(1, 1, 1), emissive: .zero, specular: .zero,
                                                           shininess: 16, transparency: 0))
            }
            // Parts named by `special` are not moved by an animation transform, so a placed
            // sub-model's offset is baked into their vertices.
            if placement != matrix_identity_double4x4 {
                let pm = simd_float4x4(SIMD4<Float>(placement.columns.0), SIMD4<Float>(placement.columns.1),
                                       SIMD4<Float>(placement.columns.2), SIMD4<Float>(placement.columns.3))
                for i in parsed.groups.indices where !parsed.groups[i].part.hasPrefix("anim:") && parsed.groups[i].part != staticPart {
                    parsed.groups[i].positions = parsed.groups[i].positions.map { p in
                        let q = pm * SIMD4(p, 1)
                        return SIMD3(q.x, q.y, q.z)
                    }
                    parsed.groups[i].normals = parsed.groups[i].normals.map { n in
                        simd_normalize(SIMD3((pm * SIMD4(n, 0)).x, (pm * SIMD4(n, 0)).y, (pm * SIMD4(n, 0)).z))
                    }
                }
            }
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
            try load(xml: subFile, directory: directory, placement: m, excluding: excluding, special: special,
                     animate: animate, fixedSelects: fixedSelects)
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
