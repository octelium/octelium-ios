#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="${LIBOCTELIUM_SOURCE_DIR:-${ROOT}/../liboctelium}"
OUT_DIR="${OCTELIUM_HOST_LIB_DIR:-${ROOT}/build/host-libs}"
HEADER="${ROOT}/OcteliumKit/Sources/COctelium/octelium.h"

if [ ! -f "${SOURCE_DIR}/include/octelium.h" ]; then
  echo "Could not find liboctelium at ${SOURCE_DIR}" >&2
  echo "Set LIBOCTELIUM_SOURCE_DIR to the root of the liboctelium repository" >&2
  exit 1
fi

if ! cmp -s "${SOURCE_DIR}/include/octelium.h" "${HEADER}"; then
  echo "OcteliumKit/Sources/COctelium/octelium.h differs from ${SOURCE_DIR}/include/octelium.h" >&2
  echo "Copy the C header of the liboctelium revision that is built" >&2
  exit 1
fi

mkdir -p "${OUT_DIR}"

cargo build --release --lib --manifest-path "${SOURCE_DIR}/Cargo.toml"

cp "${SOURCE_DIR}/target/release/liboctelium.a" "${OUT_DIR}/liboctelium.a"

echo "Built the host library into ${OUT_DIR}"
