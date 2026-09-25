#!/usr/bin/env bash

set -euo pipefail

udid="$(xcrun simctl list devices available --json | python3 -c '
import json
import sys

devices = json.load(sys.stdin)["devices"]
runtimes = sorted((rt for rt in devices if "iOS" in rt), reverse=True)

for rt in runtimes:
    for device in devices[rt]:
        if device["name"].startswith("iPhone"):
            print(device["udid"])
            sys.exit(0)

sys.exit(1)
')"

echo "SIMULATOR=platform=iOS Simulator,id=${udid}"
