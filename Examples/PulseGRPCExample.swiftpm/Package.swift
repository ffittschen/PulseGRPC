// swift-tools-version: 6.0
import AppleProductTypes
import PackageDescription

let package = Package(
    name: "PulseGRPCExample",
    platforms: [.iOS("18.0")],
    products: [
        .iOSApplication(
            name: "PulseGRPCExample",
            targets: ["AppModule"],
            bundleIdentifier: "com.example.PulseGRPCExample",
            displayVersion: "1.0",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .lightningBolt),
            accentColor: .presetColor(.blue),
            supportedDeviceFamilies: [.pad, .phone],
            supportedInterfaceOrientations: [.portrait, .landscapeLeft, .landscapeRight]
        ),
    ],
    dependencies: [
        // Named, because a path dependency's identity is otherwise its directory name.
        .package(name: "PulseGRPC", path: "../.."),
        .package(path: "../../../_forks/Pulse"),
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.4.2"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.4.1"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.1"),
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            dependencies: [
                .product(name: "PulseGRPC", package: "PulseGRPC"),
                .product(name: "PulseUI", package: "Pulse"),
                .product(name: "PulseProxy", package: "Pulse"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCInProcessTransport", package: "grpc-swift-2"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "."
        ),
    ]
)
