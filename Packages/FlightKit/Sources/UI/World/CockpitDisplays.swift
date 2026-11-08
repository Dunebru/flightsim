import CoreGraphics
import CoreText
import Foundation

/// What the A320's flight deck screens show, drawn from the flight's numbers. The layouts
/// follow the A320's (PFD, navigation display, engine/warning display, system display) in the
/// sim's own drawing; nothing is taken from Airbus or FlightGear artwork.
nonisolated struct DisplayInputs: Sendable {
    var ias = 0.0, altitude = 0.0, verticalSpeed = 0.0, heading = 0.0, track = 0.0
    var pitch = 0.0, roll = 0.0, groundSpeed = 0.0, trueAirspeed = 0.0
    var n1 = 0.0, throttle = 0.0, flaps = 0.0, gearDown = 1.0, onGround = true
    var windFrom = 0.0, windKnots = 0.0, oat = 15.0
    /// Flight mode annunciations: thrust, vertical, lateral, approach capability, engagement.
    var fma = ["", "", "", "", ""]
    var selectedAltitude = 0.0, selectedSpeed = 0.0
}

nonisolated enum CockpitDisplays {
    static let size = 384

    /// RGBA8 pixels, top row first.
    static func draw(_ page: String, _ d: DisplayInputs) -> [UInt8] {
        let n = size
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            // Top-left origin, y down, in a 1000-unit square.
            ctx.translateBy(x: 0, y: CGFloat(n))
            ctx.scaleBy(x: CGFloat(n) / 1000, y: -CGFloat(n) / 1000)
            ctx.setFillColor(CGColor(red: 0.01, green: 0.01, blue: 0.02, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 1000, height: 1000))
            switch page {
            case "pfd": pfd(ctx, d)
            case "nd": nd(ctx, d)
            case "ewd": ewd(ctx, d)
            case "mcdu": mcdu(ctx, d)
            case "dcdu": dcdu(ctx, d)
            case "isis": isis(ctx, d)
            case "clock": clock(ctx)
            case "atc": atc(ctx)
            case "batt": batt(ctx)
            default: sd(ctx, d)
            }
        }
        return pixels
    }

    // MARK: Colours and text

    static let green = CGColor(red: 0.1, green: 0.95, blue: 0.2, alpha: 1)
    static let amber = CGColor(red: 1, green: 0.62, blue: 0.05, alpha: 1)
    static let cyan = CGColor(red: 0.1, green: 0.85, blue: 1, alpha: 1)
    static let white = CGColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1)
    static let yellow = CGColor(red: 1, green: 0.92, blue: 0.1, alpha: 1)
    static let magenta = CGColor(red: 0.95, green: 0.3, blue: 0.9, alpha: 1)
    static let grey = CGColor(red: 0.35, green: 0.37, blue: 0.4, alpha: 1)

    static func text(_ ctx: CGContext, _ s: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 34, colour: CGColor = white,
                     align: CGFloat = 0) {
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, size, nil)
        let attr = NSAttributedString(string: s, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): colour,
        ])
        let line = CTLineCreateWithAttributedString(attr)
        let w = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.saveGState()
        // Text draws y-up: flip locally about the baseline.
        ctx.translateBy(x: x - CGFloat(w) * align, y: y)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    static func line(_ ctx: CGContext, _ a: CGPoint, _ b: CGPoint, _ colour: CGColor, _ width: CGFloat = 4) {
        ctx.setStrokeColor(colour)
        ctx.setLineWidth(width)
        ctx.strokeLineSegments(between: [a, b])
    }

    // MARK: PFD

    static func pfd(_ ctx: CGContext, _ d: DisplayInputs) {
        // FMA row.
        for (i, s) in d.fma.enumerated() where !s.isEmpty {
            text(ctx, s, 120 + CGFloat(i) * 190, 52, size: 30, colour: i == 4 ? white : green, align: 0.5)
        }
        for i in 1..<5 { line(ctx, CGPoint(x: 25 + CGFloat(i) * 190, y: 15), CGPoint(x: 25 + CGFloat(i) * 190, y: 70), grey, 2) }
        // Attitude: a square of sky and ground turned by the roll, moved by the pitch.
        let c = CGPoint(x: 470, y: 450)
        let pxPerDeg: CGFloat = 9
        ctx.saveGState()
        ctx.addRect(CGRect(x: 250, y: 200, width: 440, height: 480))
        ctx.clip()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: CGFloat(-d.roll * .pi / 180))
        let off = CGFloat(d.pitch) * pxPerDeg
        ctx.setFillColor(CGColor(red: 0.1, green: 0.45, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: -700, y: -1400 + off, width: 1400, height: 1400))
        ctx.setFillColor(CGColor(red: 0.55, green: 0.33, blue: 0.12, alpha: 1))
        ctx.fill(CGRect(x: -700, y: off, width: 1400, height: 1400))
        line(ctx, CGPoint(x: -700, y: off), CGPoint(x: 700, y: off), white, 3)
        for k in stride(from: -30, through: 30, by: 5) where k != 0 {
            let y = off - CGFloat(k) * pxPerDeg
            let w: CGFloat = k % 10 == 0 ? 70 : 35
            line(ctx, CGPoint(x: -w, y: y), CGPoint(x: w, y: y), white, 3)
            if k % 10 == 0 { text(ctx, "\(abs(k))", -w - 50, y + 10, size: 24, align: 0.5); text(ctx, "\(abs(k))", w + 50, y + 10, size: 24, align: 0.5) }
        }
        ctx.restoreGState()
        // Roll scale and pointer.
        for a in [-45.0, -30, -20, -10, 0, 10, 20, 30, 45] {
            let r = a * .pi / 180
            let p1 = CGPoint(x: c.x + CGFloat(sin(r)) * 200, y: c.y - CGFloat(cos(r)) * 200)
            let p2 = CGPoint(x: c.x + CGFloat(sin(r)) * (a.truncatingRemainder(dividingBy: 30) == 0 ? 225 : 215), y: c.y - CGFloat(cos(r)) * (a.truncatingRemainder(dividingBy: 30) == 0 ? 225 : 215))
            line(ctx, p1, p2, white, 3)
        }
        let rr = -d.roll * .pi / 180
        ctx.setFillColor(yellow)
        ctx.move(to: CGPoint(x: c.x + CGFloat(sin(rr)) * 195, y: c.y - CGFloat(cos(rr)) * 195))
        ctx.addLine(to: CGPoint(x: c.x + CGFloat(sin(rr + 0.06)) * 172, y: c.y - CGFloat(cos(rr + 0.06)) * 172))
        ctx.addLine(to: CGPoint(x: c.x + CGFloat(sin(rr - 0.06)) * 172, y: c.y - CGFloat(cos(rr - 0.06)) * 172))
        ctx.fillPath()
        // Aircraft symbol.
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.setStrokeColor(yellow)
        ctx.setLineWidth(6)
        ctx.strokeLineSegments(between: [CGPoint(x: c.x - 150, y: c.y), CGPoint(x: c.x - 70, y: c.y),
                                         CGPoint(x: c.x + 70, y: c.y), CGPoint(x: c.x + 150, y: c.y)])
        ctx.fill(CGRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16))
        ctx.stroke(CGRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16))
        // Speed tape.
        tape(ctx, CGRect(x: 40, y: 200, width: 150, height: 480), value: d.ias, step: 10, pxPerUnit: 5, label: { "\(Int($0))" }, every: 20)
        line(ctx, CGPoint(x: 30, y: c.y), CGPoint(x: 200, y: c.y), yellow, 6)
        // Altitude tape and box.
        tape(ctx, CGRect(x: 760, y: 200, width: 150, height: 480), value: d.altitude, step: 100, pxPerUnit: 0.45,
             label: { String(format: "%03d", Int($0 / 100)) }, every: 500)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 760, y: c.y - 32, width: 165, height: 64))
        ctx.setStrokeColor(yellow)
        ctx.setLineWidth(4)
        ctx.stroke(CGRect(x: 760, y: c.y - 32, width: 165, height: 64))
        text(ctx, String(format: "%05d", max(0, Int(d.altitude.rounded()))), 842, c.y + 14, size: 38, colour: green, align: 0.5)
        if d.selectedAltitude > 0 { text(ctx, "\(Int(d.selectedAltitude))", 835, 185, size: 30, colour: cyan, align: 0.5) }
        // Vertical speed.
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 930, y: 260, width: 55, height: 380))
        let vs = max(-6_000, min(6_000, d.verticalSpeed))
        let vsY = c.y - CGFloat(vs >= 0 ? sqrt(vs / 6_000) : -sqrt(-vs / 6_000)) * 180
        line(ctx, CGPoint(x: 990, y: c.y), CGPoint(x: 935, y: vsY), green, 5)
        if abs(vs) > 200 { text(ctx, "\(Int(abs(vs) / 100))", 958, vs > 0 ? 250 : 680, size: 26, colour: green, align: 0.5) }
        // Heading tape.
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 250, y: 860, width: 440, height: 90))
        for k in -4...4 {
            let h = (Int(d.heading / 10) + k) * 10
            let x = c.x + CGFloat(Double(h) - d.heading) * 9
            guard x > 255 && x < 685 else { continue }
            line(ctx, CGPoint(x: x, y: 860), CGPoint(x: x, y: 885), white, 3)
            let lbl = ((h % 360) + 360) % 360 / 10
            if lbl % 3 == 0 { text(ctx, "\(lbl)", x, 925, size: 30, align: 0.5) }
        }
        line(ctx, CGPoint(x: c.x, y: 850), CGPoint(x: c.x, y: 900), yellow, 6)
    }

    static func tape(_ ctx: CGContext, _ r: CGRect, value: Double, step: Double, pxPerUnit: CGFloat,
                     label: (Double) -> String, every: Double) {
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
        ctx.fill(r)
        ctx.saveGState()
        ctx.clip(to: r)
        let mid = r.midY
        let span = Double(r.height / 2 / pxPerUnit)
        var v = (floor((value - span) / step)) * step
        while v <= value + span {
            let y = mid - CGFloat(v - value) * pxPerUnit
            line(ctx, CGPoint(x: r.maxX - 25, y: y), CGPoint(x: r.maxX, y: y), white, 3)
            if v.truncatingRemainder(dividingBy: every) == 0, v >= 0 { text(ctx, label(v), r.maxX - 35, y + 12, size: 32, align: 1) }
            v += step
        }
        ctx.restoreGState()
    }

    // MARK: ND

    static func nd(_ ctx: CGContext, _ d: DisplayInputs) {
        text(ctx, "GS", 30, 60, size: 28)
        text(ctx, "\(Int(d.groundSpeed))", 85, 60, size: 32, colour: green)
        text(ctx, "TAS", 180, 60, size: 28)
        text(ctx, "\(Int(d.trueAirspeed))", 255, 60, size: 32, colour: green)
        if d.windKnots >= 2 {
            text(ctx, String(format: "%03d/%d", Int(d.windFrom.rounded()) % 360, Int(d.windKnots.rounded())), 30, 105, size: 28, colour: green)
        }
        let c = CGPoint(x: 500, y: 800)
        let radius: CGFloat = 620
        ctx.setStrokeColor(white)
        ctx.setLineWidth(4)
        ctx.addArc(center: c, radius: radius, startAngle: CGFloat(-.pi / 2 - 0.85), endAngle: CGFloat(-.pi / 2 + 0.85), clockwise: false)
        ctx.strokePath()
        for deg in stride(from: 0, to: 360, by: 5) {
            let rel = (Double(deg) - d.heading) * .pi / 180
            guard abs(remainder(rel, 2 * .pi)) < 0.85 else { continue }
            let a = CGFloat(remainder(rel, 2 * .pi)) - .pi / 2
            let long = deg % 10 == 0
            line(ctx, CGPoint(x: c.x + cos(a) * radius, y: c.y + sin(a) * radius),
                 CGPoint(x: c.x + cos(a) * (radius - (long ? 30 : 15)), y: c.y + sin(a) * (radius - (long ? 30 : 15))), white, 3)
            if deg % 30 == 0 {
                text(ctx, "\(deg / 10)", c.x + cos(a) * (radius - 65), c.y + sin(a) * (radius - 65) + 12, size: 32, align: 0.5)
            }
        }
        // Range ring.
        ctx.setStrokeColor(grey)
        ctx.setLineDash(phase: 0, lengths: [12, 12])
        ctx.addArc(center: c, radius: radius / 2, startAngle: CGFloat(-.pi / 2 - 0.85), endAngle: CGFloat(-.pi / 2 + 0.85), clockwise: false)
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        // Track diamond and lubber line, heading box.
        let trk = CGFloat(remainder((d.track - d.heading) * .pi / 180, 2 * .pi)) - .pi / 2
        ctx.setFillColor(green)
        let tp = CGPoint(x: c.x + cos(trk) * (radius + 8), y: c.y + sin(trk) * (radius + 8))
        ctx.fill(CGRect(x: tp.x - 8, y: tp.y - 8, width: 16, height: 16))
        line(ctx, CGPoint(x: c.x, y: c.y - radius - 10), CGPoint(x: c.x, y: c.y - radius - 50), yellow, 6)
        text(ctx, String(format: "%03d", Int(d.heading.rounded()) % 360), c.x, 125, size: 36, colour: green, align: 0.5)
        // Aircraft symbol.
        ctx.setStrokeColor(yellow)
        ctx.setLineWidth(6)
        ctx.strokeLineSegments(between: [CGPoint(x: c.x, y: c.y - 40), CGPoint(x: c.x, y: c.y + 40),
                                         CGPoint(x: c.x - 45, y: c.y - 10), CGPoint(x: c.x + 45, y: c.y - 10),
                                         CGPoint(x: c.x - 18, y: c.y + 32), CGPoint(x: c.x + 18, y: c.y + 32)])
    }

    // MARK: E/WD

    static func ewd(_ ctx: CGContext, _ d: DisplayInputs) {
        for (k, cx) in [CGFloat(250), CGFloat(650)].enumerated() {
            _ = k
            dial(ctx, CGPoint(x: cx, y: 210), radius: 130, value: d.n1 / 110, colour: green)
            text(ctx, String(format: "%.1f", d.n1), cx + 20, 250, size: 40, colour: green, align: 0.5)
            let egt = 400 + d.n1 * 4.5
            dial(ctx, CGPoint(x: cx, y: 450), radius: 85, value: egt / 1_000, colour: green)
            text(ctx, "\(Int(egt / 5) * 5)", cx + 10, 480, size: 32, colour: green, align: 0.5)
            text(ctx, String(format: "%.1f", 58 + d.n1 * 0.42), cx, 600, size: 34, colour: green, align: 0.5)
            text(ctx, "\(Int(300 + d.n1 * d.n1 * 0.35) / 20 * 20)", cx, 660, size: 34, colour: green, align: 0.5)
        }
        text(ctx, "N1", 450, 220, size: 30, align: 0.5)
        text(ctx, "%", 450, 255, size: 26, colour: cyan, align: 0.5)
        text(ctx, "EGT", 450, 455, size: 30, align: 0.5)
        text(ctx, "N2", 450, 600, size: 30, align: 0.5)
        text(ctx, "FF", 450, 660, size: 30, align: 0.5)
        line(ctx, CGPoint(x: 20, y: 720), CGPoint(x: 980, y: 720), white, 3)
        // Flap and slat indicator.
        let confs = ["0", "1", "2", "3", "FULL"]
        let idx = d.flaps < 0.05 ? 0 : d.flaps < 0.3 ? 1 : d.flaps < 0.45 ? 2 : d.flaps < 0.8 ? 3 : 4
        text(ctx, "S", 640, 790, size: 28)
        text(ctx, "F", 900, 790, size: 28)
        line(ctx, CGPoint(x: 690, y: 800), CGPoint(x: 690 - CGFloat(idx) * 15, y: 820 + CGFloat(idx) * 12), cyan, 6)
        line(ctx, CGPoint(x: 800, y: 800), CGPoint(x: 800 + CGFloat(idx) * 20, y: 820 + CGFloat(idx) * 12), cyan, 6)
        if idx > 0 { text(ctx, confs[idx], 760, 900, size: 38, colour: cyan, align: 0.5) }
        text(ctx, d.onGround ? "T.O MEMO" : "", 40, 790, size: 30, colour: cyan)
    }

    static func dial(_ ctx: CGContext, _ c: CGPoint, radius: CGFloat, value: Double, colour: CGColor) {
        let start = CGFloat(-.pi * 1.2), sweep = CGFloat(.pi * 1.1)
        ctx.setStrokeColor(white)
        ctx.setLineWidth(5)
        ctx.addArc(center: c, radius: radius, startAngle: start, endAngle: start + sweep, clockwise: false)
        ctx.strokePath()
        let a = start + sweep * CGFloat(max(0, min(1, value)))
        line(ctx, c, CGPoint(x: c.x + cos(a) * radius, y: c.y + sin(a) * radius), colour, 6)
    }

    // MARK: SD (wheel page)

    static func sd(_ ctx: CGContext, _ d: DisplayInputs) {
        text(ctx, "WHEEL", 500, 70, size: 40, align: 0.5)
        line(ctx, CGPoint(x: 400, y: 85), CGPoint(x: 600, y: 85), white, 3)
        for x in [CGFloat(250), CGFloat(500), CGFloat(750)] {
            let down = d.gearDown > 0.99, up = d.gearDown < 0.01
            ctx.setFillColor(down ? green : up ? grey : amber)
            ctx.move(to: CGPoint(x: x - 40, y: 250)); ctx.addLine(to: CGPoint(x: x + 40, y: 250)); ctx.addLine(to: CGPoint(x: x, y: 320)); ctx.fillPath()
        }
        text(ctx, "BRAKES", 500, 470, size: 30, align: 0.5)
        for (i, x) in [CGFloat(170), CGFloat(300), CGFloat(700), CGFloat(830)].enumerated() {
            text(ctx, "\(i + 1)", x, 520, size: 30, align: 0.5)
            text(ctx, "\(d.onGround ? 120 : 60)", x, 580, size: 34, colour: green, align: 0.5)
        }
        line(ctx, CGPoint(x: 20, y: 820), CGPoint(x: 980, y: 820), white, 3)
        text(ctx, "TAT", 40, 880, size: 28)
        text(ctx, "\(Int(d.oat + d.trueAirspeed * d.trueAirspeed / 87_000))", 140, 880, size: 30, colour: green)
        text(ctx, "SAT", 40, 930, size: 28)
        text(ctx, "\(Int(d.oat))", 140, 930, size: 30, colour: green)
        let f = DateFormatter()
        f.dateFormat = "HH mm"
        f.timeZone = TimeZone(identifier: "UTC")
        text(ctx, f.string(from: Date()), 500, 905, size: 36, colour: green, align: 0.5)
        text(ctx, "GW", 760, 905, size: 28)
        text(ctx, "64200", 830, 905, size: 30, colour: green)
    }

    // MARK: Small screens

    /// The MCDU's flight plan page.
    static func mcdu(_ ctx: CGContext, _ d: DisplayInputs) {
        text(ctx, "FROM", 60, 90, size: 44)
        text(ctx, "KPHX", 500, 90, size: 52, align: 0.5)
        let rows: [(String, String, String)] = [("RW08", "  ---", "/1135"), ("C090°", " 0420", "/ 3500"),
                                                ("BXK", " 0438", "/FL240"), ("(T/C)", " 0441", "/FL340"), ("-----", "", "")]
        for (i, r) in rows.enumerated() {
            let y = CGFloat(200 + i * 140)
            text(ctx, r.0, 40, y, size: 56, colour: i == 0 ? white : green)
            text(ctx, r.1, 420, y, size: 52, colour: green)
            text(ctx, r.2, 960, y, size: 52, colour: green, align: 1)
        }
        text(ctx, "DEST   TIME  DIST  EFOB", 40, 900, size: 40)
        text(ctx, "KLAX   0538   306   5.9", 40, 960, size: 44, colour: green)
    }

    static func dcdu(_ ctx: CGContext, _ d: DisplayInputs) {
        text(ctx, "NO ACTIVE ATC", 500, 520, size: 80, colour: white, align: 0.5)
    }

    /// The integrated standby instrument: attitude with speed and altitude beside it.
    static func isis(_ ctx: CGContext, _ d: DisplayInputs) {
        let c = CGPoint(x: 500, y: 520)
        ctx.saveGState()
        ctx.addRect(CGRect(x: 180, y: 120, width: 640, height: 800))
        ctx.clip()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: CGFloat(-d.roll * .pi / 180))
        let off = CGFloat(d.pitch) * 14
        ctx.setFillColor(CGColor(red: 0.1, green: 0.45, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: -900, y: -1800 + off, width: 1800, height: 1800))
        ctx.setFillColor(CGColor(red: 0.55, green: 0.33, blue: 0.12, alpha: 1))
        ctx.fill(CGRect(x: -900, y: off, width: 1800, height: 1800))
        line(ctx, CGPoint(x: -900, y: off), CGPoint(x: 900, y: off), white, 6)
        ctx.restoreGState()
        line(ctx, CGPoint(x: c.x - 200, y: c.y), CGPoint(x: c.x - 80, y: c.y), yellow, 14)
        line(ctx, CGPoint(x: c.x + 80, y: c.y), CGPoint(x: c.x + 200, y: c.y), yellow, 14)
        tape(ctx, CGRect(x: 0, y: 120, width: 170, height: 800), value: d.ias, step: 10, pxPerUnit: 8, label: { "\(Int($0))" }, every: 20)
        tape(ctx, CGRect(x: 830, y: 120, width: 170, height: 800), value: d.altitude, step: 100, pxPerUnit: 0.7,
             label: { "\(Int($0) / 100)" }, every: 500)
        text(ctx, "\(Int(d.ias.rounded()))", 85, 80, size: 60, colour: white, align: 0.5)
        text(ctx, "\(Int(d.altitude.rounded()))", 915, 80, size: 60, colour: green, align: 0.5)
        text(ctx, "QNH 1013", 500, 985, size: 50, colour: cyan, align: 0.5)
    }

    static func clock(_ ctx: CGContext) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        text(ctx, f.string(from: Date()), 500, 600, size: 190, colour: CGColor(red: 1, green: 0.8, blue: 0.2, alpha: 1), align: 0.5)
    }

    static func atc(_ ctx: CGContext) {
        text(ctx, "2000", 500, 640, size: 330, colour: CGColor(red: 1, green: 0.62, blue: 0.1, alpha: 1), align: 0.5)
    }

    static func batt(_ ctx: CGContext) {
        text(ctx, "28.1", 500, 680, size: 420, colour: CGColor(red: 1, green: 0.62, blue: 0.1, alpha: 1), align: 0.5)
    }
}
