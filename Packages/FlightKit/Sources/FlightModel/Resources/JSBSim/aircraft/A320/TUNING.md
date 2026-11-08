# A320 model tuning (flightsim)

The JSBSim library A320 (generic, 2002-era, author unknown) as shipped with JSBSim v1.3.3 cannot
rotate or reach stall angle: full nose-up elevator holds only 5.6 degrees angle of attack, so its
measured "stall" was 198 KCAS clean and its takeoff roll 10,683 ft. Each change below is listed
with the measured effect. Values are checked by Tests/FlightModelTests/PublishedPerformanceTests.

| ID | Change | Why |
|---|---|---|
| T1 | `Cmalpha` -4.0 -> -1.2 per rad | -4.0 with this model's lift slope (5.3 per rad) implies a static margin near 75% of MAC; airliners are about 10-25%. -1.2 is about 23%. |
| T2 | Ground effect added: lift factor `kCLge` on `CLalpha`, induced-drag factor `kCDge` on `CDalpha`, as functions of height over span | The library model had none, so a landing A320 felt no cushion. Factors are the JSBSim C172P's (Wieselsberger-style). |
| T3 | +0.45 lift in the 40 deg (CONF FULL) column of `CLalpha` | The library model has no slats. Before: VS1g CONF FULL 122 kt at 64 t, against ~109 kt derived from Airbus's 136 kt approach speed (Aircraft Characteristics, July 2026) and VLS = 1.23 VS1g. The increment also gives the real approach attitude: trimmed at 136 kt on a 3 degree glide the model flies alpha 5.5, pitch 2.5 (the A320 flies about 2.5 nose up). |
| T4 | `CmDe` -1.5 -> -1.8 | With flaps out, full elevator still could not reach the lift peak (alpha capped at 14 degrees). The real aircraft's trimmable stabiliser supplies that authority; the model lumps it into the elevator. After: the lift peak is reached at 16 degrees and VS1g CONF FULL is 106.9 kt at 64 t. |

Results after T1-T4 (Tests/FlightModelTests/PublishedPerformanceTests): VS1g CONF FULL 106.9 kt at
64 t (reference ~108.6); trims at FL350 Mach 0.789 with alpha 2.6 and 75% thrust; hands-off from a
250 KCAS trim, altitude within 9 ft over 60 s; takeoff ground roll 5,700 ft at 64 t with flaps 10.
Not checked for lack of a citable source: the CONF 0 stall speed (the model gives VS1g 148 kt at
64 t). Not modelled: slats as a separate surface, fly-by-wire control laws, alpha protection.
