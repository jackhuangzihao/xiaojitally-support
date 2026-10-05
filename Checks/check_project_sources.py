#!/usr/bin/env python3
"""Catch moved, omitted, or duplicate Swift files in the Xcode project."""
from collections import Counter
import json
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]


def main():
    project = json.loads(subprocess.check_output([
        "plutil", "-convert", "json", "-o", "-",
        str(ROOT / "Jianshi.xcodeproj/project.pbxproj"),
    ]))
    objects = project["objects"]
    paths = {}

    def visit(identifier, parent):
        item = objects[identifier]
        tree = item.get("sourceTree", "<group>")
        if tree == "BUILT_PRODUCTS_DIR":
            return
        assert tree in ("<group>", "SOURCE_ROOT"), f"Unexpected source tree: {tree}"
        path = (ROOT if tree == "SOURCE_ROOT" else parent) / item.get("path", "")
        if item["isa"] == "PBXGroup":
            for child in item["children"]:
                visit(child, path)
        elif item.get("lastKnownFileType") == "sourcecode.swift":
            assert identifier not in paths, f"File reference appears twice: {path}"
            assert path.is_file(), f"Missing source: {path}"
            paths[identifier] = path.relative_to(ROOT).as_posix()

    visit(objects[project["rootObject"]]["mainGroup"], ROOT)
    expected = {
        "Jianshi": {p.relative_to(ROOT).as_posix() for p in (ROOT / "Sources").rglob("*.swift")},
        "JianshiWidget": {"Sources/Shared/WidgetShared.swift", "Widget/JianshiWidget.swift"},
    }
    targets = [item for item in objects.values() if item["isa"] == "PBXNativeTarget"]
    assert {item["name"] for item in targets} == set(expected), "Update source checks for the target change"
    for target in targets:
        sources = [paths[objects[entry]["fileRef"]]
                   for phase_id in target["buildPhases"]
                   for phase in [objects[phase_id]] if phase["isa"] == "PBXSourcesBuildPhase"
                   for entry in phase["files"]]
        duplicate = [path for path, count in Counter(sources).items() if count != 1]
        assert not duplicate, f"Duplicate membership in {target['name']}: {duplicate}"
        wanted = expected[target["name"]]
        assert set(sources) == wanted, (
            f"{target['name']}: missing {wanted - set(sources)}; unexpected {set(sources) - wanted}"
        )
    assert set(paths.values()) == set.union(*expected.values()), "Unbuilt Swift file reference"
    print(f"PASS: {len(expected['Jianshi'])} app sources; widget membership and source paths verified")


if __name__ == "__main__":
    main()
