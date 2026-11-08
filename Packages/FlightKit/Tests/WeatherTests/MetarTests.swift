import Testing
import simd
@testable import Weather

struct MetarTests {
    @Test func liveKLAX() throws {
        let m = try #require(MetarParser.parse("METAR KLAX 080453Z 00000KT 10SM CLR 21/16 A3002 RMK AO2 SLP163 T02060156 $"))
        #expect(m.station == "KLAX")
        #expect(m.day == 8 && m.hour == 4 && m.minute == 53)
        #expect(m.windKnots == 0 && m.windDirection == 0)
        #expect(abs(m.visibilityMetres - 16_093) < 1)
        #expect(m.clear && m.clouds.isEmpty)
        #expect(m.temperatureC == 21 && m.dewpointC == 16)
        #expect(abs((m.altimeterHPa ?? 0) - 1016.6) < 0.1)
    }

    @Test func gustsLayersFractionsAndWeather() throws {
        let m = try #require(MetarParser.parse("SPECI KPHX 151756Z 24018G32KT 1 1/2SM +TSRA BR FEW008 BKN025CB OVC080 M02/M05 A2992 RMK PK WND"))
        #expect(m.windDirection == 240 && m.windKnots == 18 && m.gustKnots == 32)
        #expect(abs(m.visibilityMetres - 1.5 * 1_609.344) < 1)
        #expect(m.weather == ["+TSRA", "BR"])
        #expect(m.clouds.count == 3)
        #expect(m.clouds[1] == .init(cover: .broken, baseFeet: 2_500, type: "CB"))
        #expect(m.ceilingFeet == 2_500)
        #expect(m.temperatureC == -2 && m.dewpointC == -5)
        #expect(abs((m.altimeterHPa ?? 0) - 1013.2) < 0.1)
    }

    @Test func icaoStyle() throws {
        let m = try #require(MetarParser.parse("EGLL 081150Z VRB03KT 0800 R27L/1200 FG VV002 08/08 Q1021"))
        #expect(m.windDirection == nil && m.windKnots == 3)
        #expect(m.visibilityMetres == 800)
        #expect(m.weather == ["FG"])
        #expect(m.clouds == [.init(cover: .verticalVisibility, baseFeet: 200, type: nil)])
        #expect(m.altimeterHPa == 1021)
    }

    @Test func rejectsGarbage() {
        #expect(MetarParser.parse("hello world") == nil)
        #expect(MetarParser.parse("") == nil)
    }
}

struct WeatherConditionsTests {
    /// A 270 wind blows toward the east; it grows with height and stops growing at 2,000 ft.
    @Test func windDirectionAndProfile() throws {
        let m = try #require(MetarParser.parse("KPHX 151756Z 27010KT 10SM CLR 30/05 A2992"))
        let w = WeatherConditions(metar: m)
        let surface = w.wind(atHeightFeet: 0)
        #expect(abs(surface.y - 10) < 0.01 && abs(surface.x) < 0.01, "toward east: \(surface)")
        let high = simd_length(w.wind(atHeightFeet: 2_000)), higher = simd_length(w.wind(atHeightFeet: 10_000))
        #expect(high > 17 && high < 18.5)
        #expect(abs(higher - high) < 1e-9)
        #expect(w.visibilityMetres == 40_000)
        // 30 C at 340 m is 17.2 C above standard.
        #expect(abs(w.isaDeviation(fieldElevationMetres: 340) - 17.21) < 0.01)
        #expect(w.source == "KPHX 151756Z")
    }
}
