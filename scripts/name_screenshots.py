#!/usr/bin/env python3
"""Rename exported xcresult attachments to the names the test gave them.

`xcresulttool export attachments` writes files under generated names and
records the original name in manifest.json. Screenshots are reviewed by eye
before they go on a store listing, so they have to be called 01-library.png,
not Screenshot_1_<uuid>.png.
"""
import json
import pathlib
import re
import sys

# XCTest appends "_<index>_<uuid>" to the name the test gave the attachment.
SUFFIX = re.compile(r"_\d+_[0-9A-Fa-f-]{36}(?=\.png$|$)")


def entries(manifest):
    """Yield (exported_name, given_name) across the manifest's shapes.

    The manifest is a list of tests, each with an attachments array; the field
    naming has moved around between Xcode versions, so accept the aliases
    rather than pinning to one.
    """
    tests = manifest if isinstance(manifest, list) else manifest.get("tests", [])
    for test in tests:
        for att in test.get("attachments", []):
            exported = att.get("exportedFileName") or att.get("fileName")
            given = att.get("suggestedHumanReadableName") or att.get("name")
            if exported and given:
                yield exported, given


def main(directory):
    out = pathlib.Path(directory)
    manifest_path = out / "manifest.json"
    if not manifest_path.exists():
        sys.exit(f"no manifest.json in {out}")

    manifest = json.loads(manifest_path.read_text())
    renamed = 0
    for exported, given in entries(manifest):
        source = out / exported
        if not source.exists():
            continue
        clean = SUFFIX.sub("", given)
        target = out / (clean if clean.lower().endswith(".png") else clean + ".png")
        source.replace(target)
        renamed += 1

    manifest_path.unlink()
    print(f"  {renamed} screenshots → {out}")
    if renamed == 0:
        sys.exit("no attachments were renamed — check the manifest format")


if __name__ == "__main__":
    main(sys.argv[1])
