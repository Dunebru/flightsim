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
echo "assets ok"
