#!/usr/bin/env python3
"""Run production purchase code in an isolated XCTest host with Apple's local StoreKit.

The generated host has no user models, CloudKit, app group or production identity.
Neither production schemes nor the real installed application are changed.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[1]
EXPECTED_CASES = [
    *(f"purchase/restore/expiry {product} round {round}" for round in (1, 2)
      for product in ("monthly", "annual", "lifetime")),
    "pending approval and transaction delivery",
    "purchase failure then retry",
    "restore failure preserves access then retry",
]


def project(directory, identity):
    directory = directory.resolve()
    objects = {}

    def add(kind, **fields):
        key = f"{len(objects) + 1:024X}"
        objects[key] = {"isa": kind, **fields}
        return key

    def configurations(settings):
        return add("XCConfigurationList", buildConfigurations=[
            add("XCBuildConfiguration", name="Debug", buildSettings=settings)],
            defaultConfigurationIsVisible=0, defaultConfigurationName="Debug")

    def phase(kind, paths):
        files = []
        for path in paths:
            ref = add("PBXFileReference", path=str(path), sourceTree="<absolute>")
            files.append(add("PBXBuildFile", fileRef=ref))
        return add(kind, buildActionMask=2147483647, files=files, runOnlyForDeploymentPostprocessing=0)

    host = directory / "Host.swift"
    host.write_text('import SwiftUI\n@main struct Host: App { var body: some Scene { WindowGroup { Text("Isolated StoreKit test") } } }\n')
    app_product = add("PBXFileReference", path="PurchaseHost.app", sourceTree="BUILT_PRODUCTS_DIR", explicitFileType="wrapper.application")
    test_product = add("PBXFileReference", path="PurchaseTests.xctest", sourceTree="BUILT_PRODUCTS_DIR", explicitFileType="wrapper.cfbundle")
    common = {"SWIFT_VERSION": "5.0", "SWIFT_STRICT_CONCURRENCY": "complete", "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
              "MACOSX_DEPLOYMENT_TARGET": "14.0", "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator",
              "GENERATE_INFOPLIST_FILE": "YES", "CODE_SIGN_IDENTITY": "-", "CODE_SIGN_STYLE": "Manual",
              "ALWAYS_SEARCH_USER_PATHS": "NO", "COPY_PHASE_STRIP": "NO",
              "TARGETED_DEVICE_FAMILY": "1,2", "ENABLE_TESTABILITY": "YES", "SWIFT_OPTIMIZATION_LEVEL": "-Onone"}
    app = add("PBXNativeTarget", name="PurchaseHost", productName="PurchaseHost", productReference=app_product,
              productType="com.apple.product-type.application", buildConfigurationList=configurations({**common,
              "PRODUCT_BUNDLE_IDENTIFIER": identity, "PRODUCT_NAME": "PurchaseHost"}),
              buildPhases=[phase("PBXSourcesBuildPhase", [host])], dependencies=[], buildRules=[])
    files = [ROOT / "Sources/Purchases" / name for name in
             ("PurchaseCatalog.swift", "ProAccess.swift", "StoreKitPurchaseClient.swift", "PurchaseStore.swift")]
    files.append(ROOT / "Checks/StoreKit/NativePurchaseCheck.swift")
    test = add("PBXNativeTarget", name="PurchaseTests", productName="PurchaseTests", productReference=test_product,
               productType="com.apple.product-type.bundle.unit-test", buildConfigurationList=configurations({**common,
               "PRODUCT_BUNDLE_IDENTIFIER": identity + ".tests", "PRODUCT_NAME": "PurchaseTests",
               "TEST_HOST[sdk=macosx*]": "$(BUILT_PRODUCTS_DIR)/PurchaseHost.app/Contents/MacOS/PurchaseHost",
               "TEST_HOST[sdk=iphonesimulator*]": "$(BUILT_PRODUCTS_DIR)/PurchaseHost.app/PurchaseHost",
               "BUNDLE_LOADER": "$(TEST_HOST)", "TEST_TARGET_NAME": "PurchaseHost",
               "FRAMEWORK_SEARCH_PATHS[sdk=macosx*]": ["$(inherited)", "$(PLATFORM_DIR)/Developer/Library/Frameworks"],
               "FRAMEWORK_SEARCH_PATHS[sdk=iphonesimulator*]": ["$(inherited)", "$(PLATFORM_DIR)/Developer/Library/Frameworks", "$(SDKROOT)/Developer/Library/Frameworks"],
               "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@loader_path/Frameworks", "@executable_path/Frameworks"]}),
               buildPhases=[phase("PBXSourcesBuildPhase", files), phase("PBXResourcesBuildPhase", [ROOT / "Checks/StoreKit/TallyPro.storekit"])],
               dependencies=[add("PBXTargetDependency", target=app)], buildRules=[])
    products = add("PBXGroup", name="Products", children=[app_product, test_product], sourceTree="<group>")
    source_refs = [key for key, value in objects.items()
                   if value["isa"] == "PBXFileReference" and key not in (app_product, test_product)]
    group = add("PBXGroup", children=[products, *source_refs], sourceTree="<group>")
    root = add("PBXProject", attributes={"LastUpgradeCheck": "2660"}, buildConfigurationList=configurations(common),
               compatibilityVersion="Xcode 14.0", developmentRegion="en", hasScannedForEncodings=0, knownRegions=["en", "Base"],
               mainGroup=group, productRefGroup=products, projectDirPath="", projectRoot="", targets=[app, test])
    def encode(value):
        if isinstance(value, dict): return "{\n" + "\n".join(json.dumps(k) + " = " + encode(v) + ";" for k, v in value.items()) + "\n}"
        if isinstance(value, list): return "(" + ",".join(encode(v) for v in value) + ")"
        return json.dumps(str(value), ensure_ascii=False)
    path = directory / "PurchaseCheck.xcodeproj"
    path.mkdir()
    (path / "project.pbxproj").write_text("// !$*UTF8*$!\n" + encode({"archiveVersion": 1, "objectVersion": 56, "objects": objects, "rootObject": root}))
    schemes = path / "xcshareddata/xcschemes"
    schemes.mkdir(parents=True)
    reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{test}" BuildableName="PurchaseTests.xctest" BlueprintName="PurchaseTests" ReferencedContainer="container:PurchaseCheck.xcodeproj"/>'
    host_reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app}" BuildableName="PurchaseHost.app" BlueprintName="PurchaseHost" ReferencedContainer="container:PurchaseCheck.xcodeproj"/>'
    # Xcode resolves this reference from xcshareddata, not its xcschemes subdirectory.
    configuration = escape(os.path.relpath(ROOT / "Checks/StoreKit/TallyPro.storekit", schemes.parent), {'"': "&quot;"})
    (schemes / "PurchaseTests.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2660" version="1.3">
  <BuildAction buildImplicitDependencies="YES"><BuildActionEntries>
    <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{host_reference}</BuildActionEntry>
    <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{reference}</BuildActionEntry>
  </BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
    <Testables><TestableReference skipped="NO">{reference}</TestableReference></Testables>
  </TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" debugServiceExtension="internal">
    <BuildableProductRunnable runnableDebuggingMode="0">{host_reference}</BuildableProductRunnable>
    <StoreKitConfigurationFileReference identifier="{configuration}"/>
  </LaunchAction>
</Scheme>''')
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--prepare-only", action="store_true",
                        help="Keep an isolated project for Xcode IDE Run, then Test when the CLI cannot activate StoreKit.")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    identity = "local.jianshi.sandboxcheck.storekit" + str(os.getpid())
    if args.prepare_only:
        directory = output / "project"
        directory.mkdir(exist_ok=False)
        path = project(directory, identity)
        print("ISOLATED STOREKIT PROJECT:", path)
        print("TEST IDENTITY:", identity)
        print("Select My Mac or an iPhone simulator in Xcode; Run the empty host once, then Test.")
        return
    with tempfile.TemporaryDirectory(prefix="tally-storekit-") as temporary:
        directory = Path(temporary)
        path = project(directory, identity)
        destination = "platform=iOS Simulator,id=" + args.simulator if args.simulator else "platform=macOS,arch=arm64"
        command = ["xcodebuild", "-project", str(path), "-scheme", "PurchaseTests", "-destination", destination,
                   "-derivedDataPath", str(directory / "build"), "-resultBundlePath", str(output / "StoreKit.xcresult"),
                   "-parallel-testing-enabled", "NO", "test"]
        try:
            with (output / "test.log").open("w") as log:
                result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=600)
            text = (output / "test.log").read_text(errors="replace")
            warnings = [line for line in text.splitlines() if ": warning:" in line and "No AppIntents.framework" not in line]
            # Xcode 26.6's own StoreKitTest header references a deprecated StoreKit 1 type.
            sdk_warnings = [line for line in warnings if line.startswith("/Applications/Xcode.app/Contents/Developer/") and
                            "StoreKitTest.framework/Headers/SKTestTransaction.h:" in line and
                            "'SKPaymentTransactionState' is deprecated" in line]
            source_warnings = [line for line in warnings if line not in sdk_warnings]
            missing = [case for case in EXPECTED_CASES if "NATIVE STOREKIT CASE PASS: " + case not in text]
            if result.returncode or missing or source_warnings:
                raise RuntimeError("Native StoreKit checks did not pass; see " + str(output / "test.log"))
            print("NATIVE STOREKIT HOST PASS:", output)
            if sdk_warnings:
                print("Apple SDK header warnings retained in test.log:", len(sdk_warnings))
        finally:
            if args.simulator:
                subprocess.run(["xcrun", "simctl", "uninstall", args.simulator, identity], capture_output=True)


if __name__ == "__main__":
    main()
