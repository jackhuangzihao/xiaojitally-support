#!/usr/bin/env python3
"""Repeatable local gate; uses disposable builds/data and never signs or uploads.

python3 Checks/verify.py --simulator <UDID> [--performance] [--output /path/to/logs]
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", required=True, help="Available iPhone simulator UDID (see xcrun simctl list devices)")
    parser.add_argument("--performance", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT / ".build/verification")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    (output / "summary.json").write_text('{"passed": false, "status": "running"}\n')
    stages = []
    child_env = {k: v for k, v in os.environ.items()
                 if not k.startswith(("JIANSHI_", "SIMCTL_CHILD_JIANSHI_"))}

    def run(name, command, *, marker=None, build=False):
        print(f"Checking {name}…", flush=True)
        started = time.monotonic()
        log = output / (name + ".log")
        with log.open("w") as stream:
            result = subprocess.run(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT, timeout=1200, env=child_env)
        text = log.read_text(errors="replace")
        if result.returncode or (marker and marker not in text):
            raise RuntimeError(f"{name} failed; see {log}")
        if build:
            warnings = [line for line in text.splitlines() if ": warning:" in line
                        and "Metadata extraction skipped. No AppIntents.framework dependency found." not in line]
            if warnings:
                raise RuntimeError(f"{name} has warnings; see {log}")
        stages.append({"name": name, "seconds": round(time.monotonic() - started, 2), "log": log.name})

    def hashes():
        source_files = sorted(p for folder in ("Sources", "Widget", "Assets.xcassets", "Jianshi.xcodeproj", "Checks")
                              for p in (ROOT / folder).rglob("*") if p.is_file()
                              and "xcuserdata" not in p.parts and "__pycache__" not in p.parts)
        source_files += sorted(p for p in ROOT.iterdir() if p.suffix in (".entitlements", ".plist", ".xcprivacy"))
        return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in source_files}
    source = hashes()
    (output / "source-sha256.json").write_text(json.dumps(source, indent=2, ensure_ascii=False) + "\n")
    devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
    device = next((d for group in devices["devices"].values() for d in group if d["udid"] == args.simulator), None)
    if not device:
        raise RuntimeError("The requested simulator is not available")
    identity = f"local.jianshi.sandboxcheck.verify{os.getpid()}"
    installed = False
    mac_app = None
    passed = False
    directory = tempfile.TemporaryDirectory(prefix="tally-verify-")
    temporary = directory.name
    try:
        run("project-sources", [sys.executable, str(ROOT / "Checks/check_project_sources.py")], marker="PASS:")
        products = {}
        for name, destination, configuration in (
            ("mac", "generic/platform=macOS", "AppStore"),
            ("simulator", "generic/platform=iOS Simulator", "AppStore-iphonesimulator"),
            ("iphone", "generic/platform=iOS", "AppStore-iphoneos"),
        ):
            derived = Path(temporary) / name
            command = ["xcodebuild", "-project", str(ROOT / "Jianshi.xcodeproj"), "-scheme", "Jianshi-AppStore",
                       "-configuration", "AppStore", "-destination", destination, "-derivedDataPath", str(derived),
                       "CODE_SIGNING_ALLOWED=NO", "PRODUCT_BUNDLE_IDENTIFIER=" + identity,
                       "SWIFT_STRICT_CONCURRENCY=complete", "ONLY_ACTIVE_ARCH=NO", "build"]
            if name == "mac":
                mac_app = derived / "Build/Products/AppStore/小记.app"
            run(name + "-build", command, marker="** BUILD SUCCEEDED **", build=True)
            apps = list((derived / "Build/Products" / configuration).glob("*.app"))
            if len(apps) != 1:
                raise RuntimeError(f"Expected one {name} app, got {apps}")
            products[name] = apps[0]
            run(name + "-package", [sys.executable, str(ROOT / "Checks/check_release_bundle.py"), str(apps[0])], marker="PASS:")
        mac_app = products["mac"]
        info = plistlib.loads((mac_app / "Contents/Info.plist").read_bytes())
        executable = str(mac_app / "Contents/MacOS" / info["CFBundleExecutable"])
        run("mac-self-check", [executable, "--self-check"], marker="checks — calendar")
        run("frozen-migration", [sys.executable, str(ROOT / "Checks/check_migration.py"), executable], marker="FROZEN MIGRATION PASS:")
        run("account-currency", [sys.executable, str(ROOT / "Checks/check_finance_account_switch.py")], marker="PASS:")
        if args.performance:
            run("performance", [executable, "--performance-check"], marker="PERF PASS:")
        if device["state"] != "Booted":
            run("simulator-boot", ["xcrun", "simctl", "boot", args.simulator])
        run("simulator-ready", ["xcrun", "simctl", "bootstatus", args.simulator, "-b"])
        run("simulator-install", ["xcrun", "simctl", "install", args.simulator, str(products["simulator"])])
        installed = True
        run("simulator-self-check", ["xcrun", "simctl", "launch", "--console", "--terminate-running-process",
                                     args.simulator, identity, "--self-check"], marker="checks — calendar")
        if hashes() != source:
            raise RuntimeError("Source changed while checks were running; rerun the gate")
        passed = True
    finally:
        if installed:
            subprocess.run(["xcrun", "simctl", "uninstall", args.simulator, identity], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if mac_app:
            subprocess.run(["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                            "-u", str(mac_app)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        directory.cleanup()
        (output / "summary.json").write_text(json.dumps({"passed": passed, "scope": "unsigned local build and regression checks",
            "simulator": args.simulator, "stages": stages}, indent=2) + "\n")
    print(f"LOCAL GATE PASS: {len(stages)} stages; logs: {output}")


if __name__ == "__main__":
    main()
