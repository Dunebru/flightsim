import Foundation

/// How a US controller says things (FAA JO 7110.65): digits one at a time with "niner",
/// letters in the phonetic alphabet, runways by digits and side, altitudes in thousands and
/// hundreds below 18,000 ft and as flight levels above.
public enum Phraseology {
    static let digitWords = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "niner"]
    static let letters: [Character: String] = [
        "A": "alpha", "B": "bravo", "C": "charlie", "D": "delta", "E": "echo", "F": "foxtrot", "G": "golf",
        "H": "hotel", "I": "india", "J": "juliett", "K": "kilo", "L": "lima", "M": "mike", "N": "november",
        "O": "oscar", "P": "papa", "Q": "quebec", "R": "romeo", "S": "sierra", "T": "tango", "U": "uniform",
        "V": "victor", "W": "whiskey", "X": "x-ray", "Y": "yankee", "Z": "zulu",
    ]

    /// Each character on its own: "25" two five, "C3" charlie three.
    public static func spell(_ s: String) -> String {
        s.uppercased().compactMap { c -> String? in
            if let d = c.wholeNumberValue { return digitWords[d] }
            return letters[c]
        }.joined(separator: " ")
    }

    /// "25R" runway two five right.
    public static func runway(_ id: String) -> String {
        let number = id.prefix { $0.isNumber }
        let side: String = switch id.drop(while: { $0.isNumber }).uppercased() {
        case "L": " left"
        case "R": " right"
        case "C": " center"
        default: ""
        }
        return "runway " + spell(String(number)) + side
    }

    /// A taxiway as said: "B" bravo, "B3" bravo three.
    public static func taxiway(_ ref: String) -> String { spell(ref) }

    /// Heading or wind direction, three digits: 70 is zero seven zero.
    public static func heading(_ degrees: Int) -> String {
        var d = degrees % 360
        if d <= 0 { d += 360 }
        return spell(String(format: "%03d", d))
    }

    /// Altitude: "five thousand", "one one thousand five hundred", "flight level one eight zero".
    public static func altitude(_ feet: Int) -> String {
        if feet >= 18_000 { return "flight level " + spell(String(feet / 100)) }
        let thousands = feet / 1_000, hundreds = (feet % 1_000) / 100
        var parts: [String] = []
        if thousands > 0 { parts.append(spell(String(thousands)) + " thousand") }
        if hundreds > 0 { parts.append(digitWords[hundreds] + " hundred") }
        return parts.isEmpty ? "zero" : parts.joined(separator: " ")
    }

    /// Altimeter from hectopascals, in inches of mercury: two niner niner two.
    public static func altimeter(hPa: Double) -> String {
        let inches = Int((hPa / 33.863_9 * 100).rounded())
        return "altimeter " + spell(String(inches))
    }

    /// Wind: "wind two six zero at eight", "gusts two two", "wind calm".
    public static func wind(from: Double, knots: Double, gust: Double?) -> String {
        guard knots >= 1 else { return "wind calm" }
        var s = "wind " + heading(Int((from / 10).rounded()) * 10) + " at " + spell(String(Int(knots.rounded())))
        if let gust { s += " gusts " + spell(String(Int(gust.rounded()))) }
        return s
    }
}
