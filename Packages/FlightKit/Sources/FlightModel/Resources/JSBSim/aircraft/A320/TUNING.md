# A320 model tuning (flightsim)

The JSBSim library A320 (generic, 2002-era, author unknown) as shipped with JSBSim v1.3.3 cannot
rotate or reach stall angle: full nose-up elevator holds only 5.6 degrees angle of attack, so its
measured "stall" was 198 KCAS clean and its takeoff roll 10,683 ft. Each change below is listed
with the measured effect. Values are checked by Tests/FlightModelTests/PublishedPerformanceTests.

| ID | Change | Why |
|---|---|---|
| T1 | `Cmalpha` -4.0 -> -1.2 per rad | -4.0 with this model's lift slope (5.3 per rad) implies a static margin near 75% of MAC; airliners are about 10-25%. -1.2 is about 23%. |
| T2 | Ground effect added: lift factor `kCLge` on `CLalpha`, induced-drag factor `kCDge` on `CDalpha`, as functions of height over span | The library model had none, so a landing A320 felt no cushion. Factors are the JSBSim C172P's (Wieselsberger-style). |
