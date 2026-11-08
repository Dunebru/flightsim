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

    /// Each reported layer becomes the right kind of cloud at the right height above sea level.
    @Test func layersBecomeVolumes() throws {
        let m = try #require(MetarParser.parse("KLAX 151753Z 25008KT 3SM BR FEW008 SCT045TCU BKN120 OVC250 FEW060CB 18/16 A2990"))
        let v = WeatherConditions(metar: m).cloudVolumes(fieldElevationMetres: 38)
        #expect(v.count == 5)
        #expect(v[0].kind == .cumulus && abs(v[0].baseMetres - (38 + 243.84)) < 0.01 && v[0].topMetres > v[0].baseMetres + 1_000)
        #expect(v[1].kind == .cumulus && v[1].topMetres - v[1].baseMetres == 4_500, "TCU towers")
        #expect(v[2].kind == .stratus && v[2].coverage == 0.75)
        #expect(v[3].kind == .cirrus, "25,000 ft is cirrus")
        #expect(v[4].kind == .cumulonimbus && v[4].topMetres >= 11_000)
        let fog = try #require(MetarParser.parse("KSFO 151753Z 00000KT 1/4SM FG VV001 12/12 A3001"))
        let f = WeatherConditions(metar: fog).cloudVolumes(fieldElevationMetres: 4)
        #expect(f.count == 1 && f[0].baseMetres < 4 && f[0].coverage == 1, "obscured sky is fog on the ground")
        #expect(WeatherConditions(metar: fog).fogScaleHeightMetres == 120)
        #expect(WeatherConditions(metar: m).fogScaleHeightMetres == 400, "BR is mist")
        #expect(WeatherConditions(metar: m).precipitation == nil, "BR is not precipitation")
        let storm = try #require(MetarParser.parse("KPHX 151753Z 22018G32KT 5SM +TSRA FEW035CB 21/17 A2970"))
        let p = try #require(WeatherConditions(metar: storm).precipitation)
        #expect(p.kind == .rain && p.intensity == 1)
        let snow = try #require(MetarParser.parse("KDEN 151753Z 01010KT 2SM -SN BKN015 M03/M05 A3010"))
        #expect(WeatherConditions(metar: snow).precipitation?.kind == .snow)
        let nearby = try #require(MetarParser.parse("KPHX 151753Z 22010KT 10SM VCSH SCT060 30/10 A2990"))
        #expect(WeatherConditions(metar: nearby).precipitation == nil, "showers in the vicinity are not overhead")
        // Rough inside cloud, smooth between layers; surface gusts stir only the lowest kilometre.
        let cb = WeatherConditions(metar: storm)
        #expect(cb.turbulenceSeverity(altitudeMetres: 340 + 3_000, fieldElevationMetres: 340) == 5, "inside the CB")
        #expect(cb.turbulenceSeverity(altitudeMetres: 340 + 300, fieldElevationMetres: 340) == 4, "gusty near the ground")
        let layered = WeatherConditions(metar: m)
        #expect(layered.turbulenceSeverity(altitudeMetres: 38 + 1_500, fieldElevationMetres: 38) == 3, "inside the TCU")
        let two = WeatherConditions(metar: try #require(MetarParser.parse("KLAX 151753Z 25008KT 10SM SCT045 BKN120 18/10 A2990")))
        #expect(two.turbulenceSeverity(altitudeMetres: 38 + 3_300, fieldElevationMetres: 38) == 0, "clear air between layers")
        #expect(two.turbulenceSeverity(altitudeMetres: 38 + 2_000, fieldElevationMetres: 38) == 3, "inside the cumulus")
        // A west wind moves the clouds east.
        let w = WeatherConditions(metar: m).windVectorMetresPerSecond(atHeightFeet: 3_000)
        #expect(w.x > 3 && abs(w.y) < w.x, "toward east-northeast: \(w)")
    }
}
