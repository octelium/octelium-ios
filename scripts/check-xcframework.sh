#!/usr/bin/env bash

set -euo pipefail

TARGET="${1:-}"
SYMBOLS=(
  octelium_abi_version
  octelium_client_new
  octelium_client_call
  octelium_client_complete_request
  octelium_client_free
  octelium_free
)

if [ -z "${TARGET}" ] || [ ! -d "${TARGET}" ]; then
  echo "Usage: $0 path/to/liboctelium.xcframework" >&2
  exit 1
fi

found=0

while IFS= read -r lib; do
  found=$((found + 1))
  echo "Checking ${lib}: $(lipo -archs "${lib}")"

  exported="$(nm -gU "${lib}" 2>/dev/null || true)"
  for symbol in "${SYMBOLS[@]}"; do
    if ! grep -q "_${symbol}$" <<< "${exported}"; then
      echo "The symbol ${symbol} is not exported by ${lib}" >&2
      exit 1
    fi
  done
done < <(find "${TARGET}" -name 'liboctelium.a' -type f)

if [ "${found}" -eq 0 ]; then
  echo "No liboctelium.a found in ${TARGET}" >&2
  exit 1
fi

echo "Verified ${found} liboctelium libraries"
