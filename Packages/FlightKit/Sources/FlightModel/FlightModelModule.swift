public import SimCore
import CJSBSim

/// FlightModel: Swift wrapper around JSBSim: 120 Hz physics thread, control inputs, failures.
/// Placeholder (M0 stub): no functionality yet. Implemented in M2; see PLAN.md section 3.2.
public enum FlightModelModule {
    public static let info = ModuleInfo(name: "FlightModel", status: .stub(plannedFor: "M2"))

    /// Version string reported by the linked flight dynamics engine ("stub" until M2).
    public static var engineVersion: String { String(cString: jsb_version()) }
}
