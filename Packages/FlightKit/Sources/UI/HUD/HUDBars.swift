import SwiftUI

/// Top bar: pause and clock on the left, the flight mode annunciator in the middle, and soft keys
/// on the right that open panels. Three separate bezels rather than one full-width bar, so the
/// sky stays open between them.
struct TopBar: View {
    @Bindable var model: HUDModel

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.gap) {
            HStack(spacing: 0) {
                SoftKey(title: model.paused ? "RESUME" : "PAUSE", isSelected: model.paused, width: 64) {
                    model.paused.toggle()
                }
                Divider().overlay(Palette.hairline)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.utc.string(from: context.date) + "Z")
                        .font(Typeface.value(13))
                        .foregroundStyle(Palette.textSecondary)
                        .padding(.horizontal, 10)
                }
            }
            .frame(height: Metrics.toolbarHeight)
            .bezel()

            Spacer(minLength: 0)
            ModeAnnunciator(model: model)
            Spacer(minLength: 0)

            HStack(spacing: 0) {
                ForEach(HUDModel.Panel.allCases) { panel in
                    SoftKey(title: panel.rawValue, isSelected: model.openPanel == panel) {
                        withAnimation(.snappy(duration: 0.22)) { model.toggle(panel) }
                    }
                    if panel != HUDModel.Panel.allCases.last {
                        Divider().overlay(Palette.hairline)
                    }
                }
            }
            .frame(height: Metrics.toolbarHeight)
            .bezel()
        }
    }

    private static let utc: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

/// A bezel soft key, like the labeled keys around a cockpit display. Selected keys get a cyan bar.
struct SoftKey: View {
    let title: String
    let isSelected: Bool
    var width: CGFloat = 46
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(title).labelStyle(isSelected ? Palette.selected : Palette.textPrimary, size: 10)
                Rectangle()
                    .fill(isSelected ? Palette.selected : .clear)
                    .frame(width: 18, height: 2)
            }
            .padding(.top, 6)
            .frame(width: width, height: Metrics.touch)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Flight mode annunciator: what the automation is doing right now, in green when engaged and
/// cyan when armed, the way it reads on a real primary flight display.
struct ModeAnnunciator: View {
    @Bindable var model: HUDModel

    var body: some View {
        HStack(spacing: 0) {
            cell(model.autothrottle ? "SPEED" : "MAN THR", color: model.autothrottle ? Palette.active : Palette.textSecondary)
            separator
            cell(model.apMaster ? "V/S" : "—", color: Palette.active, below: model.approachArmed ? "G/S" : nil)
            separator
            cell(model.apMaster ? "HDG" : "—", color: Palette.active, below: model.locArmed || model.approachArmed ? "LOC" : nil)
            separator
            VStack(spacing: 1) {
                Text(model.apMaster ? "AP1" : "AP OFF")
                    .foregroundStyle(model.apMaster ? Palette.textPrimary : Palette.caution)
                Text(model.autothrottle ? "A/THR" : " ")
                    .foregroundStyle(Palette.textPrimary)
            }
            .font(Typeface.title(10))
            .tracking(Typeface.labelTracking)
            .frame(width: 60)
        }
        .frame(height: Metrics.toolbarHeight)
        .bezel()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Flight modes")
    }

    private var separator: some View {
        Rectangle().fill(Palette.hairline).frame(width: 1, height: 28)
    }

    private func cell(_ text: String, color: Color, below: String? = nil) -> some View {
        // Engaged mode on top in green; an armed mode, if any, below it in cyan. With nothing
        // armed the engaged mode sits centered rather than leaving an empty row.
        VStack(spacing: 1) {
            Text(text).foregroundStyle(color)
            if let below { Text(below).foregroundStyle(Palette.selected) }
        }
        .font(Typeface.title(10))
        .tracking(Typeface.labelTracking)
        .frame(width: 64)
    }
}

/// Bottom data strip: the numbers you fly by, monospaced so they never jitter.
struct DataStrip: View {
    @Bindable var model: HUDModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            strip(compact: false)
            strip(compact: true)
        }
    }

    private func strip(compact: Bool) -> some View {
        HStack(spacing: 0) {
            cell("IAS", "\(model.indicatedAirspeed)", unit: "KT")
            divider
            cell("GS", "\(model.groundSpeed)", unit: "KT")
            divider
            cell("ALT", model.altitude.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US"))), unit: "FT")
            divider
            cell("V/S", signed(model.verticalSpeed), unit: "FPM")
            divider
            cell("HDG", String(format: "%03d", model.heading), unit: "MAG")
            if !compact {
                divider
                cell("AOA", String(format: "%.1f", model.angleOfAttack), unit: "DEG")
                divider
                cell("N1", String(format: "%.1f", model.n1), unit: "%")
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 52)
        .bezel()
        .fixedSize()
    }

    private var divider: some View {
        Rectangle().fill(Palette.hairline).frame(width: 1, height: 30)
    }

    private func cell(_ label: String, _ value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).labelStyle(Palette.textSecondary, size: 8)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(Typeface.value(19))
                    .foregroundStyle(Palette.textPrimary)
                    .contentTransition(.numericText())
                Text(unit).labelStyle(Palette.textTertiary, size: 7)
            }
        }
        .padding(.horizontal, 10)
        .accessibilityElement(children: .combine)
    }

    private func signed(_ v: Int) -> String {
        v > 0 ? "+\(v)" : "\(v)"
    }
}
