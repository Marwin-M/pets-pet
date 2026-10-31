#!/usr/bin/env python3
"""Versioned local releases. Build/archive first; install is a separate action."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import struct
import subprocess
import tempfile
from datetime import datetime, timezone
import zipfile

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "dist/PetsPet.app"
ARCHIVES = ROOT / "dist/releases"
BUNDLE_ID = "com.marwin.petspet"


def run(arguments, **kwargs):
    return subprocess.run([str(value) for value in arguments], check=True, **kwargs)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def executable_sections_digest(path):
    """Hash initialized Mach-O sections, excluding the replaceable signature."""
    data = path.read_bytes()
    if struct.unpack_from("<I", data)[0] != 0xFEEDFACF:
        raise ValueError("Expected a thin 64-bit macOS executable")
    count = struct.unpack_from("<I", data, 16)[0]
    offset = 32
    checksum = hashlib.sha256()
    for _ in range(count):
        command, size = struct.unpack_from("<II", data, offset)
        if command == 0x19:  # LC_SEGMENT_64
            sections = struct.unpack_from("<I", data, offset + 64)[0]
            for index in range(sections):
                section = offset + 72 + index * 80
                length = struct.unpack_from("<Q", data, section + 40)[0]
                location = struct.unpack_from("<I", data, section + 48)[0]
                kind = struct.unpack_from("<I", data, section + 64)[0] & 0xFF
                if kind in (1, 12, 18):  # zero-filled sections have no file bytes
                    continue
                if location + length > len(data):
                    raise ValueError("Invalid Mach-O section")
                checksum.update(data[section:section + 32])
                checksum.update(struct.pack("<Q", length))
                checksum.update(data[location:location + length])
        offset += size
    return checksum.hexdigest()


def validate_version(version):
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("Version must be major.minor.patch")
    return version


def verify_release(directory, version):
    manifest = json.loads((directory / "manifest.json").read_text())
    if manifest["version"] != version or manifest["bundleIdentifier"] != BUNDLE_ID:
        raise ValueError("Release identity does not match")
    for name, checksum in manifest["artifacts"].items():
        if Path(name).name != name or digest(directory / name) != checksum:
            raise ValueError("Artifact checksum mismatch: " + name)
    with zipfile.ZipFile(directory / manifest["package"]) as archive:
        for name in archive.namelist():
            path = PurePosixPath(name)
            if path.is_absolute() or ".." in path.parts:
                raise ValueError("Unsafe archive member")
        if archive.testzip() is not None:
            raise ValueError("Damaged app archive")
        info = plistlib.loads(archive.read("PetsPet.app/Contents/Info.plist"))
        if (info["CFBundleShortVersionString"] != version
                or info["CFBundleVersion"] != manifest["build"]
                or info["CFBundleIdentifier"] != BUNDLE_ID):
            raise ValueError("Archived bundle metadata does not match")
        binary = archive.read("PetsPet.app/Contents/MacOS/PetsPet")
        if hashlib.sha256(binary).hexdigest() != manifest["binarySHA256"]:
            raise ValueError("Archived executable does not match")
    if manifest["sourceAvailable"]:
        with zipfile.ZipFile(directory / manifest["sourcePackage"]) as archive:
            if archive.testzip() is not None:
                raise ValueError("Damaged source archive")
            info = plistlib.loads(archive.read("PetsPet-source/Resources/Info.plist"))
            if (info["CFBundleShortVersionString"] != version
                    or info["CFBundleVersion"] != manifest["build"]):
                raise ValueError("Source snapshot version/build does not match")
    return manifest


def publish_release(output, destination, replace=False):
    """Keep one final archive per version; restore the old one if publishing fails."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    backup = output.parent / "previous-release"
    if destination.exists():
        if not replace:
            raise FileExistsError("Release already exists: " + str(destination))
        destination.rename(backup)
    try:
        output.rename(destination)
    except BaseException:
        if backup.exists():
            backup.rename(destination)
        raise
    if backup.exists():
        shutil.rmtree(backup)


def write_source_snapshot(destination):
    """Export project files without local collaboration or account data."""
    destination.mkdir()
    for name in ["Package.swift", "README.md", "README.en.md", ".gitignore", ".github", "Docs",
                 "Sources", "Tests", "Scripts", "Tools", "Resources", "Previews", "Releases", "Windows"]:
        item = ROOT / name
        if item.is_dir():
            ignored = ["__pycache__", ".DS_Store"]
            if name == "Windows":
                ignored += ["PetsPet.exe", "data", "验收截图"]
            shutil.copytree(item, destination / name,
                            ignore=shutil.ignore_patterns(*ignored))
        elif item.is_file():
            shutil.copy2(item, destination / name)


def archive_release(existing_version, preview, revision=False):
    origin = None
    info_path = APP / "Contents/Info.plist" if existing_version else ROOT / "Resources/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    version = validate_version(existing_version or info["CFBundleShortVersionString"])
    destination = ARCHIVES / version
    if revision:
        previous = verify_release(destination, version)
        build = int(info["CFBundleVersion"])
        if build <= int(previous["build"]):
            raise ValueError("A revision requires an existing version and a higher build number")
    elif destination.exists():
        raise FileExistsError("Release already exists; use --revision only for an approved final update: " + str(destination))
    notes = ROOT / "Releases" / (version + ".md")
    if not notes.is_file():
        raise FileNotFoundError("Write release notes first: " + str(notes))
    (ROOT / ".build").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="release-", dir=ROOT / ".build") as temporary:
        stage = Path(temporary)
        staged_app = stage / "PetsPet.app"
        if existing_version:
            run(["codesign", "--verify", "--strict", APP])
            original_hash = digest(APP / "Contents/MacOS/PetsPet")
            original_sections = executable_sections_digest(APP / "Contents/MacOS/PetsPet")
            origin = {"version": info["CFBundleShortVersionString"],
                      "build": info["CFBundleVersion"], "binarySHA256": original_hash,
                      "executableSectionsSHA256": original_sections}
            run(["ditto", APP, staged_app])
            info["CFBundleShortVersionString"] = version
            info["CFBundleVersion"] = str(int(info["CFBundleVersion"]) + 1)
            (staged_app / "Contents/Info.plist").write_bytes(plistlib.dumps(info, sort_keys=False))
            run(["codesign", "--force", "--sign", "-", "--identifier", BUNDLE_ID, staged_app])
            if executable_sections_digest(staged_app / "Contents/MacOS/PetsPet") != original_sections:
                raise ValueError("Relabeling changed executable code or initialized data")
        else:
            environment = dict(os.environ, PETSPET_BUILD_DEST=str(staged_app))
            run(["zsh", "Scripts/build.sh"], cwd=ROOT, env=environment)
        run(["codesign", "--verify", "--strict", staged_app])
        output = stage / "archive"
        output.mkdir()
        stem = "PetsPet-" + version
        package = stem + ".zip"
        run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", staged_app, output / package])
        shutil.copy2(notes, output / "release-notes.md")
        if preview:
            shutil.copy2(Path(preview), output / "preview.png")
        elif not existing_version:
            shutil.copy2(ROOT / "Previews/Assets/current.png", output / "preview.png")
        source_package = None
        if not existing_version:
            source = stage / "PetsPet-source"
            write_source_snapshot(source)
            source_package = stem + "-source.zip"
            run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", source, output / source_package])
        manifest = {"version": version, "build": info["CFBundleVersion"], "bundleIdentifier": BUNDLE_ID,
                    "createdAt": datetime.now(timezone.utc).isoformat(), "package": package,
                    "binarySHA256": digest(staged_app / "Contents/MacOS/PetsPet"),
                    "sourceAvailable": source_package is not None, "sourcePackage": source_package,
                    "origin": origin,
                    "previewKind": "historical screenshot" if existing_version else "native review sample",
                    "artifacts": {path.name: digest(path) for path in sorted(output.iterdir())}}
        (output / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
        checksums = "".join(digest(path) + "  " + path.name + "\n" for path in sorted(output.iterdir()))
        (output / "SHA256SUMS.txt").write_text(checksums)
        verify_release(output, version)
        publish_release(output, destination, replace=revision)
    print("ARCHIVED " + str(destination))


def install_release(version):
    version = validate_version(version)
    directory = ARCHIVES / version
    manifest = verify_release(directory, version)
    # Stage beside the destination so complete bundles can be renamed without
    # merging resources or copying across filesystems during replacement.
    APP.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="install-", dir=APP.parent) as temporary:
        stage = Path(temporary)
        run(["ditto", "-x", "-k", directory / manifest["package"], stage])
        staged_app = stage / "PetsPet.app"
        run(["codesign", "--verify", "--strict", staged_app])
        peers = set()
        for app in [APP, ROOT / "dist/Next/PetsPet.app"]:
            pattern = "^" + re.escape(str(app / "Contents/MacOS/PetsPet")) + "($| )"
            result = subprocess.run(["pgrep", "-f", pattern], text=True, capture_output=True)
            if result.returncode not in (0, 1):
                raise RuntimeError("Cannot check running Pet's Pet processes")
            peers.update(int(value) for value in result.stdout.split())
        if peers:
            raise RuntimeError("Quit Pet's Pet manually before installing; the app bundle was not replaced")
        # Keep the backup outside the automatically cleaned staging directory:
        # even a failed rollback must never discard the previous working app.
        backup_dir = Path(tempfile.mkdtemp(prefix=".petspet-backup-", dir=APP.parent))
        backup = backup_dir / "PetsPet.app"
        installed = False
        try:
            if APP.exists() or APP.is_symlink():
                APP.rename(backup)
            staged_app.rename(APP)
            installed = True
            run(["codesign", "--verify", "--strict", APP])
            if digest(APP / "Contents/MacOS/PetsPet") != manifest["binarySHA256"]:
                raise ValueError("Installed binary does not match the archived release")
        except BaseException:
            try:
                if installed:
                    APP.rename(staged_app)
                if backup.exists() or backup.is_symlink():
                    backup.rename(APP)
            except OSError as error:
                raise RuntimeError("Installation rollback failed; recovery files retained at " + str(backup_dir)) from error
            backup_dir.rmdir()
            raise
        shutil.rmtree(backup_dir)
    print("INSTALLED " + version + " at " + str(APP))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--archive-existing", metavar="VERSION")
    action.add_argument("--install", metavar="VERSION")
    parser.add_argument("--preview", help="Historical screenshot for an existing binary baseline")
    parser.add_argument("--revision", action="store_true", help="Replace the final archive after an approved same-version update")
    arguments = parser.parse_args()
    if arguments.revision and (arguments.install or arguments.archive_existing):
        parser.error("--revision only applies to a new source build")
    if arguments.install:
        if arguments.preview:
            parser.error("--preview only applies to archiving")
        install_release(arguments.install)
    else:
        archive_release(arguments.archive_existing, arguments.preview, arguments.revision)


if __name__ == "__main__":
    main()
