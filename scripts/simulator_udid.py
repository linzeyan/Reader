#!/usr/bin/env python3
"""Print the UDID of the simulator to shoot a device name on, creating it if need be.

    simulator_udid.py NAME [DEVICE_TYPE]

The type defaults to the name. A different name is for a simulator of its own — the
preview walk changes settings that would otherwise follow the screenshot run around.

The newest iOS runtime that can run the device wins. `-destination name=…` alone
resolves against the newest runtime only, so once Xcode ships a runtime that has no
simulator of that name, the name matches nothing — while a check that only asks
whether *some* simulator has the name still finds the one on the older runtime and
creates nothing. Both happened when iOS 27.0 arrived beside 26.5.

Newest first because that is the system the listing is photographed on; older only
for a device the newest runtime no longer runs (the small phones the store still has
slots for), where the older runtime is the only way to shoot that screen at all.
"""
import json
import subprocess
import sys


def simctl(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["xcrun", "simctl", *args], capture_output=True, text=True)


def version(runtime: dict) -> tuple:
    return tuple(int(part) for part in runtime["version"].split("."))


name = sys.argv[1]
device_type = sys.argv[2] if len(sys.argv) > 2 else name
devices = json.loads(simctl("list", "-j", "devices", "available").stdout)["devices"]
runtimes = json.loads(simctl("list", "-j", "runtimes", "available").stdout)["runtimes"]
ios = sorted((r for r in runtimes if r.get("platform") == "iOS"), key=version, reverse=True)

for runtime in ios:
    existing = [d for d in devices.get(runtime["identifier"], []) if d["name"] == name]
    if existing:
        print(existing[0]["udid"])
        sys.exit(0)
    if any(t["name"] == device_type for t in runtime.get("supportedDeviceTypes", [])):
        created = simctl("create", name, device_type, runtime["identifier"])
        if created.returncode == 0:
            print(created.stdout.strip())
            sys.exit(0)
        print(created.stderr.strip(), file=sys.stderr)

sys.exit(f"no available iOS runtime can run a simulator named {name!r}")
