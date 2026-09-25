#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIT_DIR="${ROOT}/OcteliumKit"
PROTO_DIR="${KIT_DIR}/Protos"
PROTO_OUT_DIR="${KIT_DIR}/Sources/OcteliumProto/Generated"
GRPC_OUT_DIR="${KIT_DIR}/Sources/OcteliumAPI/Generated"
PROTOC="${PROTOC:-protoc}"

PROTOS=(
  "apis/protobuf/main/metav1/metav1.proto"
  "apis/protobuf/main/userv1/userv1.proto"
  "apis/protobuf/client/daemonv1/daemonv1.proto"
  "apis/protobuf/client/mobilev1/mobilev1.proto"
)

GRPC_PROTOS=(
  "apis/protobuf/main/userv1/userv1.proto"
)

if ! command -v "${PROTOC}" >/dev/null 2>&1; then
  echo "Could not find protoc. Install it or set PROTOC" >&2
  exit 1
fi

if [ -z "${PROTOC_GEN_SWIFT:-}" ] || [ -z "${PROTOC_GEN_GRPC_SWIFT:-}" ]; then
  echo "Building the protoc plugins pinned by OcteliumKit/Package.resolved"
  for product in protoc-gen-swift protoc-gen-grpc-swift-2; do
    swift build --package-path "${KIT_DIR}" -c release --product "${product}" >/dev/null
  done
  BIN_DIR="$(swift build --package-path "${KIT_DIR}" -c release --show-bin-path)"
  PROTOC_GEN_SWIFT="${PROTOC_GEN_SWIFT:-${BIN_DIR}/protoc-gen-swift}"
  PROTOC_GEN_GRPC_SWIFT="${PROTOC_GEN_GRPC_SWIFT:-${BIN_DIR}/protoc-gen-grpc-swift-2}"
fi

PROTO_PATHS=("--proto_path=.")
WKT_DIR="${PROTOBUF_WKT_DIR:-${KIT_DIR}/.build/checkouts/swift-protobuf/Protos/Sources/SwiftProtobuf}"
if [ -f "${WKT_DIR}/google/protobuf/timestamp.proto" ]; then
  PROTO_PATHS+=("--proto_path=${WKT_DIR}")
fi

rm -rf "${PROTO_OUT_DIR}" "${GRPC_OUT_DIR}"
mkdir -p "${PROTO_OUT_DIR}" "${GRPC_OUT_DIR}"

(
  cd "${PROTO_DIR}"

  "${PROTOC}" \
    "${PROTO_PATHS[@]}" \
    --plugin="protoc-gen-swift=${PROTOC_GEN_SWIFT}" \
    --swift_out="${PROTO_OUT_DIR}" \
    --swift_opt=Visibility=Public \
    --swift_opt=FileNaming=DropPath \
    "${PROTOS[@]}"

  "${PROTOC}" \
    "${PROTO_PATHS[@]}" \
    --plugin="protoc-gen-grpc-swift=${PROTOC_GEN_GRPC_SWIFT}" \
    --grpc-swift_out="${GRPC_OUT_DIR}" \
    --grpc-swift_opt=Visibility=Public \
    --grpc-swift_opt=FileNaming=DropPath \
    --grpc-swift_opt=Client=true \
    --grpc-swift_opt=Server=true \
    --grpc-swift_opt=ExtraModuleImports=OcteliumProto \
    "${GRPC_PROTOS[@]}"
)

echo "Generated the Swift protobuf and gRPC sources"
