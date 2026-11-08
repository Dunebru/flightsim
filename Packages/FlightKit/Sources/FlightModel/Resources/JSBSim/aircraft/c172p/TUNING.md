# C172P model tuning (flightsim)

Checked against the 1981 Cessna 172P POH at 2,400 lb (sources in PROGRESS.md). Measured by
Tests/FlightModelTests (TestPilot).

| ID | Change | Why |
|---|---|---|
| C1 | `c172p.xml` uses `prop_75in2f_c172p` (a copy of `prop_75in2f`) with `cp_factor` 1.2 and `ct_factor` 1.1 | As shipped, full throttle at Vy (76 KCAS) turned 2,735 RPM, above the 2,700 RPM redline, and climbed 875 fpm against the POH's ~700 at sea level: the propeller absorbed too little power. A single factor cannot match both climb and takeoff (they move together); this pair gives climb 794 fpm (+13%) and ground roll 992 ft against 890 (+11%, flaps 10, short-field). Climb RPM is 2,556, still somewhat high. Reshaping the thrust coefficient against advance ratio would close the remaining gap. |

Unchanged and already within tolerance: power-off stall speeds (minimum-speed method) 52.1 KCAS
clean and 46.8 KCAS flaps 30, against the POH's 51 and 46.
