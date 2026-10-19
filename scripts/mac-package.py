"""Validate transferred source and package unsigned iPhone builds on macOS."""
import hashlib
import json
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile
import zipfile


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


run = pathlib.Path(sys.argv[2]).resolve()
source = json.loads((run / 'source-manifest.json').read_text(encoding='utf-8'))
out = run / 'output'
if sys.argv[1] == 'verify':
    for record in source['files']:
        path = (run / 'src' / record['path']).resolve()
        if not path.is_relative_to(run / 'src') or digest(path) != record['sha256']:
            raise RuntimeError(f"Source mismatch: {record['path']}")
    shutil.copyfile(run / 'source-manifest.json', out / 'source-manifest.json')
    print(f"Verified {len(source['files'])} source files against Windows SHA-256 manifest")
elif sys.argv[1] == 'package':
    app = run / 'DerivedData-device/Build/Products/Release-iphoneos/audiolife.app'
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    subprocess.run(['xcrun', 'lipo', str(app / info['CFBundleExecutable']), '-verify_arch', 'arm64'], check=True)
    assert (app / 'Assets.car').is_file(), 'Missing compiled asset catalog'
    assert (app / 'PlugIns/AudioLifeWidgets.appex/Info.plist').is_file(), 'Missing Widget extension'
    assert info['CFBundleIdentifier'] == 'com.liuxiaogang.audiolife'
    stage = pathlib.Path(tempfile.mkdtemp(prefix='package-', dir=run))
    target = stage / 'Payload/AudioLife.app'
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(app, target)
    # Simulator/ad-hoc build signatures are not distribution signatures.
    for root in [target] + list(target.rglob('*.appex')):
        subprocess.run(['codesign', '--remove-signature', str(root)], check=True)
        signature = root / '_CodeSignature'
        if signature.exists():
            shutil.rmtree(signature)
        assert not (root / 'embedded.mobileprovision').exists()
    live_activities = info.get('NSSupportsLiveActivities', False)
    label = '-liveactivity' if live_activities else ''
    base = f"AudioLife-{info['CFBundleShortVersionString']}-{info['CFBundleVersion']}-{source['commit'][:7]}-{source['run_id']}-vm{label}"
    artifacts = []
    # A Live Activity build requires its extension. Do not produce a misleading
    # nowidget package with the Live Activity-dependent recording code enabled.
    for variant in (['with-widget'] if live_activities else ['with-widget', 'nowidget']):
        if variant == 'nowidget':
            shutil.rmtree(target / 'PlugIns')
        ipa = out / f'{base}-{variant}-unsigned.ipa'
        # Revalidation must replace the archive, not append to an older ZIP.
        if ipa.exists():
            ipa.unlink()
        subprocess.run(['/usr/bin/zip', '-qry', str(ipa), 'Payload'], cwd=stage, check=True)
        with zipfile.ZipFile(ipa) as package:
            assert package.testzip() is None
            names = package.namelist()
            assert ('Payload/AudioLife.app/PlugIns/AudioLifeWidgets.appex/Info.plist' in names) == (variant == 'with-widget')
            assert not any('_CodeSignature/' in n or n.endswith('embedded.mobileprovision') for n in names)
            assert 'Payload/AudioLife.app/Assets.car' in names
        sha = digest(ipa)
        ipa.with_suffix('.ipa.sha256').write_text(f'{sha}  {ipa.name}\n', encoding='utf-8')
        artifacts.append({'file': ipa.name, 'variant': variant, 'sha256': sha, 'bytes': ipa.stat().st_size})
    report = {
        'source_commit': source['commit'], 'source_git_status': source['git_status'],
        'source_files_verified': len(source['files']), 'run_id': source['run_id'],
        'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
        'bundle_identifier': info['CFBundleIdentifier'], 'minimum_ios': info['MinimumOSVersion'],
        'architecture': 'arm64', 'signed_for_device': False,
        'live_activities': live_activities,
        'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
        'iphoneos_sdk': subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-version'], text=True).strip(),
        'validation': {'source_hashes': 'passed', 'analyze': 'passed', 'release_build': 'passed',
                       'simulator_launch': 'skipped' if sys.argv[3] == '1' else 'passed',
                       'unit_tests': 'not configured: project has no test target',
                       'physical_device': 'not tested'},
        'artifacts': artifacts,
    }
    (out / 'build-info.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    shutil.rmtree(stage)
    print(json.dumps(report, ensure_ascii=False, indent=2))
else:
    raise ValueError('Expected verify or package')
