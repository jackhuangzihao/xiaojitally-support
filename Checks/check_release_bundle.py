"""Run after building: python3 Checks/check_release_bundle.py /path/to/Jianshi.app"""
import json
import plistlib
import sys
from pathlib import Path

app = Path(sys.argv[1])
mac = (app / 'Contents').is_dir()
manifest = app / ('Contents/Resources/PrivacyInfo.xcprivacy' if mac else 'PrivacyInfo.xcprivacy')
info = plistlib.loads((app / ('Contents/Info.plist' if mac else 'Info.plist')).read_bytes())
assert info['ITSAppUsesNonExemptEncryption'] is False
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
assert not list(app.rglob('JianshiWidget.appex')), 'Disabled widget extension remains embedded'
print('PASS: privacy manifest, encryption declaration and disabled widget registrations')
