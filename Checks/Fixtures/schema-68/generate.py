#!/usr/bin/env python3
"""One-off provenance tool; normal regression checks consume committed fixtures.

Usage: python3 generate.py /private/tmp/schema-68-regenerated
Requires the exact pinned commit and Xcode. Never opens the default app store.
"""
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import sqlite3
import subprocess
import sys
import tarfile
import tempfile

COMMIT = "6614558dbb888ae9b453f54be3ed4e0fd36f8466"
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    output = Path(sys.argv[1]).resolve()
    if output.exists():
        raise SystemExit("Output must not exist; frozen fixtures must never be overwritten by a test.")
    resolved = subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", COMMIT], text=True).strip()
    if resolved != COMMIT:
        raise SystemExit("Pinned source commit does not match")
    with tempfile.TemporaryDirectory(prefix="tally-migration68-", dir="/private/tmp") as temp:
        temp = Path(temp)
        project = temp / "source"
        project.mkdir()
        archive = subprocess.check_output(["git", "-C", str(ROOT), "archive", COMMIT])
        with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
            for member in tar.getmembers():
                destination = (project / member.name).resolve()
                if project not in destination.parents or not (member.isfile() or member.isdir()):
                    raise SystemExit("Unexpected path or link in pinned source archive")
            tar.extractall(project)
        original = {name: digest(project / name) for name in (
            "Sources/Models.swift", "Sources/FinanceModels.swift", "Sources/CloudSync.swift")}
        check = project / "Sources/SelfCheck.swift"
        check.write_text(check.read_text() + "\n" + (HERE / "generate.swift").read_text())
        app = project / "Sources/JianshiApp.swift"
        needle = "    init() {\n"
        hook = '''    init() {
        if let path = ProcessInfo.processInfo.environment["TALLY_FROZEN_FIXTURE_OUTPUT"] {
            do { try SelfCheck.exportFrozenSchema68(to: URL(fileURLWithPath: path)); exit(0) }
            catch { print("FROZEN FIXTURE FAILED: \\(error)"); exit(1) }
        }
'''
        assert app.read_text().count(needle) == 1
        app.write_text(app.read_text().replace(needle, hook, 1))
        build = temp / "build"
        with (temp / "build.log").open("w") as log:
            result = subprocess.run(["xcodebuild", "-project", str(project / "Jianshi.xcodeproj"),
                "-scheme", "Jianshi-AppStore", "-configuration", "AppStore", "-destination", "generic/platform=macOS",
                "-derivedDataPath", str(build), "CODE_SIGNING_ALLOWED=NO", "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES",
                "PRODUCT_BUNDLE_IDENTIFIER=local.jianshi.sandboxcheck.migration68", "build"], stdout=log, stderr=subprocess.STDOUT)
        if result.returncode:
            print((temp / "build.log").read_text()[-12000:])
            raise SystemExit(result.returncode)
        bundle = build / "Build/Products/AppStore/小记.app"
        executable = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())["CFBundleExecutable"]
        generated = temp / "generated"
        env = os.environ.copy()
        env["TALLY_FROZEN_FIXTURE_OUTPUT"] = str(generated)
        subprocess.run([str(bundle / "Contents/MacOS" / executable)], env=env, check=True)
        output.mkdir(parents=True)
        source = sqlite3.connect(f"file:{generated / 'source.store'}?mode=ro", uri=True)
        try:
            dest = sqlite3.connect(output / "store.sqlite")
            try:
                source.backup(dest)
                assert dest.execute("PRAGMA quick_check").fetchone()[0] == "ok"
                dest.execute("PRAGMA wal_checkpoint(TRUNCATE)")
                dest.execute("PRAGMA journal_mode=DELETE")
            finally:
                dest.close()
        finally:
            source.close()
        for name in ("expected.json", "cloud-baseline.json", "cloud-state.json"):
            shutil.copyfile(generated / name, output / name)
        files = {name: digest(output / name) for name in ("store.sqlite", "expected.json", "cloud-baseline.json", "cloud-state.json")}
        manifest = {"sourceCommit": COMMIT, "sourceBuild": "1.0 (68)", "synthetic": True,
                    "xcode": subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
                    "sourceSHA256": original, "generatorSHA256": {name: digest(HERE / name) for name in ("generate.py", "generate.swift")},
                    "filesSHA256": files}
        (output / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(f"Frozen synthetic fixture: {output}")


if __name__ == "__main__":
    main()
