#!/usr/bin/env bash
# Regenerates the checked-in Echo fixtures used by PulseGRPCTests and the example app.
#
# Requires `protoc` on PATH (e.g. `brew install protobuf`). The Swift plugins are built
# from this package's resolved dependencies, so the generated code matches the runtime.
set -euo pipefail

cd "$(dirname "$0")/.."

command -v protoc >/dev/null || { echo "protoc not found (brew install protobuf)" >&2; exit 1; }

swift build -c release --product protoc-gen-swift
swift build -c release --product protoc-gen-grpc-swift-2
BIN="$(swift build -c release --show-bin-path)"

FIXTURES="Tests/PulseGRPCTests/Fixtures"

protoc \
    --proto_path="$FIXTURES" \
    --plugin=protoc-gen-swift="$BIN/protoc-gen-swift" \
    --plugin=protoc-gen-grpc-swift-2="$BIN/protoc-gen-grpc-swift-2" \
    --swift_out="$FIXTURES" \
    --swift_opt=Visibility=Internal \
    --grpc-swift-2_out="$FIXTURES" \
    --grpc-swift-2_opt=Visibility=Internal \
    "$FIXTURES/echo.proto"

echo "Generated $FIXTURES/echo.pb.swift and $FIXTURES/echo.grpc.swift"
