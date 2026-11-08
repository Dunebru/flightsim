#!/bin/bash
# Bakes the scenery packs bundled with the app into Data/Bundle/Scenery: the KPHX and KLAX
# regions and the global base. Downloads are cached under Data/raw (gitignored), so a re-bake
# only fetches what is missing. Each pack is baked into a staging folder and replaces the
# installed one only if the bake succeeded and the result checks out.
#
# Needs: the KPHX DEM in Data/raw/dem (see PLAN.md section 7; made with GDAL from Copernicus
# GLO-30). Usage: scripts/bake-scenery.sh [kphx] [klax] [world]   (default: all three)
set -Eeuo pipefail
cd "$(dirname "$0")/.."

STAGING="Data/raw/staging"
INSTALL="Data/Bundle/Scenery"
TOOL="Tools/.build/release/flight-tools"
PACKS=("$@")
[ ${#PACKS[@]} -eq 0 ] && PACKS=(kphx klax world)

swift build -c release --package-path Tools 2>&1 | tail -1
mkdir -p "$STAGING" "$INSTALL"

bake() {
  local name="$1"; shift
  rm -rf "${STAGING:?}/$name"
  echo "==> $name"
  "$TOOL" terrain-bake --name "$name" --out "$STAGING/$name" \
    --terrarium-cache Data/raw/terrarium --imagery-cache Data/raw/imagery "$@"
  # The pack must have an index, and every tile in it must have heights and imagery.
  /usr/bin/python3 -I - "$STAGING/$name" <<'PY'
import json, os, sys
root = sys.argv[1]
index = json.load(open(os.path.join(root, "index.json")))
tiles = index["tiles"]
missing = [t for t in tiles if not os.path.exists(f"{root}/heights/{t}.h16") or not os.path.exists(f"{root}/imagery/{t}.jpg")]
if not tiles or missing:
    sys.exit(f"pack {root}: {len(tiles)} tiles, {len(missing)} incomplete, e.g. {missing[:3]}")
print(f"    ok: {len(tiles)} tiles, zoom {index['minZoom']}-{index['maxZoom']}")
PY
  rm -rf "${INSTALL:?}/$name"
  mv "$STAGING/$name" "$INSTALL/$name"
  echo "    installed $INSTALL/$name ($(du -sh "$INSTALL/$name" | cut -f1))"
}

for p in "${PACKS[@]}"; do
  case "$p" in
    kphx) bake kphx --center 33.44085,-112.011 --usgs-from-zoom 12 --naip-from-zoom 17 --airport Data/Bundle/Airports/KPHX.json \
            --dem Data/raw/dem/phoenix_3857.bin --dem-info Data/raw/dem/phoenix_3857.json ;;
    klax) bake klax --center 33.942501,-118.407997 --usgs-from-zoom 12 --naip-from-zoom 17 --terrarium-max-zoom 18 \
            --airport Data/Bundle/Airports/KLAX.json ;;
    world) bake world --world 5 ;;
    *) echo "unknown pack $p"; exit 64 ;;
  esac
done
