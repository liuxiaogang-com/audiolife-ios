#!/bin/bash
set -euo pipefail
run="$1"
fixture="${2:-}"
device="$(cat "$run/output/simulator-udid.txt")"
app="$run/DerivedData-simulator/Build/Products/Debug-iphonesimulator/audiolife.app"
out="$run/output"
# Only reset the simulator created by this run, never a phone or another simulator.
python3 - "$device" "$(basename "$run")" <<'PY'
import json,subprocess,sys
devices=json.loads(subprocess.check_output(['xcrun','simctl','list','devices','-j']))['devices']
d=next(d for group in devices.values() for d in group if d['udid']==sys.argv[1])
assert d['name']=='AudioLife validation '+sys.argv[2], d['name']
PY
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b
xcrun simctl uninstall "$device" com.liuxiaogang.audiolife
xcrun simctl install "$device" "$app"
container="$(xcrun simctl get_app_container "$device" com.liuxiaogang.audiolife data)"
mkdir -p "$container/Library/Application Support" "$container/Documents"
if [[ -n "$fixture" ]]; then
  cp "$fixture"/default.store* "$container/Library/Application Support/"
  cp "$fixture/migration-expectations.json" "$container/Documents/"
fi
SIMCTL_CHILD_AUDIOLIFE_VALIDATE=1 xcrun simctl launch "$device" com.liuxiaogang.audiolife
for ((i=0;i<180;i++)); do
  [[ ! -f "$container/Documents/library-validation.json" ]] || break
  sleep 1
done
test -f "$container/Documents/library-validation.json"
cp "$container/Documents/library-validation.json" "$out/library-validation.json"
python3 - "$out/library-validation.json" "$out" <<'PY'
import json,pathlib,shutil,sys,zipfile,hashlib
report=json.loads(pathlib.Path(sys.argv[1]).read_text())
print(json.dumps(report,ensure_ascii=False,indent=2))
assert report['status']=='passed',report
source=pathlib.Path(report['export_zip'])
target=pathlib.Path(sys.argv[2])/'library-validation-export.zip'
shutil.copy2(source,target)
with zipfile.ZipFile(target) as z:
 assert z.testzip() is None
 manifest_name=next(n for n in z.namelist() if n.endswith('manifest.json'))
 manifest=json.loads(z.read(manifest_name))
 prefix=manifest_name[:-len('manifest.json')]
 assert manifest['text']=='文字笔记校验'
 for a in manifest['attachments']:
  assert hashlib.sha256(z.read(prefix+a['file'])).hexdigest()==a['sha256']
print('Export archive content and original attachment hashes verified')
info_path=pathlib.Path(sys.argv[2])/'build-info.json'
info=json.loads(info_path.read_text())
info['validation']['library_runtime_tests']='passed'
info['validation']['library_runtime_checks']=len(report['checks'])
info['validation']['legacy_migration_counts']=report.get('migration_counts')
info_path.write_text(json.dumps(info,ensure_ascii=False,indent=2)+'\n')
PY
# Remove the private migration fixture before capturing product screenshots.
xcrun simctl terminate "$device" com.liuxiaogang.audiolife
xcrun simctl uninstall "$device" com.liuxiaogang.audiolife
xcrun simctl install "$device" "$app"
for screen in notes ai diary composer; do
  SIMCTL_CHILD_AUDIOLIFE_SCREEN="$screen" xcrun simctl launch --terminate-running-process "$device" com.liuxiaogang.audiolife
  sleep 15
  xcrun simctl io "$device" screenshot "$out/library-$screen.png"
done
xcrun simctl shutdown "$device"
tar -czf "$run/results-with-tests.tar.gz" -C "$run" output
