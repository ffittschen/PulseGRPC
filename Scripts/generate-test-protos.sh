#!/bin/bash
# Regenerates the checked-in Echo fixtures used by PulseGRPCTests.
#
# Requires `protoc` on PATH (e.g. `brew install protobuf`). The Swift plugins are
# built from the package versions this package resolves, so the generated code
# always matches the runtime used by the tests.
set -euo pipefail

cd "$(dirname "$0")/.."

swift package resolve

build_plugin() {
    local package="$1" product="$2"
    swift build -c release --package-path ".build/checkouts/$package" --product "$product" >&2
    echo "$(swift build -c release --package-path ".build/checkouts/$package" --show-bin-path)/$product"
}

PROTOC_GEN_SWIFT="$(build_plugin swift-protobuf protoc-gen-swift)"
PROTOC_GEN_GRPC_SWIFT="$(build_plugin grpc-swift-protobuf protoc-gen-grpc-swift-2)"

FIXTURES="Tests/PulseGRPCTests/Fixtures"

protoc \
    --proto_path="$FIXTURES" \
    --plugin=protoc-gen-swift="$PROTOC_GEN_SWIFT" \
    --plugin=protoc-gen-grpc-swift-2="$PROTOC_GEN_GRPC_SWIFT" \
    --swift_out="$FIXTURES" \
    --swift_opt=Visibility=Internal \
    --grpc-swift-2_out="$FIXTURES" \
    --grpc-swift-2_opt=Visibility=Internal \
    "$FIXTURES/echo.proto"

echo "Generated $FIXTURES/echo.pb.swift and $FIXTURES/echo.grpc.swift"
