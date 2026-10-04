#!/usr/bin/env python3
"""Generate synthetic data with the frozen, independently archived build-52 source.

Usage: python3 generate.py old-source.zip old-source-checks.json /private/tmp/schema-52-regenerated
Never run the old app's normal startup or open a default/user store.
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile
import zipfile

HERE = Path(__file__).resolve().parent
ARCHIVE_SHA256 = "cf32653491a3407d422d4ce41f326f7d674b6d5af1472746096777d19f6cf7d7"
CHECKS_SHA256 = "e018fc9df76cd577a50a299681985d2f0d68ee732d5dd5d85720a4ab0c29e035"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    archive, checks, output = (Path(value).resolve() for value in sys.argv[1:])
    if output.exists():
        raise SystemExit("Output must not exist; frozen fixtures must never be overwritten by a test.")
    if digest(archive) != ARCHIVE_SHA256 or digest(checks) != CHECKS_SHA256:
        raise SystemExit("The archived source or its original checksum list does not match the pinned build 52.")
    expected_sources = json.loads(checks.read_text())
    with tempfile.TemporaryDirectory(prefix="tally-migration52-", dir="/private/tmp") as folder:
        temp = Path(folder)
        project = temp / "source"
        project.mkdir()
        with zipfile.ZipFile(archive) as source:
            actual_sources = {}
            for member in source.infolist():
                destination = (project / member.filename).resolve()
                if project not in destination.parents or stat.S_ISLNK(member.external_attr >> 16):
                    raise SystemExit("Unexpected path or link in pinned source archive")
                if not member.is_dir():
                    actual_sources[member.filename] = hashlib.sha256(source.read(member)).hexdigest()
            if actual_sources != expected_sources:
                raise SystemExit("Archived source files do not match their original checksum list")
            source.extractall(project)
        check = project / "Sources/SelfCheck.swift"
        check.write_text(check.read_text() + "\n" + (HERE / "generate.swift").read_text())
        app = project / "Sources/JianshiApp.swift"
        needle = "    init() {\n"
        hook = '''    init() {
        if let path = ProcessInfo.processInfo.environment["TALLY_FROZEN_FIXTURE_OUTPUT"] {
            do { try SelfCheck.exportFrozenSchema52(to: URL(fileURLWithPath: path)); exit(0) }
            catch { print("FROZEN FIXTURE FAILED: \\(error)"); exit(1) }
        }
'''
        if app.read_text().count(needle) != 1:
            raise SystemExit("The pinned app initializer changed")
        app.write_text(app.read_text().replace(needle, hook, 1))
        build = temp / "build"
        with (temp / "build.log").open("w") as log:
            result = subprocess.run(["xcodebuild", "-project", str(project / "Jianshi.xcodeproj"),
                "-scheme", "Jianshi-AppStore", "-configuration", "AppStore", "-destination", "generic/platform=macOS",
                "-derivedDataPath", str(build), "CODE_SIGNING_ALLOWED=NO", "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES",
                "PRODUCT_BUNDLE_IDENTIFIER=local.jianshi.sandboxcheck.migration52", "build"], stdout=log, stderr=subprocess.STDOUT)
        if result.returncode:
            print((temp / "build.log").read_text()[-12000:])
            raise SystemExit(result.returncode)
        bundle = build / "Build/Products/AppStore/小记.app"
        executable = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())["CFBundleExecutable"]
        generated = temp / "generated"
        env = {key: value for key, value in os.environ.items()
               if not key.startswith(("JIANSHI_", "SIMCTL_CHILD_JIANSHI_"))}
        env["TALLY_FROZEN_FIXTURE_OUTPUT"] = str(generated)
        subprocess.run([str(bundle / "Contents/MacOS" / executable)], env=env, check=True)
        output.mkdir(parents=True)
        source = sqlite3.connect(f"file:{generated / 'source.store'}?mode=ro", uri=True)
        try:
            dest = sqlite3.connect(output / "store.sqlite")
            try:
                source.backup(dest)
                if dest.execute("PRAGMA quick_check").fetchone()[0] != "ok":
                    raise SystemExit("Generated SQLite store failed integrity check")
                dest.execute("PRAGMA wal_checkpoint(TRUNCATE)")
                dest.execute("PRAGMA journal_mode=DELETE")
            finally:
                dest.close()
        finally:
            source.close()
        for name in ("expected.json", "cloud-baseline.json", "cloud-state.json"):
            shutil.copyfile(generated / name, output / name)
        exported = json.loads((output / "expected.json").read_text())
        if exported["version"] != 6 or "weekTitles" in exported:
            raise SystemExit("Build-52 export must retain its original version and absent week titles")
        files = {name: digest(output / name) for name in ("store.sqlite", "expected.json", "cloud-baseline.json", "cloud-state.json")}
        manifest = {"sourceBuild": "1.0 (52)", "synthetic": True,
                    "sourceArchive": archive.name, "sourceArchiveSHA256": ARCHIVE_SHA256,
                    "sourceChecksumFile": checks.name, "sourceChecksumSHA256": CHECKS_SHA256,
                    "sourceSHA256": actual_sources,
                    "xcode": subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
                    "generatorSHA256": {name: digest(HERE / name) for name in ("generate.py", "generate.swift")},
                    "filesSHA256": files}
        (output / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True, ensure_ascii=False) + "\n")
    print(f"Frozen synthetic fixture: {output}")


if __name__ == "__main__":
    main()
