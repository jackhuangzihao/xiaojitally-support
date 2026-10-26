"""Check an app bundle. Add --production --dsym /path/to/app.dSYM after export."""
import argparse
import json
import plistlib
import re
import subprocess
from pathlib import Path
from urllib.parse import urlparse

if not __debug__:
    raise RuntimeError('Run without Python optimisation; release assertions must remain enabled')

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app', type=Path)
parser.add_argument('--production', action='store_true')
parser.add_argument('--dsym', type=Path)
parser.add_argument('--build', help='Expected CFBundleVersion')
args = parser.parse_args()
if args.production and not args.dsym:
    parser.error('--production requires the matching --dsym for crash symbolication')
app = args.app.resolve()
mac = (app / 'Contents').is_dir()
manifest = app / ('Contents/Resources/PrivacyInfo.xcprivacy' if mac else 'PrivacyInfo.xcprivacy')
info = plistlib.loads((app / ('Contents/Info.plist' if mac else 'Info.plist')).read_bytes())
if args.build:
    assert info['CFBundleVersion'] == args.build, 'Unexpected build number'
assert info['ITSAppUsesNonExemptEncryption'] is False
for key in ('TallyPrivacyPolicyURL', 'TallyPrivacyPolicyEnglishURL'):
    policy = urlparse(info.get(key, ''))
    assert policy.scheme == 'https' and policy.hostname and not policy.username and not policy.password, f'Missing or invalid public privacy URL: {key}'
data = plistlib.loads(manifest.read_bytes())
assert data['NSPrivacyTracking'] is False
assert data['NSPrivacyCollectedDataTypes'] == []
reasons = {item['NSPrivacyAccessedAPIType']: set(item['NSPrivacyAccessedAPITypeReasons'])
           for item in data['NSPrivacyAccessedAPITypes']}
assert reasons['NSPrivacyAccessedAPICategoryUserDefaults'] == {'CA92.1'}
assert reasons['NSPrivacyAccessedAPICategorySystemBootTime'] == {'35F9.1'}
for path in app.rglob('extract.actionsdata'):
    metadata = json.loads(path.read_text())
    assert not metadata.get('actions'), f'Unexpected registered actions: {path}'
    assert not metadata.get('entities'), f'Unexpected registered entities: {path}'
    assert not metadata.get('queries'), f'Unexpected registered queries: {path}'
assert not list(app.rglob('*.storekit')), 'Local StoreKit configuration must not ship in the app'
assert not list(app.rglob('JianshiWidget.appex')), 'Disabled widget extension remains embedded'
if args.production:
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    signature = subprocess.run(['codesign', '-dv', '--verbose=4', str(app)], check=True, capture_output=True, text=True).stderr
    assert 'Signature=adhoc' not in signature, 'Ad-hoc signature cannot be released'
    assert 'TeamIdentifier=JY659LHUCS' in signature, 'Wrong certificate team'
    assert re.search(r'^Authority=(Apple Distribution:|3rd Party Mac Developer Application:|iPhone Distribution:)', signature, re.MULTILINE), 'App Store distribution certificate missing'
    assert 'Authority=Apple Root CA' in signature, 'Apple certificate chain missing'
    result = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(app)], check=True, capture_output=True)
    entitlements = plistlib.loads(result.stdout)
    assert info['CFBundleIdentifier'] == 'local.jianshi.personal', 'Test identity cannot be released'
    assert entitlements.get('com.apple.developer.team-identifier') == 'JY659LHUCS', 'Wrong signing team'
    assert entitlements.get('com.apple.developer.icloud-container-environment') == 'Production', 'CloudKit is not Production'
    assert entitlements.get('com.apple.developer.icloud-container-identifiers') == ['iCloud.local.jianshi.personal'], 'Wrong CloudKit container'
    assert 'CloudKit' in entitlements.get('com.apple.developer.icloud-services', []), 'Missing CloudKit entitlement'
    assert not entitlements.get('get-task-allow') and not entitlements.get('com.apple.security.get-task-allow'), 'Debug entitlement in release'
    if mac:
        assert entitlements.get('com.apple.security.app-sandbox') is True, 'Mac App Store sandbox missing'
if args.dsym:
    executable = app / ('Contents/MacOS' if mac else '') / info['CFBundleExecutable']
    def uuids(path):
        text = subprocess.check_output(['xcrun', 'dwarfdump', '--uuid', str(path)], text=True)
        values = set(re.findall(r'UUID: ([A-Fa-f0-9-]+) \(([^)]+)\)', text))
        assert values, f'No debug UUIDs: {path}'
        return values
    assert uuids(executable) == uuids(args.dsym), 'dSYM does not match app architectures/UUIDs'
print('PASS: privacy, encryption and widget checks' +
      ('; Production signature, CloudKit and matching crash symbols' if args.production else '; unsigned/local scope'))
