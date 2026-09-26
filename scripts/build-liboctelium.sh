#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="${LIBOCTELIUM_SOURCE_DIR:-${ROOT}/../liboctelium}"
OUT_DIR="${OCTELIUM_LIB_DIR:-${ROOT}/liboctelium}"
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-18.0}"
TARGETS="${TARGETS:-aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios}"
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

if ! command -v xcrun >/dev/null 2>&1; then
  echo "Could not find xcrun. liboctelium for iOS can only be built on macOS with Xcode" >&2
  exit 1
fi

COMMIT="$(git -C "${SOURCE_DIR}" rev-parse HEAD)"
TAG="${LIBOCTELIUM_TAG:-$(git -C "${SOURCE_DIR}" describe --tags --exact-match --match 'v*.*.*' 2>/dev/null || true)}"
BRANCH="$(git -C "${SOURCE_DIR}" rev-parse --abbrev-ref HEAD)"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

for target in ${TARGETS}; do
  case "${target}" in
    aarch64-apple-ios | aarch64-apple-ios-sim | x86_64-apple-ios)
      ;;
    *)
      echo "Unsupported target: ${target}" >&2
      exit 1
      ;;
  esac

  echo "Building liboctelium ${TAG:-${COMMIT}} for ${target}"

  IPHONEOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET}" \
    cargo build --release --lib --target "${target}" --manifest-path "${SOURCE_DIR}/Cargo.toml"

  mkdir -p "${WORK_DIR}/${target}"
  cp "${SOURCE_DIR}/target/${target}/release/liboctelium.a" "${WORK_DIR}/${target}/liboctelium.a"
done

XCFRAMEWORK_ARGS=()

if [ -f "${WORK_DIR}/aarch64-apple-ios/liboctelium.a" ]; then
  XCFRAMEWORK_ARGS+=(-library "${WORK_DIR}/aarch64-apple-ios/liboctelium.a")
fi

SIMULATOR_LIBS=()
for target in aarch64-apple-ios-sim x86_64-apple-ios; do
  if [ -f "${WORK_DIR}/${target}/liboctelium.a" ]; then
    SIMULATOR_LIBS+=("${WORK_DIR}/${target}/liboctelium.a")
  fi
done

if [ "${#SIMULATOR_LIBS[@]}" -gt 0 ]; then
  mkdir -p "${WORK_DIR}/iphonesimulator"
  lipo -create "${SIMULATOR_LIBS[@]}" -output "${WORK_DIR}/iphonesimulator/liboctelium.a"
  XCFRAMEWORK_ARGS+=(-library "${WORK_DIR}/iphonesimulator/liboctelium.a")
fi

rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"

xcodebuild -create-xcframework "${XCFRAMEWORK_ARGS[@]}" -output "${OUT_DIR}/liboctelium.xcframework"

printf '%s\n' "${COMMIT}" > "${OUT_DIR}/LIBOCTELIUM_COMMIT"
printf '%s\n' "${TAG:-${BRANCH}}" > "${OUT_DIR}/LIBOCTELIUM_REF"
printf 'LIBOCTELIUM_COMMIT = %s\nLIBOCTELIUM_REF = %s\n' "${COMMIT}" "${TAG:-${BRANCH}}" > "${OUT_DIR}/liboctelium.xcconfig"

"${ROOT}/scripts/check-xcframework.sh" "${OUT_DIR}/liboctelium.xcframework"

echo "Built liboctelium into ${OUT_DIR}"
