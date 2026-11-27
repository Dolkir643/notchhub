import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[1] / "Scripts"


def write_plist(path, version, build):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "name.notchhub.NotchHub",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": build,
    }))


class InstallVersionTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.app = self.root / "Applications" / "NotchHub.app"
        self.installed_plist = self.app / "Contents" / "Info.plist"
        self.candidate = self.root / "Resources" / "Info.plist"
        write_plist(self.installed_plist, "1.3", "5")

    def check(self):
        return subprocess.run(["/usr/bin/python3", SCRIPTS / "check-install-version.py",
                               self.candidate, self.app], capture_output=True, text=True)

    def test_compares_versions_and_builds_numerically(self):
        for version, build, allowed in [
            ("1.2", "999", False), ("1.3.0", "4", False), ("1.3.0", "5.0", True),
            ("1.3", "10", True), ("1.10", "1", True), ("1.3.1", "1", True),
            ("", "5", False), ("1.4", "?", False),
        ]:
            with self.subTest(version=version, build=build):
                write_plist(self.candidate, version, build)
                self.assertEqual(self.check().returncode == 0, allowed)

    def test_missing_installation_is_distinct_from_broken_bundle(self):
        write_plist(self.candidate, "1.3.1", "6")
        self.installed_plist.unlink()
        self.assertNotEqual(self.check().returncode, 0)
        self.installed_plist.write_bytes(b"broken")
        self.assertNotEqual(self.check().returncode, 0)
        shutil.rmtree(self.app)
        self.assertEqual(self.check().returncode, 0)

    def test_both_scripts_reject_a_downgrade_before_build_or_shutdown(self):
        scripts = self.root / "Scripts"
        scripts.mkdir()
        shutil.copy(SCRIPTS / "check-install-version.py", scripts)
        write_plist(self.candidate, "1.2", "3")
        # Redirect the installed path and intercept side effects inside the fixture.
        marker = self.root / "unexpected-call"
        for command in ["build.sh", "pkill", "open"]:
            stub = scripts / command
            stub.write_text(f'#!/bin/bash\ntouch "{marker}"\nexit 1\n')
            stub.chmod(0o755)
        for name in ["install.sh", "run.sh"]:
            with self.subTest(name=name):
                script = scripts / name
                script.write_text((SCRIPTS / name).read_text().replace(
                    "/Applications", str(self.app.parent)))
                result = subprocess.run(["/bin/bash", script], capture_output=True, text=True,
                                        env={**os.environ, "PATH": f"{scripts}:{os.environ['PATH']}"})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("1.2 (3)", result.stderr)
                self.assertFalse(marker.exists())
                self.assertTrue(self.installed_plist.exists())


if __name__ == "__main__":
    unittest.main()
