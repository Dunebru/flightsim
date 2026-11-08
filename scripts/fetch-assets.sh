#!/usr/bin/env bash
# fetch-assets.sh: downloads third-party assets the build needs but git does not carry.
# Every file is pinned to an exact upstream commit and checked against a SHA-256.
# Idempotent: files that already match are skipped. Output goes to Data/ (gitignored).
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Cessna 172P exterior and cockpit model (AC3D + PNG textures), c172p-team/c172p, GPL-2.0.
# Placeholder-quality test aircraft for M1; the fleet pipeline arrives in M6.
C172P_COMMIT="63ba85273b7f44637eb4683dcdc8f97af7821653"
C172P_DIR="$ROOT/Data/Bundle/Aircraft/c172p"
C172P_FILES=(
  "c172-common.ac 2026d777964edf0efd41db950392d19eccd503bf9f14288e1c6930a84072239b"
  "fuselage-normal.png 678129b798af241442b72d07f04855b93f10d1228ca8912783eb13525c461cfd"
  "fuselage.png 0abd235787aff3875e4925dbdea66548ab4ebf777817f2f6440861555586a004"
  "glass-alpha.png 1f7a9d02158433c8865e8968bf8e19fde8f69691884da95347f6be3aebdb98ce"
  "interior.png 371ca4014f4ae3200bc69ceaf980417ecc7c33ec37c8d251f48019e93afe76c4"
  "lights.png 753c7905ac38eda3a8203ece494aae6be706c5d8b950f7a5da0812a97c38a208"
  "panel.png d9f2bb0ca47ee8aa4503854e253bcfa3dc284e13f991df73ea6951a012c9574e"
  "panel_parts.png f7f2ffb3b7229e52643a68097a941adff882f1d164a5ecd828825697d7bfccb5"
  "prop.png 441cbf5a9f6b605dfedf502b433449463aac455b0f51f92e018dc4debc9cf66f"
  "tail-normal.png a58a9e5074af24010718f3bd45685bedcfa260f84eccdfd6086f8d560d3af465"
  "tail.png 2248e1fb506af432dd06904e79e6b2d42d228642226b1261ad982b1bae17f0ac"
  "wing-normal.png 7b4f1f73ce6f3c699b7e215ac7f7722296619dbb9232ca49acc68c6cc1a0bc01"
  "wing.png bac29254864db96988d8f4917df04d04e0a9915e5b0de52d9b9bd75a32553950"
)

fetch_set() {
  local base="${1:?}" dir="${2:?}"; shift 2
  mkdir -p "$dir"
  local entry name sum have part
  for entry in "$@"; do
    name="${entry%% *}"; sum="${entry##* }"
    if [ -f "${dir:?}/${name:?}" ]; then
      have=$(shasum -a 256 "${dir:?}/${name:?}" | awk '{print $1}')
      [ "$have" = "$sum" ] && continue
    fi
    part="${dir:?}/${name:?}.part"
    curl -fsSL --retry 2 -o "$part" "$base/$name"
    have=$(shasum -a 256 "$part" | awk '{print $1}')
    if [ "$have" != "$sum" ]; then
      echo "checksum mismatch for $name (got $have)" >&2
      mv -f "$part" "${dir:?}/${name:?}.rejected"
      exit 1
    fi
    mv -f "$part" "${dir:?}/${name:?}"
    echo "fetched $name"
  done
}

fetch_set "https://raw.githubusercontent.com/c172p-team/c172p/$C172P_COMMIT/Models" "$C172P_DIR" "${C172P_FILES[@]}"

# The A320 family by legoboyvdlp and Octal450 (FlightGear, GPL-2.0): the CFM56-powered A320
# airframe, its engines and four liveries. Originals go to Data/raw/a320; the app gets copies
# with the 4K liveries scaled to 2048 px (a phone holds several at once).
A320_COMMIT="fec1ecba767c8fffd145337b27012e89c01e3ade"
A320_BASE="https://raw.githubusercontent.com/legoboyvdlp/A320-family/$A320_COMMIT/Models"
A320_RAW="$ROOT/Data/raw/a320"
A320_DIR="$ROOT/Data/Bundle/Aircraft/A320"
fetch_set "$A320_BASE/Fuselage/res" "$A320_RAW" \
  "A320-216.ac 0bd775520f9948f24f868ed82dc6852704dac56856696b066f9fe9ac28f8bf30" \
  "CFM56.ac fe95776240aac63bdbbf33dedf1770c7b2b50b257ac018f788b9f45552dd77e5" \
  "LandingGears.png 9ecb333a55f3ab8e2f868995bcb4ceecbdb0dc8b380d7f1b86c847bcae884c91" \
  "Static-Elements.png 8685bfe5fd628f3ca3bc2b949b4f0e2d6ac8eff480c685ae84728e935ecaefc9" \
  "placards.png 3f2e74db8af8e2a83f79e9c715a14720b69d0edab2b6617cab1f9c6ecdf340ee"
fetch_set "$A320_BASE/Liveries/CFM/4k" "$A320_RAW" \
  "AAL-fuselage.png 802ec9166cb81ad01dfd16afd8cac602fec5f57e3b473c7d43d24658c76fc62a" \
  "DAL-fuselage.png 0d603b264d74678c272d794bf185d98a177adda80cef39d2a5186d2fb5f53551" \
  "SWR-fuselage.png 3d53a28696ddbf05e7c94118846d030d8883976d9fcdbd127f657db349769586" \
  "AUA-fuselage.png 60ddae11fc32eed801b62bc7cd2db80c4708d452fc158c5f524b5cd4c929b028"
fetch_set "$A320_BASE/Liveries/CFM/2k" "$A320_RAW" \
  "AAL-engine.png 336086566921425f321dfdd0c30ceb6b9950fbbd973fb06425be4356c4f45b54" \
  "DAL-engine.png b1d46b3c47e5aa1b34b6814151ceea87a4f1700e7f28da797158bc386440ccb5" \
  "SWR-engine.png aa416852b556c283d58f06f1abdbfeba79d7b7533f46f5f2c849f2345ed50640" \
  "CFM56-white.png aa416852b556c283d58f06f1abdbfeba79d7b7533f46f5f2c849f2345ed50640"
mkdir -p "$A320_DIR"
for f in A320-216.ac CFM56.ac; do
  cmp -s "$A320_RAW/$f" "$A320_DIR/$f" || cp "$A320_RAW/$f" "$A320_DIR/$f"
done
# Fuselage sheets at 2048 px (the player's aircraft); everything else, and the parked and moving
# traffic's fuselages ("-1k"), at 1024 px.
cook() {  # cook <source> <dest name> <pixels>
  if [ ! -f "$A320_DIR/$2" ] || [ "$A320_RAW/$1" -nt "$A320_DIR/$2" ]; then
    sips -Z "$3" "$A320_RAW/$1" --out "$A320_DIR/$2" >/dev/null
  fi
}
for code in AAL DAL SWR AUA; do
  cook "$code-fuselage.png" "$code-fuselage.png" 2048
  cook "$code-fuselage.png" "$code-fuselage-1k.png" 1024
done
for f in LandingGears.png Static-Elements.png placards.png AAL-engine.png DAL-engine.png SWR-engine.png CFM56-white.png; do
  cook "$f" "$f" 1024
done
echo "assets ok"
