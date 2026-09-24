#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="${OCTELIUM_SOURCE_DIR:-${ROOT}/../octelium}"
OUT_DIR="${OCTELIUM_HOST_LIB_DIR:-${ROOT}/build/host-libs}"

if [ ! -f "${SOURCE_DIR}/client/liboctelium/capi.go" ]; then
  echo "Could not find liboctelium at ${SOURCE_DIR}/client/liboctelium" >&2
  echo "Set OCTELIUM_SOURCE_DIR to the root of the Octelium repository" >&2
  exit 1
fi

mkdir -p "${OUT_DIR}"

(
  cd "${SOURCE_DIR}"
  CGO_ENABLED=1 go build -trimpath -buildvcs=false -buildmode=c-archive \
    -o "${OUT_DIR}/liboctelium.a" github.com/octelium/octelium/client/liboctelium
)

rm -f "${OUT_DIR}/liboctelium.h"

echo "Built the host library into ${OUT_DIR}"
