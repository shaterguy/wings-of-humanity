"""The export preset and visible project version must match the Android pin."""
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class AndroidVersionIdentityTests(unittest.TestCase):
    def test_candidate_uses_unused_dev20_and_increased_code(self):
        pin = json.loads((ROOT / 'tools/build/toolchain.json').read_text())['android']
        self.assertEqual(pin['version_name'], '0.1.0-dev20-candidate-native-pursuit-r6d')
        self.assertEqual(pin['version_code'], 20)
        self.assertGreater(pin['version_code'], 19)  # Preserve the delivered dev19 update baseline.

    def test_project_and_export_preset_match_pin(self):
        pin = json.loads((ROOT / 'tools/build/toolchain.json').read_text())['android']
        project = (ROOT / 'project.godot').read_text()
        plugin = (ROOT / 'addons/chapter_export/plugin.gd').read_text()
        self.assertEqual(re.findall(r'^config/version="([^"]+)"$', project, re.M), [pin['version_name']])
        self.assertEqual(re.findall(r'preset\.set\("version/name","([^"]+)"\)', plugin), [pin['version_name']])
        self.assertEqual(re.findall(r'preset\.set\("version/code",(\d+)\)', plugin), [str(pin['version_code'])])

    def test_new_package_is_separate_from_preserved_historical_signer(self):
        pin = json.loads((ROOT / 'tools/build/toolchain.json').read_text())['android']
        signer = json.loads((ROOT / 'docs/build/dev-signer-public.json').read_text())
        plugin = (ROOT / 'addons/chapter_export/plugin.gd').read_text()
        self.assertEqual(pin['package'], 'com.shaterguy.wingsofhumanity.dev')
        self.assertEqual(signer['package'], 'com.shaterguy.shiganshina.dev')
        self.assertNotEqual(signer['package'], pin['package'])
        self.assertEqual(re.findall(r'preset\.set\("package/unique_name","([^"]+)"\)', plugin), [pin['package']])
        self.assertEqual(signer['certificate_sha256'], '4256200e2c63dbfec3d0e9370ecca4b611ee11c65e1e2edad88003ea858c174c')


if __name__ == '__main__':
    unittest.main()
