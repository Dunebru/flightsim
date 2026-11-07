# Assets needed from you

Things only you can supply, buy or ask for. Each entry says where to get it, what it costs if known, and where to put it. Nothing here blocks M0 to M2.

## Wanted now (helps M3)

### Infinite Flight reference screenshots (free, optional but strongly recommended)
You asked for the UI to match Infinite Flight exactly. I am rebuilding it from scratch, so the closer the reference, the closer the result. If you have Infinite Flight on your phone, take landscape screenshots of: main menu, free flight setup (aircraft, livery, airport, gate/runway, time, weather), the in-flight HUD with nothing open, each panel open (autopilot, flight plan, map, ATC, camera menu, lights/systems, settings), the pause menu, and the map. Two or three in-flight shots in different cameras help too.

Put them in `Reference/InfiniteFlight/` (gitignored, never shipped, used only to compare layouts side by side).

## Later milestones

### EOX Sentinel-2 cloudless: bulk caching permission (M4, free)
The license (CC BY-NC-SA 4.0) allows non-commercial use, but the terms do not say whether baking many tiles into offline packs is fine; EOX asks bulk users to email them. Send a short note from your address to cloudless@eox.at saying it is a single-user, non-commercial, never-distributed flight sim and asking whether caching a few regions offline is acceptable. Until they answer I bake only one small test region from EOX; US regions use NAIP, which is public domain.

### AWS account for NAIP (M4, a few dollars)
NAIP's AWS buckets are "requester pays". Either an AWS account with credentials configured locally (`aws configure`, never committed), or I use Microsoft Planetary Computer instead, which is free. Default: Planetary Computer. Only needed if that turns out to be too slow.

### Aircraft models (M6, decided after free models are evaluated)
Free first. If the free models fall short, the verified shortlist is:

| Aircraft | Where | Price seen | License notes |
|---|---|---|---|
| 737-800 with interior | CGTrader, "B 737-800 with interior" | $299 | Royalty-free; fine for private use |
| 777-300ER with cockpit and cabin | TurboSquid | $479 | Royalty-free; requires a non-extractable format, which our cooked `.flm` satisfies |
| A320 | CGTrader / TurboSquid | $59 to $129 | Some are "editorial only"; avoid those |
| 737 MAX | RenderHub | $195 | |

Purchased files go in `Purchased/<aircraft>/` (gitignored, never committed).

### Navigraph (optional, M8)
Only if you want worldwide SIDs, STARs and approaches. Navigraph's developer FAQ says they cannot license data to a developer and that "home projects" are not covered, so this needs written permission from dev@navigraph.com before any purchase. Navigraph Unlimited is roughly €82/year (price from a search snippet, unverified). Default plan without it: US procedures from FAA CIFP, plus hand-entered procedures for the non-US top 20 airports.

### Tools to install on the Mac (approved; I install them when needed)
`gdal` via Homebrew (M4), Blender via Homebrew cask (M6), `astcenc` (M6).
