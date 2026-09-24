#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="${OCTELIUM_SOURCE_DIR:-${ROOT}/../octelium}"
OUT_DIR="${OCTELIUM_LIB_DIR:-${ROOT}/liboctelium}"
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-18.0}"
SLICES="${SLICES:-iphoneos-arm64 iphonesimulator-arm64 iphonesimulator-amd64}"
LDFLAGS_PATH="github.com/octelium/octelium/pkg/utils/ldflags"

if [ ! -f "${SOURCE_DIR}/client/liboctelium/capi.go" ]; then
  echo "Could not find liboctelium at ${SOURCE_DIR}/client/liboctelium" >&2
  echo "Set OCTELIUM_SOURCE_DIR to the root of an Octelium repository revision that includes liboctelium" >&2
  exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "Could not find xcrun. liboctelium for iOS can only be built on macOS with Xcode" >&2
  exit 1
fi

COMMIT="$(git -C "${SOURCE_DIR}" rev-parse HEAD)"
TAG="${OCTELIUM_TAG:-$(git -C "${SOURCE_DIR}" describe --tags --exact-match --match 'v*.*.*' 2>/dev/null || true)}"
BRANCH="$(git -C "${SOURCE_DIR}" rev-parse --abbrev-ref HEAD)"

LDFLAGS="-s -w -X ${LDFLAGS_PATH}.GitCommit=${COMMIT} -X ${LDFLAGS_PATH}.GitBranch=${BRANCH} -X ${LDFLAGS_PATH}.Mode=production"
if [ -n "${TAG}" ]; then
  LDFLAGS="${LDFLAGS} -X ${LDFLAGS_PATH}.GitTag=${TAG} -X ${LDFLAGS_PATH}.SemVer=${TAG}"
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

build_slice() {
  local slice="$1"
  local sdk="${slice%-*}"
  local goarch="${slice##*-}"
  local arch target

  case "${goarch}" in
    arm64)
      arch="arm64"
      ;;
    amd64)
      arch="x86_64"
      ;;
    *)
      echo "Unsupported architecture: ${goarch}" >&2
      exit 1
      ;;
  esac

  case "${sdk}" in
    iphoneos)
      target="${arch}-apple-ios${IOS_DEPLOYMENT_TARGET}"
      ;;
    iphonesimulator)
      target="${arch}-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator"
      ;;
    *)
      echo "Unsupported SDK: ${sdk}" >&2
      exit 1
      ;;
  esac

  local sdk_path cc
  sdk_path="$(xcrun --sdk "${sdk}" --show-sdk-path)"
  cc="$(xcrun --sdk "${sdk}" --find clang)"

  echo "Building liboctelium ${TAG:-${COMMIT}} for ${target}"

  mkdir -p "${WORK_DIR}/${slice}"

  (
    cd "${SOURCE_DIR}"
    CGO_ENABLED=1 GOOS=ios GOARCH="${goarch}" \
      CC="${cc}" \
      CGO_CFLAGS="-isysroot ${sdk_path} -target ${target} -O2" \
      CGO_LDFLAGS="-isysroot ${sdk_path} -target ${target}" \
      go build -trimpath -buildvcs=false -ldflags "${LDFLAGS}" -buildmode=c-archive \
      -o "${WORK_DIR}/${slice}/liboctelium.a" github.com/octelium/octelium/client/liboctelium
  )

  rm -f "${WORK_DIR}/${slice}/liboctelium.h"
}

for slice in ${SLICES}; do
  build_slice "${slice}"
done

XCFRAMEWORK_ARGS=()

if [ -f "${WORK_DIR}/iphoneos-arm64/liboctelium.a" ]; then
  XCFRAMEWORK_ARGS+=(-library "${WORK_DIR}/iphoneos-arm64/liboctelium.a")
fi

SIMULATOR_LIBS=()
for slice in iphonesimulator-arm64 iphonesimulator-amd64; do
  if [ -f "${WORK_DIR}/${slice}/liboctelium.a" ]; then
    SIMULATOR_LIBS+=("${WORK_DIR}/${slice}/liboctelium.a")
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

printf '%s\n' "${COMMIT}" > "${OUT_DIR}/OCTELIUM_COMMIT"
printf '%s\n' "${TAG:-${BRANCH}}" > "${OUT_DIR}/OCTELIUM_REF"
printf 'LIBOCTELIUM_COMMIT = %s\nLIBOCTELIUM_REF = %s\n' "${COMMIT}" "${TAG:-${BRANCH}}" > "${OUT_DIR}/liboctelium.xcconfig"

"${ROOT}/scripts/check-xcframework.sh" "${OUT_DIR}/liboctelium.xcframework"

echo "Built liboctelium into ${OUT_DIR}"
