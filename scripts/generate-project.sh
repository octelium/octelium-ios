#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVED_DIR="${ROOT}/Octelium.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "Could not find xcodegen. Install it via 'brew install xcodegen'" >&2
  exit 1
fi

if [ ! -d "${ROOT}/liboctelium/liboctelium.xcframework" ]; then
  echo "Could not find liboctelium/liboctelium.xcframework. Build it via ./scripts/build-liboctelium.sh" >&2
  exit 1
fi

(
  cd "${ROOT}"
  xcodegen generate --spec project.yml --quiet
)

mkdir -p "${RESOLVED_DIR}"
cp "${ROOT}/OcteliumKit/Package.resolved" "${RESOLVED_DIR}/Package.resolved"

echo "Generated Octelium.xcodeproj"
