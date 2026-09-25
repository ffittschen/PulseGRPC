// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PulseGRPC",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2),
    ],
    products: [
        .library(name: "PulseGRPC", targets: ["PulseGRPC"]),
    ],
    dependencies: [
        .package(path: "../_forks/Pulse"),
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.4.2"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.1"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.4.1"),
    ],
    targets: [
        .target(
            name: "PulseGRPC",
            dependencies: [
                .product(name: "Pulse", package: "Pulse"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .testTarget(
            name: "PulseGRPCTests",
            dependencies: [
                "PulseGRPC",
                .product(name: "Pulse", package: "Pulse"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCInProcessTransport", package: "grpc-swift-2"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
    ]
)
