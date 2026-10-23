"""Final-archive replacement and recovery; never touch installed apps."""
import importlib.util
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("release", Path(__file__).parents[1] / "Scripts/release.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class ReleaseArchivesTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.archives = self.root / "dist/releases"
        self.baseline = self.archives / "1.1.0"
        self.baseline.mkdir(parents=True)
        self.write_manifest(self.baseline, 4)
        self.patch = patch.multiple(release, ROOT=self.root, ARCHIVES=self.archives)
        self.patch.start()
        self.addCleanup(self.patch.stop)

    def write_manifest(self, directory, build, version="1.1.0"):
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "manifest.json").write_text(json.dumps({"version": version, "build": str(build)}))

    def write_source_info(self, build):
        resources = self.root / "Resources"
        resources.mkdir(exist_ok=True)
        (resources / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleShortVersionString": "1.1.0", "CFBundleVersion": str(build)}))

    def test_publish_replaces_same_version_and_removes_previous_branch(self):
        self.write_manifest(self.baseline / "build-5", 5)
        output = self.root / "stage/archive"
        self.write_manifest(output, 5)
        release.publish_release(output, self.baseline, replace=True)
        self.assertEqual(json.loads((self.baseline / "manifest.json").read_text())["build"], "5")
        self.assertEqual([p.name for p in self.baseline.iterdir()], ["manifest.json"])
        self.assertFalse((output.parent / "previous-release").exists())

    def test_failed_publish_restores_previous_archive(self):
        output = self.root / "stage/archive"
        self.write_manifest(output, 5)
        rename = Path.rename

        def fail_new_archive(path, target):
            if path == output:
                raise OSError("Simulated publication failure")
            return rename(path, target)

        with patch.object(Path, "rename", new=fail_new_archive):
            with self.assertRaises(OSError):
                release.publish_release(output, self.baseline, replace=True)
        self.assertEqual(json.loads((self.baseline / "manifest.json").read_text())["build"], "4")
        self.assertTrue(output.exists())

    def test_default_archive_cannot_overwrite_existing_version(self):
        self.write_source_info(5)
        with patch.object(release, "run") as run:
            with self.assertRaises(FileExistsError):
                release.archive_release(None, None)
            run.assert_not_called()

    def test_source_snapshot_excludes_local_instructions_credentials_and_cache(self):
        (self.root / "AGENTS.md").write_text("private collaboration instructions")
        (self.root / ".env").write_text("PRIVATE_VALUE=not-for-publication")
        (self.root / "README.md").write_text("public documentation")
        docs = self.root / "Docs"
        docs.mkdir()
        (docs / "DEVELOPMENT.md").write_text("public development guide")
        cache = docs / "__pycache__"
        cache.mkdir()
        (cache / "private.pyc").write_bytes(b"cache")
        windows = self.root / "Windows"
        windows.mkdir()
        (windows / "PetsPet.cs").write_text("Windows source")
        (windows / "PetsPet.exe").write_bytes(b"local build")
        data = windows / "data"
        data.mkdir()
        (data / "settings.json").write_text("local settings")
        screenshots = windows / "验收截图"
        screenshots.mkdir()
        (screenshots / "capture.png").write_bytes(b"local screenshot")
        destination = self.root / "export"
        release.write_source_snapshot(destination)
        self.assertEqual((destination / "README.md").read_text(), "public documentation")
        self.assertTrue((destination / "Docs/DEVELOPMENT.md").is_file())
        self.assertFalse((destination / "AGENTS.md").exists())
        self.assertFalse((destination / ".env").exists())
        self.assertFalse((destination / "dist").exists())
        self.assertFalse((destination / "Docs/__pycache__").exists())
        self.assertEqual((destination / "Windows/PetsPet.cs").read_text(), "Windows source")
        self.assertFalse((destination / "Windows/PetsPet.exe").exists())
        self.assertFalse((destination / "Windows/data").exists())
        self.assertFalse((destination / "Windows/验收截图").exists())

    def test_revision_cannot_reuse_or_decrease_build(self):
        for build in [3, 4]:
            with self.subTest(build=build):
                self.write_source_info(build)
                with patch.object(release, "verify_release", return_value={"build": "4"}), patch.object(release, "run") as run:
                    with self.assertRaises(ValueError):
                        release.archive_release(None, None, revision=True)
                    run.assert_not_called()

    def test_corrupt_archive_is_not_replaced(self):
        self.write_source_info(5)
        before = (self.baseline / "manifest.json").read_bytes()
        with patch.object(release, "verify_release", side_effect=ValueError("Checksum mismatch")), patch.object(release, "run") as run:
            with self.assertRaises(ValueError):
                release.archive_release(None, None, revision=True)
            run.assert_not_called()
        self.assertEqual((self.baseline / "manifest.json").read_bytes(), before)

    def test_install_writes_only_the_primary_app(self):
        # Isolated filesystem and process/command doubles: never use a real app.
        primary = self.root / "dist/PetsPet.app"
        old_resource = primary / "Contents/Resources/removed.txt"
        old_resource.parent.mkdir(parents=True)
        old_resource.write_text("obsolete resource")
        payload = b"isolated release install check"
        manifest = {"package": "PetsPet-1.1.0.zip", "binarySHA256": hashlib.sha256(payload).hexdigest()}

        def command(arguments):
            if arguments[0] != "ditto":
                return
            if "-x" in arguments:
                binary = Path(arguments[-1]) / "PetsPet.app/Contents/MacOS/PetsPet"
                binary.parent.mkdir(parents=True)
                binary.write_bytes(payload)
                resources = binary.parent.parent / "Resources"
                resources.mkdir()
                (resources / "current.txt").write_text("current resource")

        with patch.object(release, "APP", primary), \
                patch.object(release, "verify_release", return_value=manifest), \
                patch.object(release, "run", side_effect=command), \
                patch.object(release.subprocess, "run", return_value=SimpleNamespace(returncode=1, stdout="")), \
                patch("builtins.print"):
            release.install_release("1.1.0")
        self.assertEqual((primary / "Contents/MacOS/PetsPet").read_bytes(), payload)
        self.assertFalse(old_resource.exists())
        self.assertEqual((primary / "Contents/Resources/current.txt").read_text(), "current resource")
        self.assertEqual(list(primary.parent.glob(".petspet-backup-*")), [])
        self.assertFalse((self.root / "dist/Next").exists())

    def test_install_failures_restore_the_complete_previous_app(self):
        primary = self.root / "dist/PetsPet.app"
        binary = primary / "Contents/MacOS/PetsPet"
        resource = primary / "Contents/Resources/previous.txt"
        payload = b"replacement binary"
        rename = Path.rename
        for failure in ["rename", "signature", "checksum"]:
            with self.subTest(failure=failure):
                binary.parent.mkdir(parents=True, exist_ok=True)
                binary.write_bytes(b"previous binary")
                resource.parent.mkdir(parents=True, exist_ok=True)
                resource.write_text("previous resource")
                manifest = {"package": "PetsPet-1.1.0.zip", "binarySHA256": hashlib.sha256(payload if failure != "checksum" else b"wrong checksum").hexdigest()}

                def command(arguments):
                    if arguments[0] == "ditto":
                        staged_binary = Path(arguments[-1]) / "PetsPet.app/Contents/MacOS/PetsPet"
                        staged_binary.parent.mkdir(parents=True)
                        staged_binary.write_bytes(payload)
                    elif arguments[0] == "codesign" and arguments[-1] == primary and failure == "signature":
                        raise subprocess.CalledProcessError(1, arguments)

                def move(path, target):
                    if failure == "rename" and path.name == "PetsPet.app" and path.parent.name.startswith("install-"):
                        raise OSError("Simulated replacement failure")
                    return rename(path, target)

                with patch.object(release, "APP", primary), \
                        patch.object(release, "verify_release", return_value=manifest), \
                        patch.object(release, "run", side_effect=command), \
                        patch.object(release.subprocess, "run", return_value=SimpleNamespace(returncode=1, stdout="")), \
                        patch.object(Path, "rename", new=move):
                    with self.assertRaises((OSError, subprocess.CalledProcessError, ValueError)):
                        release.install_release("1.1.0")
                self.assertEqual(binary.read_bytes(), b"previous binary")
                self.assertEqual(resource.read_text(), "previous resource")
                self.assertEqual(list(primary.parent.glob(".petspet-backup-*")), [])

    def test_failed_rollback_keeps_the_previous_app_for_recovery(self):
        primary = self.root / "dist/PetsPet.app"
        binary = primary / "Contents/MacOS/PetsPet"
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b"previous binary")
        manifest = {"package": "PetsPet-1.1.0.zip"}
        rename = Path.rename

        def command(arguments):
            if arguments[0] == "ditto":
                staged_binary = Path(arguments[-1]) / "PetsPet.app/Contents/MacOS/PetsPet"
                staged_binary.parent.mkdir(parents=True)
                staged_binary.write_bytes(b"replacement binary")

        def move(path, target):
            if target == primary:
                raise OSError("Simulated replacement and rollback failure")
            return rename(path, target)

        with patch.object(release, "APP", primary), \
                patch.object(release, "verify_release", return_value=manifest), \
                patch.object(release, "run", side_effect=command), \
                patch.object(release.subprocess, "run", return_value=SimpleNamespace(returncode=1, stdout="")), \
                patch.object(Path, "rename", new=move):
            with self.assertRaisesRegex(RuntimeError, "recovery files retained"):
                release.install_release("1.1.0")
        backups = list(primary.parent.glob(".petspet-backup-*/PetsPet.app"))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / "Contents/MacOS/PetsPet").read_bytes(), b"previous binary")

    def test_install_refuses_running_app_without_terminating_or_replacing(self):
        primary = self.root / "dist/PetsPet.app"
        binary = primary / "Contents/MacOS/PetsPet"
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b"previous app")
        manifest = {"package": "PetsPet-1.1.0.zip"}
        with patch.object(release, "APP", primary), \
                patch.object(release, "verify_release", return_value=manifest), \
                patch.object(release, "run") as command, \
                patch.object(release.subprocess, "run", return_value=SimpleNamespace(returncode=0, stdout="12345\n")), \
                patch.object(release.os, "kill") as kill:
            with self.assertRaisesRegex(RuntimeError, "Quit Pet's Pet manually"):
                release.install_release("1.1.0")
            kill.assert_not_called()
        self.assertEqual(binary.read_bytes(), b"previous app")
        self.assertFalse(any(args[0][0] == "ditto" and "-x" not in args[0] for args in command.call_args_list))


if __name__ == "__main__":
    unittest.main()
