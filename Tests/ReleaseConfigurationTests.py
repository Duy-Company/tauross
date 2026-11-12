import importlib.util
from pathlib import Path
import plistlib
import unittest

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location('release_check', ROOT / 'Scripts/check-release.py')
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)

class ReleaseConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.info = plistlib.loads((ROOT / 'Config/Info.plist').read_bytes())

    def test_current_configuration_is_valid(self):
        CHECK.validate_info(self.info)

    def test_mismatched_build_version_is_rejected(self):
        self.info['CFBundleVersion'] = '0.0.0'
        with self.assertRaises(AssertionError):
            CHECK.validate_info(self.info)

    def test_downgraded_signature_policies_are_rejected(self):
        for key in ['SURequireSignedFeed', 'SUVerifyUpdateBeforeExtraction']:
            with self.subTest(key=key):
                with self.assertRaises(AssertionError):
                    CHECK.validate_info({**self.info, key: False})

    def test_foreign_update_feed_is_rejected(self):
        self.info['SUFeedURL'] = 'https://example.com/appcast.xml'
        with self.assertRaises(AssertionError):
            CHECK.validate_info(self.info)

    def test_feed_signature_fallback_is_rejected(self):
        self.info['SUSignedFeedFailureExpirationInterval'] = 86400
        with self.assertRaises(AssertionError):
            CHECK.validate_info(self.info)

if __name__ == '__main__':
    unittest.main()
