#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PB_DIR="${OCTELIUM_PB_DIR:-${ROOT}/../pb}"
OUT_DIR="${ROOT}/OcteliumKit/Protos"

PROTOS=(
  "apis/protobuf/main/metav1/metav1.proto"
  "apis/protobuf/main/userv1/userv1.proto"
  "apis/protobuf/client/daemonv1/daemonv1.proto"
  "apis/protobuf/client/mobilev1/mobilev1.proto"
)

if [ ! -f "${PB_DIR}/apis/protobuf/client/mobilev1/mobilev1.proto" ]; then
  echo "Could not find the Octelium protobuf APIs at ${PB_DIR}" >&2
  echo "Set OCTELIUM_PB_DIR to the root of the protobuf APIs repository" >&2
  exit 1
fi

rm -rf "${OUT_DIR}/apis"

for proto in "${PROTOS[@]}"; do
  mkdir -p "$(dirname "${OUT_DIR}/${proto}")"
  cp "${PB_DIR}/${proto}" "${OUT_DIR}/${proto}"
done

if git -C "${PB_DIR}" rev-parse HEAD >/dev/null 2>&1; then
  git -C "${PB_DIR}" rev-parse HEAD > "${OUT_DIR}/PB_COMMIT"
fi

echo "Synchronized the Octelium protobuf APIs into ${OUT_DIR}"

"${ROOT}/scripts/generate-proto.sh"
