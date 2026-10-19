#!/bin/bash
set -euo pipefail
run="$1"
skip_simulator="${2:-0}"
cd "$run/src"
out="$run/output"
mkdir -p "$out"
finish() {
  status=$?
  trap - EXIT
  printf '%s\n' "$status" > "$out/exit-code.txt"
  tar -czf "$run/results.tar.gz" -C "$run" output
  exit "$status"
}
trap finish EXIT
echo '=== Toolchain ==='
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-version
python3 scripts/mac-package.py verify "$run"
xcodebuild -list -json -project audiolife.xcodeproj > "$out/project-targets.json"
common=(-project audiolife.xcodeproj -scheme audiolife
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM=
  ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS=NO)
echo '=== Analyze ==='
xcodebuild analyze "${common[@]}" -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath "$run/DerivedData-device" 2>&1 | tee "$out/analyze.log"
echo '=== Release device build ==='
xcodebuild build "${common[@]}" -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$run/DerivedData-device" 2>&1 | tee "$out/release.log"
if [[ "$skip_simulator" == 0 ]]; then
  echo '=== Simulator build and launch ==='
  xcodebuild build "${common[@]}" -configuration Debug -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$run/DerivedData-simulator" 2>&1 | tee "$out/simulator-build.log"
  runtime="$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; r=[r for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")]; print(r[-1]["identifier"])')"
  # Dedicated simulator avoids modifying any existing app or device data.
  if [[ -f "$out/simulator-udid.txt" ]]; then
    device="$(cat "$out/simulator-udid.txt")"
    python3 - "$device" "$(basename "$run")" <<'PY'
import json,subprocess,sys
devices=json.loads(subprocess.check_output(['xcrun','simctl','list','devices','-j']))['devices']
d=next(d for group in devices.values() for d in group if d['udid']==sys.argv[1])
assert d['name']=='AudioLife validation '+sys.argv[2], d['name']
PY
  else
    device="$(xcrun simctl create "AudioLife validation $(basename "$run")" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro "$runtime")"
  fi
  printf '%s\n' "$device" > "$out/simulator-udid.txt"
  xcrun simctl boot "$device"
  xcrun simctl bootstatus "$device" -b
  xcrun simctl install "$device" "$run/DerivedData-simulator/Build/Products/Debug-iphonesimulator/audiolife.app"
  xcrun simctl launch "$device" com.liuxiaogang.audiolife | tee "$out/simulator-launch.txt"
  # A freshly initialized VM simulator can still show the launch screen at 5 s.
  sleep 20
  xcrun simctl spawn "$device" launchctl list > "$out/simulator-processes.txt"
  grep -E '^[[:space:]]*[0-9]+[[:space:]]+.*com[.]liuxiaogang[.]audiolife' "$out/simulator-processes.txt" > "$out/simulator-running.txt"
  xcrun simctl io "$device" screenshot "$out/simulator-home.png"
  xcrun simctl shutdown "$device"
fi
echo '=== Package and verify ==='
python3 scripts/mac-package.py package "$run" "$skip_simulator"
