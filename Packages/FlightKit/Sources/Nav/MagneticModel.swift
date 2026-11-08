public import Foundation

/// The World Magnetic Model 2025 (NOAA NCEI and the British Geological Survey; US Government
/// work, public domain), valid 2025.0 to 2030.0: magnetic declination anywhere, for turning true
/// headings into the magnetic ones pilots fly and runways are named for.
public enum MagneticModel {
    static let epoch = 2025.0
    /// (n, m, g, h, g per year, h per year), nanotesla, from WMM.COF.
    static let coefficients: [(Int, Int, Double, Double, Double, Double)] = [
        (1, 0, -29351.8, 0.0, 12.0, 0.0),
        (1, 1, -1410.8, 4545.4, 9.7, -21.5),
        (2, 0, -2556.6, 0.0, -11.6, 0.0),
        (2, 1, 2951.1, -3133.6, -5.2, -27.7),
        (2, 2, 1649.3, -815.1, -8.0, -12.1),
        (3, 0, 1361.0, 0.0, -1.3, 0.0),
        (3, 1, -2404.1, -56.6, -4.2, 4.0),
        (3, 2, 1243.8, 237.5, 0.4, -0.3),
        (3, 3, 453.6, -549.5, -15.6, -4.1),
        (4, 0, 895.0, 0.0, -1.6, 0.0),
        (4, 1, 799.5, 278.6, -2.4, -1.1),
        (4, 2, 55.7, -133.9, -6.0, 4.1),
        (4, 3, -281.1, 212.0, 5.6, 1.6),
        (4, 4, 12.1, -375.6, -7.0, -4.4),
        (5, 0, -233.2, 0.0, 0.6, 0.0),
        (5, 1, 368.9, 45.4, 1.4, -0.5),
        (5, 2, 187.2, 220.2, 0.0, 2.2),
        (5, 3, -138.7, -122.9, 0.6, 0.4),
        (5, 4, -142.0, 43.0, 2.2, 1.7),
        (5, 5, 20.9, 106.1, 0.9, 1.9),
        (6, 0, 64.4, 0.0, -0.2, 0.0),
        (6, 1, 63.8, -18.4, -0.4, 0.3),
        (6, 2, 76.9, 16.8, 0.9, -1.6),
        (6, 3, -115.7, 48.8, 1.2, -0.4),
        (6, 4, -40.9, -59.8, -0.9, 0.9),
        (6, 5, 14.9, 10.9, 0.3, 0.7),
        (6, 6, -60.7, 72.7, 0.9, 0.9),
        (7, 0, 79.5, 0.0, -0.0, 0.0),
        (7, 1, -77.0, -48.9, -0.1, 0.6),
        (7, 2, -8.8, -14.4, -0.1, 0.5),
        (7, 3, 59.3, -1.0, 0.5, -0.8),
        (7, 4, 15.8, 23.4, -0.1, 0.0),
        (7, 5, 2.5, -7.4, -0.8, -1.0),
        (7, 6, -11.1, -25.1, -0.8, 0.6),
        (7, 7, 14.2, -2.3, 0.8, -0.2),
        (8, 0, 23.2, 0.0, -0.1, 0.0),
        (8, 1, 10.8, 7.1, 0.2, -0.2),
        (8, 2, -17.5, -12.6, 0.0, 0.5),
        (8, 3, 2.0, 11.4, 0.5, -0.4),
        (8, 4, -21.7, -9.7, -0.1, 0.4),
        (8, 5, 16.9, 12.7, 0.3, -0.5),
        (8, 6, 15.0, 0.7, 0.2, -0.6),
        (8, 7, -16.8, -5.2, -0.0, 0.3),
        (8, 8, 0.9, 3.9, 0.2, 0.2),
        (9, 0, 4.6, 0.0, -0.0, 0.0),
        (9, 1, 7.8, -24.8, -0.1, -0.3),
        (9, 2, 3.0, 12.2, 0.1, 0.3),
        (9, 3, -0.2, 8.3, 0.3, -0.3),
        (9, 4, -2.5, -3.3, -0.3, 0.3),
        (9, 5, -13.1, -5.2, 0.0, 0.2),
        (9, 6, 2.4, 7.2, 0.3, -0.1),
        (9, 7, 8.6, -0.6, -0.1, -0.2),
        (9, 8, -8.7, 0.8, 0.1, 0.4),
        (9, 9, -12.9, 10.0, -0.1, 0.1),
        (10, 0, -1.3, 0.0, 0.1, 0.0),
        (10, 1, -6.4, 3.3, 0.0, 0.0),
        (10, 2, 0.2, 0.0, 0.1, -0.0),
        (10, 3, 2.0, 2.4, 0.1, -0.2),
        (10, 4, -1.0, 5.3, -0.0, 0.1),
        (10, 5, -0.6, -9.1, -0.3, -0.1),
        (10, 6, -0.9, 0.4, 0.0, 0.1),
        (10, 7, 1.5, -4.2, -0.1, 0.0),
        (10, 8, 0.9, -3.8, -0.1, -0.1),
        (10, 9, -2.7, 0.9, -0.0, 0.2),
        (10, 10, -3.9, -9.1, -0.0, -0.0),
        (11, 0, 2.9, 0.0, 0.0, 0.0),
        (11, 1, -1.5, 0.0, -0.0, -0.0),
        (11, 2, -2.5, 2.9, 0.0, 0.1),
        (11, 3, 2.4, -0.6, 0.0, -0.0),
        (11, 4, -0.6, 0.2, 0.0, 0.1),
        (11, 5, -0.1, 0.5, -0.1, -0.0),
        (11, 6, -0.6, -0.3, 0.0, -0.0),
        (11, 7, -0.1, -1.2, -0.0, 0.1),
        (11, 8, 1.1, -1.7, -0.1, -0.0),
        (11, 9, -1.0, -2.9, -0.1, 0.0),
        (11, 10, -0.2, -1.8, -0.1, 0.0),
        (11, 11, 2.6, -2.3, -0.1, 0.0),
        (12, 0, -2.0, 0.0, 0.0, 0.0),
        (12, 1, -0.2, -1.3, 0.0, -0.0),
        (12, 2, 0.3, 0.7, -0.0, 0.0),
        (12, 3, 1.2, 1.0, -0.0, -0.1),
        (12, 4, -1.3, -1.4, -0.0, 0.1),
        (12, 5, 0.6, -0.0, -0.0, -0.0),
        (12, 6, 0.6, 0.6, 0.1, -0.0),
        (12, 7, 0.5, -0.1, -0.0, -0.0),
        (12, 8, -0.1, 0.8, 0.0, 0.0),
        (12, 9, -0.4, 0.1, 0.0, -0.0),
        (12, 10, -0.2, -1.0, -0.1, -0.0),
        (12, 11, -1.3, 0.1, -0.0, 0.0),
        (12, 12, -0.7, 0.2, -0.1, -0.1)
    ]

    /// Declination (degrees, east positive: magnetic north lies east of true north) at a
    /// geodetic latitude and longitude (degrees), height above the ellipsoid (km) and decimal year.
    public static func declination(latitude: Double, longitude: Double, heightKm: Double = 0, year: Double) -> Double {
        let n = 12
        let a = 6378.137, f = 1 / 298.257_223_563, e2 = f * (2 - f), reference = 6371.2
        let phi = latitude * .pi / 180, lambda = longitude * .pi / 180
        // Geodetic to geocentric spherical.
        let rc = a / (1 - e2 * sin(phi) * sin(phi)).squareRoot()
        let p = (rc + heightKm) * cos(phi), z = (rc * (1 - e2) + heightKm) * sin(phi)
        let r = (p * p + z * z).squareRoot()
        let phiC = asin(z / r)
        let ct = sin(phiC), st = max(cos(phiC), 1e-9)
        let dt = year - epoch

        // Schmidt semi-normalized associated Legendre functions and their colatitude derivatives.
        var P = [[Double]](repeating: [Double](repeating: 0, count: n + 1), count: n + 1)
        var dP = P
        P[0][0] = 1
        for i in 1...n {
            for m in 0...i {
                if i == m {
                    P[i][m] = st * P[i - 1][m - 1]
                    dP[i][m] = st * dP[i - 1][m - 1] + ct * P[i - 1][m - 1]
                } else if i == 1 || m == i - 1 {
                    P[i][m] = ct * P[i - 1][m]
                    dP[i][m] = ct * dP[i - 1][m] - st * P[i - 1][m]
                } else {
                    let k = Double((i - 1) * (i - 1) - m * m) / Double((2 * i - 1) * (2 * i - 3))
                    P[i][m] = ct * P[i - 1][m] - k * P[i - 2][m]
                    dP[i][m] = ct * dP[i - 1][m] - st * P[i - 1][m] - k * dP[i - 2][m]
                }
            }
        }
        // Gauss to Schmidt normalisation factors.
        var S = [[Double]](repeating: [Double](repeating: 0, count: n + 1), count: n + 1)
        S[0][0] = 1
        for i in 1...n {
            S[i][0] = S[i - 1][0] * Double(2 * i - 1) / Double(i)
            for m in 1...i {
                let j = m == 1 ? 2.0 : 1.0
                S[i][m] = S[i][m - 1] * (Double(i - m + 1) * j / Double(i + m)).squareRoot()
            }
        }

        var bt = 0.0, bp = 0.0, br = 0.0
        for (i, m, g0, h0, gd, hd) in coefficients where i <= n {
            let g = (g0 + gd * dt) * S[i][m], h = (h0 + hd * dt) * S[i][m]
            let ar = pow(reference / r, Double(i + 2))
            let cm = cos(Double(m) * lambda), sm = sin(Double(m) * lambda)
            let t1 = g * cm + h * sm, t2 = g * sm - h * cm
            bt -= ar * t1 * dP[i][m]
            bp += Double(m) * t2 * ar * P[i][m]
            br += Double(i + 1) * t1 * ar * P[i][m]
        }
        bp /= st
        let rot = phi - phiC
        let bx = -bt * cos(rot) - br * sin(rot)
        let by = bp
        return atan2(by, bx) * 180 / .pi
    }

    /// Decimal year of a date.
    public static func year(of date: Date) -> Double {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let y = utc.component(.year, from: date)
        let start = utc.date(from: DateComponents(year: y, month: 1, day: 1))!
        let end = utc.date(from: DateComponents(year: y + 1, month: 1, day: 1))!
        return Double(y) + date.timeIntervalSince(start) / end.timeIntervalSince(start)
    }
}
