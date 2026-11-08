public import SimCore
import CJSBSim

/// FlightModel: JSBSim flight dynamics on a fixed-rate physics thread.
public enum FlightModelModule {
    public static let info = ModuleInfo(name: "FlightModel", status: .partial(missing: "published-number validation of the A320, ground handling tuning (M2)"))

    /// Version string reported by the linked flight dynamics engine.
    public static var engineVersion: String { String(cString: jsb_version()) }
}
