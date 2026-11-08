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
  "fuel-selector.png e99e386587b53aa584aea6e5f1a42f82e20b1c1508577c50c7385a7c55241274"
)

# The C172P cockpit: interior, panel, the instruments with their animation XML, yoke and
# pedals (same repository and commit). Originals keep their folders in Data/raw/c172p; the app
# gets every file flat beside the exterior (no two share a name).
C172P_RAW="$ROOT/Data/raw/c172p"
C172P_COCKPIT_FILES=(
  "Panel/Flaps/flaps.ac 82066ac587cad23a34d3b350c99706373baf1d638e2971a5c31e60bc46be3352"
  "Panel/Flaps/flaps.png cbcd5acf6729cf61520ea2ed01ee6909d005b98d42a7902ebe68727205dd904d"
  "Panel/Flaps/flaps.xml 8f8e9430c5a37876549b258a5cdd23e609ea1f7bde813b370c35effd4ce701fd"
  "Panel/Instruments/AI/AI.ac b2a81912a796a9b318fb6f1e7090e46a6b499025338d4b314c9cf71f5227d80c"
  "Panel/Instruments/AI/AI.png 1cc46c55eeb235ff3a7c0aa2e0d00354ff7fd89c643c12bd723945dc30164312"
  "Panel/Instruments/AI/AI.xml d1c20fd7522255052588166b65ac855a8fe43a57e12bf09a81b8b778f62cc541"
  "Panel/Instruments/BatteryGauge/BatteryGauge.ac 4eac43ba95d58d8511028fb4a0ee4711f841883ee147022a6eb896e7a9925887"
  "Panel/Instruments/BatteryGauge/BatteryGauge.png f54adedb9e0dd382eeec9d7c56f1add433e7596c5ee11adc2727f2a012dd8f79"
  "Panel/Instruments/BatteryGauge/BatteryGauge.xml 9dd304ba467dd9945a7ca56dd6339f1ec9d701222403a71d3e41337af06a3f37"
  "Panel/Instruments/EGT/EGT.ac 2e1b928756aadb89f09b9d71cd4185ff9c79594e2f06673bfceb9aa3f938e9fd"
  "Panel/Instruments/EGT/EGT.png 5f8bc20ccc28c1335f75658c30f1f075d739ca2bec6c8230f65d7cb3a15ae248"
  "Panel/Instruments/EGT/EGT.xml ef239dd05346a68db268c61c5bad56db8f75d718df5ad3ff4f3c3762181f0af5"
  "Panel/Instruments/FuelOilAmps/c172fuel.ac e8888b86cfc09c6ed0859ba9e17de572acbfed30cb1f81ca145fb2db38c25b30"
  "Panel/Instruments/FuelOilAmps/c172fuel.xml c68e551f55406d464172ac91088f0a6ce0aaba121545a88134451c25ee0a7e81"
  "Panel/Instruments/FuelOilAmps/c172oil.ac dc3a99126297d0c8c5bc322b04fd08bd3ff285d7460b7ed5249afe8a7727a314"
  "Panel/Instruments/FuelOilAmps/c172oil.xml bae15d3a91eaf2ab5f9dadfe095adcf63d94ecbadcfc964518a65b371a4e2ee5"
  "Panel/Instruments/FuelOilAmps/fuel-oil.png ec41aeb5b89215ff798756ec3431015935effcb88ed1adc370b2212542ea42de"
  "Panel/Instruments/RPM/RPM.ac 7e193c9d6b7b70f4e063fa148cf43a7dcd6e092a46c7bb1fe3d148a4892498a2"
  "Panel/Instruments/RPM/RPM.png ab94efe5d2899cf0db25fbb31a1b222d279478a891fe2d06bacd76837f77f633"
  "Panel/Instruments/RPM/RPM.xml 5868453fa4c06a8dd4e4055431cb20c95b85baedc7df7fc357e3820ccf886954"
  "Panel/Instruments/VSI/VSI.ac 4b32735b7fad7084db62fdf30660803d605b023d915232ac24bce7c39e1ffee1"
  "Panel/Instruments/VSI/VSI.png 413403a0a2b3d5d7e27a5f21fce10c635511faec90446e295aaa474ccf24e758"
  "Panel/Instruments/VSI/VSI.xml 22e8f4bf45c3bcc97c0232d91504413f486806e116c05a5be0f6a1f93169a2f2"
  "Panel/Instruments/alt/alt.ac 73e1b2fb05949e836c3f937a58665d561cd19cbc38607630689672ddca44662c"
  "Panel/Instruments/alt/alt.png 3a5406c4a7d99eb6900fc5d6913a9d3b3b15b17b6c10a4f2e4bd8ec459879a0e"
  "Panel/Instruments/alt/alt.xml 5d71ebbef3c8cf5689b06f2eae3a450fb69b50a751bd7a69dd5bbfff778bdcf3"
  "Panel/Instruments/asi/asi.ac a8f72730f5c44b568f88de4018a39b5499b9117c3d8ab5e9c53ed5fd1a828890"
  "Panel/Instruments/asi/asi.png 0c3284e28f3c087ab79b6fda9a71593147d78ec7b3b8c771744c9cca91b84d7e"
  "Panel/Instruments/asi/asi.xml b7030ee42a284c2c703d9be8237e75ab358613982da00c3a2baac0fdf20df601"
  "Panel/Instruments/clock/clock.ac 7c0a6aa36a6050c7c3ef4af9c8a879054de3cd611cec1a0053aa07222df37be0"
  "Panel/Instruments/clock/clock.png 7bb65ebf3d1d8b6fef84ae823715abaa30243201f0f456050a0b6d0ba856cab2"
  "Panel/Instruments/clock/clock.xml 8ee58b9a0cfce0dfc9cc22f0f514b156b92cd176099098ca2baa280588dc76d7"
  "Panel/Instruments/dme/dme.png 680490c8128258f585a130fac5b0d0d1eadd48c02ab6983e6a762fda1918e28a"
  "Panel/Instruments/dme/ki266.ac 0426e2ac141e987cf5ff1a61fd065539bd1d8157f3ad483d464509ad888a960d"
  "Panel/Instruments/dme/ki266.xml 31ef0a85ecd5cc341d583d2505acbc915031941ee634619baf2b84d3f6856683"
  "Panel/Instruments/hi/hi.ac 9bbfc8211d14e1f0510d2c17f3fa6f4272cef4e7ff7df69293c8fac7e89ac373"
  "Panel/Instruments/hi/hi.png 338adf525e2f544f40cf4790110a5a7b55561530a07ec122d9c22bbacd370607"
  "Panel/Instruments/hi/hi.xml fed6c458c4d52d8da135d824c029b6918020fba5eb57186b9bbfb2e23f4c0931"
  "Panel/Instruments/hobbs/hobbs.ac 54a1591f8c02e71c09c15cdc7546a4dc57833c239ecab85a3c8f0162555b05c8"
  "Panel/Instruments/hobbs/hobbs.png 3ef765bdbb730b7910d42ad2ca9f65f7165d6ac0b6b18459d584eb430417bf94"
  "Panel/Instruments/hobbs/hobbs.xml 8b0795b92bba647069ddcd7e51cf25d460aaa7a205e30dfaddd89883e56029cb"
  "Panel/Instruments/kap140/kap140.ac 677eb1af505307defb10b812af580c3dfa549f6199421e771976a1bcf0f2048c"
  "Panel/Instruments/kap140/kap140.png 232e48a808af0f46d4e53f6c169633fe8b264961a708ee56814fd4d818ae4f02"
  "Panel/Instruments/kap140/kap140.xml 215dc3228c86c1d9d005a44719aabcbb08c9de59ef380ad80512afd39617cb6c"
  "Panel/Instruments/kap140/nav-selector.xml cf67364960059bbc3215ff33116f2625e129a97e6e1d0d18453b5ba44f771630"
  "Panel/Instruments/kma20/kma20.ac 5173e01296b0b87366819f48dfd295b359df6eed17afb4a364d5d8b8f62e4e9e"
  "Panel/Instruments/kma20/kma20.png f0c416b51eea7fee82d592db6a958e81c9523099c6f848b538d73d594197057a"
  "Panel/Instruments/kma20/kma20.xml 44f612e753699bfe9394a6bbd8907f7c3b327066039ac215953b21aabb81f717"
  "Panel/Instruments/kma20/kma20init.xml 39cf24f2825439d3844ca8e5ea274eaa83bbf1e531a08e8329ed5b7a1d2a7596"
  "Panel/Instruments/kr87-adf/adf.png c8876eccc86e1ad5ac0a416e5235f26f0fec97903d02be93fb0edf109de93853"
  "Panel/Instruments/kr87-adf/ki227_228.ac 4b4547582d366ddbb1c361516129ad5c8b1d29284ae64fd9c7be208e3df13b29"
  "Panel/Instruments/kr87-adf/ki227_228.xml df50de4107deb284709fbfa9366165b557bcb3042220e1406076c7427d045f7e"
  "Panel/Instruments/kr87-adf/kr87.ac 345b840596d1caf659b09b4af81aa844eae5670cb0d2bb732671eac0a604b8b9"
  "Panel/Instruments/kr87-adf/kr87.png dbcacc2501f464ed1afe703d1af8ad1927d9d46258261697765c3fb1f6676982"
  "Panel/Instruments/kr87-adf/kr87.xml 074a514028df5ee9c5c6f74451cd3e70183c41af24cfb003239d219b30d2a6ab"
  "Panel/Instruments/kt76a/kt76a.ac f7296470a6f9262c03162e5c659a683cc5d841269c462d9cfcb2574f245cc042"
  "Panel/Instruments/kt76a/kt76a.png d8a6574795ff04eb6a4d470cc19bc487d9d89fc27f7d682218c95db9a581fa85"
  "Panel/Instruments/kt76a/kt76a.xml ac8bdc5b51f124120ab6d368b58e2e38ce410b3d8bf8441d88a4bbd38135d3af"
  "Panel/Instruments/kx165/kx165-1.ac 6756e2c53d28efd0b2e8a5e5bb162b9ec0115dbd86bcd0773a50186af5afd75f"
  "Panel/Instruments/kx165/kx165-1.xml 058f383ae315d6e55708b0c63be1a868d5edfaf4e22793158186f8c3a813f8ac"
  "Panel/Instruments/kx165/kx165-2.ac 0d47a0408ab69a9aa7f83b2bc359092b2a8077db51bf92c492aa4df08cc68616"
  "Panel/Instruments/kx165/kx165-2.xml 5869f1fdb38d012b9be7f551cc3520ee22c619e4dd7412227b80c3efd3bb4c90"
  "Panel/Instruments/kx165/kx165.png 4677a60756190eb45545b3d4f8ccbb2acc87159012f32755d9ec536923e2e995"
  "Panel/Instruments/mag-compass/compass-correction-card.png 318e71fc200ff7f5344d52613effcaf3d5be3adb6c2ae24b55616ad8658058b9"
  "Panel/Instruments/mag-compass/mag-compass-float.ac af6b95912f106b8762f7b7bdb9d98daf45edcc704af2f078a6fdd84f4c91ec9b"
  "Panel/Instruments/mag-compass/mag-compass-float.xml 2b4c3eb458988eb009d45d2968d1887b110d929a6c101a634f8f4964a325699f"
  "Panel/Instruments/mag-compass/mag-compass.ac cd69aeae60362b02c80cbb78ef5d1ff49af5124a0e4ecfcc38734795e638bc96"
  "Panel/Instruments/mag-compass/mag-compass.png 81332d59cbf23e60e3ccc8e38486d09fd60edff80c2bb37acb721c5fcc27e2bb"
  "Panel/Instruments/mag-compass/mag-compass.xml 7195af19d3b782c32c59da030b61113bfb5e09dfab182100c87913f6b7bae6a9"
  "Panel/Instruments/magneto-switch/magneto-switch.ac fe801fa0e8a9396f8ecbd5afa5ea5cf9f33acfc6195639883f902524352fc80b"
  "Panel/Instruments/magneto-switch/magneto-switch.png fad3f150a751503d8e2e2205035e8a755fbcaad2c1fb95e00432b4ef8942f27c"
  "Panel/Instruments/magneto-switch/magneto-switch.xml e4318153b56a13b69d2f5a5360ad057d28bf0c129a32a74b81831f747e3fbda9"
  "Panel/Instruments/tc/tc.ac d83c8f3d0e80b3c3949ccb3cad7cad7a2b7965043f5f8ad51607e5dd5cd77101"
  "Panel/Instruments/tc/tc.png 7f4fbecac0b5c2586fa18c8eb6b1bcd4535965f30bf5ab5f0482c2690e393337"
  "Panel/Instruments/tc/tc.xml 752e8cd268b8b38802f5e75f11296cfd5974079eec397598896c50b8b8233c74"
  "Panel/Instruments/vac/vac.ac 15c986484c0e713e3b6eb81767fb9808fc27ca6bc3c6198f2afc6c1a2e127b07"
  "Panel/Instruments/vac/vac.png 8ab1a930ac1c058622ef216d6faa2fbe3305bc08aeb8e24dad8c3234d75c9a1d"
  "Panel/Instruments/vac/vac.xml 61e7cdba0137405774a45525c8e295fc8a4eb1f323080f13338db7785be629e6"
  "Panel/Instruments/vor/vor.png 4bb8549cca20dbd44dac6fa3da5887f59c7a78b74e81f47cda77e718bbd5a21d"
  "Panel/Instruments/vor/vor.xml c0d783b5c44593e87efce44c75cce979056cea1f850e94d8b2817e3b7b77e08a"
  "Panel/Instruments/vor/vor1.ac f088106ece50c448e6e028a89ce06b327b0b96d71669cd93079d774f582e9372"
  "Panel/Instruments/vor/vor2.ac 249b1bb339d41749feee0b1ccc8a0f4cf2ca9c70a874b69661df8e27e6198772"
  "Panel/Instruments/vor/vor2.xml 47e8c3b73e4bc60ac72319aa54baccc0f9d341abf31a9c4c76dcc4d2634a1ad6"
  "Panel/c172p-panel/c172p-interior.ac fc3c24701c1f983628b740c07911fd0356b8101002c11d886e708e6dbd288948"
  "Panel/c172p-panel/c172p.xml b36b92a63ff18d7994d8342df84c1ccc5327b0e3b4a371308ce7b65bfa567914"
  "Pedals/pedal.png 490cfd6b85a207974b7c1ae2cedaf1ad468b5d5af8f47c604c97e1f051518933"
  "Pedals/pedals-pilot.xml 1c9cbd51456918bf225c3c1738a8b1c4e8a1d82cdb8c6237e5f8b0809d658d24"
  "Pedals/pedals.ac 463625db814a14043f54f323e1a647ac711ff19d7481151e6e606178eebc55e0"
  "Yoke/yoke.ac e8221a2194b825cfa68a571bcb42d623c4d86ebf8b14ed1598dedf02bec3a67b"
  "Yoke/yoke.png 2c8276716c65fa17e919ed3dd19daa650ff6e9b9e148bcd6fff5f740a23e1300"
  "Yoke/yoke.xml de438125c3fc68cc5cff0db7d04ddb0cbcaacff7207772775c165d55e8230d15"
  "Yoke/yoke_mount.png 9b6f7ea42ab690f5138f06300b83cb234aa2aab1651d34505689706319432972"
)


fetch_set() {
  local base="${1:?}" dir="${2:?}"; shift 2
  mkdir -p "$dir"
  local entry name sum have part
  for entry in "$@"; do
    name="${entry%% *}"; sum="${entry##* }"
    mkdir -p "$(dirname "${dir:?}/${name:?}")"
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
fetch_set "https://raw.githubusercontent.com/c172p-team/c172p/$C172P_COMMIT/Models/Interior" "$C172P_RAW" "${C172P_COCKPIT_FILES[@]}"
# The airframe's own model file (its animations: control surfaces, nose wheel, throttle and
# mixture knobs), named apart from the panel's c172p.xml in the flat folder.
fetch_set "https://raw.githubusercontent.com/c172p-team/c172p/$C172P_COMMIT/Models" "$C172P_RAW/model" "c172p.xml 46070342dc08ca8b0713429786e1a61c8547aad0fd929fabcd8728440f24c1da"
cmp -s "$C172P_RAW/model/c172p.xml" "$C172P_DIR/c172p-model.xml" || cp -f "$C172P_RAW/model/c172p.xml" "$C172P_DIR/c172p-model.xml"
for entry in "${C172P_COCKPIT_FILES[@]}"; do
  name="${entry%% *}"
  cmp -s "$C172P_RAW/$name" "$C172P_DIR/$(basename "$name")" || cp -f "$C172P_RAW/$name" "$C172P_DIR/$(basename "$name")"
done

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
# Their animation files: gear retraction and doors, strut compression, wheel and fan spin,
# flight controls, spoilers, slats, flaps, reversers.
fetch_set "$A320_BASE/Fuselage" "$A320_RAW" \
  "fuselage.xml 718a74bbf84d444dd86beed3a8427be2e451ad2246eb50cfaa928e80338b5a6d" \
  "a320.cfm.xml 6a23afce46658c418892e9926ffd97b72cbc0960b97b16424bc3a755cf8f3436"
# The A320 flight deck (Models/FlightDeck, same repository): the model, its animation file and
# the textures it uses; the 4K sheets scaled to 2048 px for the phone.
fetch_set "$A320_BASE/FlightDeck" "$A320_RAW/FlightDeck" \
  "a320.flightdeck.xml 423586d54d95bff48bcb1ed3316289abcb604ddf29066cc6e10857b5d0423a10" \
  "res/fd_complete.ac a6f85edf93f54f89e1513e394cd23d934403aedd5cfad2f91f4944c90de489ae" \
  "res/Clock.jpg d55ebd97d53d886aae3492ea8289dd4c2b9fa573dc6c188c4b0d901aff843ac4" \
  "res/DDRMI.png 34c14b41741644370d911ea63a1620bf58241cfa5794b791fc83d7a8b7c6d9fb" \
  "res/ECAM.png 8409f1e77ef63690599f45ecece8e09fed8dca17ef17cb11bd0edf806d2c7a58" \
  "res/MCDU_screen.png 6860b583d65fd0423ada637c4aa5bf4698bf2b6d92aa4db2e9c4708a2f34fb03" \
  "res/Pedestal_low.png 60ca3c92f71a02984119782d2c506ab7ec848def5e9eb80767b1e9eadfc605f8" \
  "res/Radio.jpg 2daf3430d88babb2f9f841b9e67e0273e573f74be39f04e0d56186fa85d1f33b" \
  "res/carpet2.png 1164fe410f82b8a69f14470d56ef4c41389044d9229323986d825f9a3fd6711d" \
  "res/checklist.png db65d7a31bd6b6fafa64b9246a7e20d9a9709e28271e9f0a311058d13b526b3d" \
  "res/cpit_5.png 9a78bb1fcfcaab20205019d5243684997dd40ebef400b7e7c760647c7b13c28b" \
  "res/dcdu-screen.png dce3088e12ec73d0710dddfc0fd103974d88e128aa832d2340be7ab6a1d1061f" \
  "res/dcdu.png cd99923393aa2bdb7eb7730d5a193f175d3931027df03e8214046c04b879f48d" \
  "res/fabric2.png ee552cb8d75f8c826ff976393ed4d053295149203e92b8622d4a6c727cc9ae1a" \
  "res/fcu.png 0a1b18cda6b73afdf72bba366eeaa563de54eda59b8dd601a9d685f2d092af77" \
  "res/fcu2.png adbc1a80c78c3cee1d5e401322a8b1704fd55c4efd28bf0da84e99db1d86443d" \
  "res/fd_buttons.png 39ad3031a43144f964b52702d5f7a7a655ebe03a3ec346802fd00edcb7b111a4" \
  "res/fd_glare.png 59ae855a3081c286da384d51e8c4f2149a7835df553fa626e76928371ad99489" \
  "res/fd_leather.png 25913dded8ea20d22666d8cc7d814a67281af2d069e7add3e38b857d4f1d271e" \
  "res/fd_main.png 589e911842888a713c20c7fdd308563ecbaec1dbfa864f6123164bf164546751" \
  "res/fd_other.png be5dfc11937d7eaee089f349cac7c510f90c35e83ae169a64a857113b54c630e" \
  "res/glare_sw.png 1afc7c7682414b92deb42f67a129fae52d898ea3ae560e45f674406a8383b8ea" \
  "res/hud.png 9dd8619408e4d7e83b150a7a6f9e535d67830123210b6f901040c4ffdc04db77" \
  "res/hud_box_grid.png 773cf73a2607a001ba5aaeb9317e51f3b987cf6ed2bc113b9a9cfc5ed9b424cb" \
  "res/iesi.png 273ac887a96618dab70e681cd7a43bfeba62a59e31c3c890aec473a6df45cd72" \
  "res/inop.png f244510d4bfed309c772846094555294b4b3cb476abc4262cd9bd46f0bf2b8f4"
for f in a320.flightdeck.xml res/fd_complete.ac; do
  cmp -s "$A320_RAW/FlightDeck/$f" "$A320_DIR/$(basename "$f")" || cp -f "$A320_RAW/FlightDeck/$f" "$A320_DIR/$(basename "$f")"
done
for t in $(grep -h "^texture" "$A320_RAW/FlightDeck/res/fd_complete.ac" | sort -u | cut -d'"' -f2); do
  src="$A320_RAW/FlightDeck/res/$t"; out="$A320_DIR/$t"
  if [ ! -f "$out" ] || [ "$src" -nt "$out" ]; then
    # sips -Z also enlarges, so only the sheets wider than 2048 px go through it.
    if [ "$(sips -g pixelWidth "$src" | awk 'END {print $2}')" -gt 2048 ]; then sips -Z 2048 "$src" --out "$out" >/dev/null; else cp -f "$src" "$out"; fi
  fi
done

# CFM56 recordings from the same A320 repository (Sounds/SASA/CFM56B, GPL-2.0): outside and
# flight-deck sets. The app gets mono 16-bit copies named ext-* and ckpt-*.
fetch_set "https://raw.githubusercontent.com/legoboyvdlp/A320-family/$A320_COMMIT/Sounds/SASA/CFM56B" "$A320_RAW/sounds" \
  "cockpit/cfm-buzz.wav 3916c4cb562a1f79965e5f3280170390dc9640ebfd1a992bafdac57ec2e43a82" \
  "cockpit/cfm-comb.wav 1356a4a94cb152347e1a0f0029535f3ca90452e3f441b963b3bc0e45cefcca7c" \
  "cockpit/cfm-hum.wav ecb41f5384713c1f699e699a95917d3e5bec349b36c828b5614360323acdf560" \
  "cockpit/cfm-idle.wav 0db5e1ac4634ce044adb1cd5129f5eed636db3d348182d563d180930d5ff7595" \
  "cockpit/cfm-lowspool.wav f8289c7f87a81d1253f769bc921bdeb96def38320359673980d93ec73c38a259" \
  "cockpit/cfm-reverse.wav 91e020aedc6023a38f78b01e2001eaae85726c23143b815235110653b5db6d84" \
  "cockpit/cfm-spool.wav 2e2aeb5da9b38f458ab65752fd3de1979b60f46449c101fb7ffbb1806648f826" \
  "external/cfm-buzz.wav 64b7cc3b1fe904865a02a9f5fe4f9cc05dc9e21dc480607be81c5d25b369e5dc" \
  "external/cfm-idle.wav c095fa853fd76bf45a6aa1726faf978870d337abff68480c77a851a89f3e9427" \
  "external/cfm-idleClose.wav d55f3f8868ba3ae2a8eba32d18e70d59df4ebe897444614d3a61fa1e8afb1707" \
  "external/cfm-lowspool.wav 9eaa736a3b9fa0d910cac1b7114cab257ed11c1560ed94ddf4e0d72aa5dfa18a" \
  "external/cfm-reverse.wav 0d3228728f5d3f638575568ef4745bb0d32e816905cbf5d03a693365ce8fb1ed" \
  "external/cfm-rumble.wav 2859ed2b8a9efc023f7c2b6c088fe22d549d81e02b501985ffe8ad4df20ccc87" \
  "external/cfm-spool.wav 5907c059ff9eecae2567c8d9fa87cb3b9e956f393b6fcb44d06aeb4f519e7124"
SOUND_DIR="$ROOT/Data/Bundle/Sounds/CFM56"
mkdir -p "$SOUND_DIR"
for f in "$A320_RAW"/sounds/external/*.wav "$A320_RAW"/sounds/cockpit/*.wav; do
  case "$f" in */external/*) out="$SOUND_DIR/ext-$(basename "$f" .wav).caf" ;; *) out="$SOUND_DIR/ckpt-$(basename "$f" .wav).caf" ;; esac
  if [ ! -f "$out" ] || [ "$f" -nt "$out" ]; then afconvert -f caff -d LEI16@32000 -c 1 "$f" "$out"; fi
done
mkdir -p "$A320_DIR"
for f in A320-216.ac CFM56.ac fuselage.xml a320.cfm.xml; do
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
