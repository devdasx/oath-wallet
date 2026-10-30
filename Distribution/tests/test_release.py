import importlib.util
import base64
from datetime import datetime
import os
import plistlib
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

MODULE = Path(__file__).resolve().parents[1] / "verify_release.py"
spec = importlib.util.spec_from_file_location("verify_release", MODULE)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
signing_spec = importlib.util.spec_from_file_location("prepare_signing", MODULE.parent / "prepare_signing.py")
signing = importlib.util.module_from_spec(signing_spec)
signing_spec.loader.exec_module(signing)


class ReleaseIdentityTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.project = self.root / "OathAtmosphere.xcodeproj/project.pbxproj"
        self.project.parent.mkdir()
        self.project.write_text("MARKETING_VERSION = 4.1.3;\nCURRENT_PROJECT_VERSION = 86;\n" * 2)
        self.git("init", "-q")
        self.git("config", "user.name", "Synthetic release test")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("add", ".")
        self.git("commit", "-qm", "Synthetic release")
        self.git("tag", "v4.1.3")

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.root), *args], text=True).strip()

    def verify(self, tag="v4.1.3", version="4.1.3", build="86"):
        return release.inspect_release(self.root, tag, version, build)

    def test_exact_source_version_and_build(self):
        self.assertEqual(self.verify()["source_commit"], self.git("rev-parse", "HEAD"))

    def test_build_specific_tag_preserves_previous_release(self):
        self.git("tag", "v4.1.3-build86")
        self.assertEqual(self.verify(tag="v4.1.3-build86")["build"], "86")

    def test_wrong_build(self):
        with self.assertRaises(ValueError): self.verify(build="87")

    def test_inconsistent_configurations(self):
        self.project.write_text(self.project.read_text().replace("86", "87", 1))
        with self.assertRaises(ValueError): self.verify()

    def test_modified_tagged_source(self):
        self.project.write_text(self.project.read_text() + "// modification\n")
        with self.assertRaisesRegex(ValueError, "modifications"): self.verify()

    def test_new_commit_does_not_reuse_old_tag(self):
        self.project.write_text(self.project.read_text() + "// new commit\n")
        self.git("commit", "-qam", "Changed")
        with self.assertRaisesRegex(ValueError, "requested tag"): self.verify()

    def test_untrusted_inputs_rejected_before_git(self):
        for version, build in [("4.1.3;command", "86"), ("../main", "86"), ("4.1.3", "0"), ("4.1.3", "86\ncommand")]:
            with self.subTest(version=version, build=build), self.assertRaises(ValueError):
                self.verify(tag="v" + version, version=version, build=build)

    def test_tag_must_match_version(self):
        with self.assertRaises(ValueError): self.verify(tag="main")


class SigningPreflightTests(unittest.TestCase):
    def test_profile_must_support_manual_app_store_signing(self):
        def encoded(data): return base64.b64encode(data).decode()
        env = {name: encoded(b"synthetic") for name in ["ASC_API_KEY_P8_BASE64", "APPLE_DISTRIBUTION_P12_BASE64", "APPLE_PROVISIONING_PROFILE_BASE64"]}
        env.update({name: "synthetic" for name in ["ASC_KEY_ID", "ASC_ISSUER_ID", "APPLE_DISTRIBUTION_PASSWORD"]})
        env["OATH_PROVIDER_CONFIGURATION_BASE64"] = encoded(plistlib.dumps({"WalletConnectProjectID": "synthetic"}))
        profile = {"Name": "Synthetic", "UUID": "synthetic-profile", "ExpirationDate": datetime(2050, 1, 1),
                   "Entitlements": {"application-identifier": "C5T44SZNQX.com.aperture.wallet"}}
        for managed in [True, False]:
            with self.subTest(managed=managed), tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, env):
                root = Path(folder)
                with patch.object(signing.subprocess, "check_output", return_value=plistlib.dumps({**profile, "IsXcodeManaged": managed})):
                    if managed:
                        with self.assertRaisesRegex(ValueError, "manually managed"):
                            signing.install(root / "source", root / "credentials")
                        self.assertFalse((root / "source").exists())
                    else:
                        signing.install(root / "source", root / "credentials")
                        self.assertTrue((root / "source/OathApp/Private/TokenRPC.plist").exists())

    def test_missing_credentials_fail_without_creating_files(self):
        script = MODULE.parent / "prepare_signing.py"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            env = {k: v for k, v in os.environ.items() if not k.startswith(("ASC_", "APPLE_", "OATH_PROVIDER_"))}
            result = subprocess.run(["python3", str(script), "--root", str(root), "--temporary", str(root / "credentials")], env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Missing deployment secrets", result.stderr)
            self.assertFalse((root / "credentials").exists())


class UploadOnlyLaneTests(unittest.TestCase):
    def test_release_lane_without_network_or_signing(self):
        fixture = Path(__file__).with_name("upload_lane_fixture.rb")
        lane = MODULE.parent / "ios/fastlane/Fastfile"
        for mode in ["success", "duplicate", "upload_failure", "build_failure", "verification_missing", "processing_invalid"]:
            with self.subTest(mode=mode):
                result = subprocess.run(["ruby", str(fixture), str(lane), mode], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
