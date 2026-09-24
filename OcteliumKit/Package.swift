// swift-tools-version: 6.0

import PackageDescription

let swiftProtobuf: Target.Dependency = .product(name: "SwiftProtobuf", package: "swift-protobuf")

let targets: [Target] = [
    .target(
        name: "OcteliumProto",
        dependencies: [swiftProtobuf]
    ),
    .target(
        name: "OcteliumCore",
        dependencies: ["OcteliumProto", swiftProtobuf]
    ),
    .target(
        name: "OcteliumAPI",
        dependencies: [
            "OcteliumProto",
            "OcteliumCore",
            .product(name: "GRPCCore", package: "grpc-swift-2"),
            .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
            .product(
                name: "GRPCNIOTransportHTTP2TransportServices",
                package: "grpc-swift-nio-transport",
                condition: .when(platforms: [.iOS, .macOS])
            ),
            .product(
                name: "GRPCNIOTransportHTTP2Posix",
                package: "grpc-swift-nio-transport",
                condition: .when(platforms: [.linux])
            ),
        ]
    ),
    .systemLibrary(name: "COctelium"),
    .target(
        name: "LibOctelium",
        dependencies: ["COctelium", "OcteliumCore", "OcteliumProto", swiftProtobuf]
    ),
    .testTarget(
        name: "OcteliumCoreTests",
        dependencies: ["OcteliumCore", "OcteliumProto", swiftProtobuf]
    ),
    .testTarget(
        name: "OcteliumAPITests",
        dependencies: [
            "OcteliumAPI",
            "OcteliumCore",
            "OcteliumProto",
            .product(name: "GRPCCore", package: "grpc-swift-2"),
            .product(name: "GRPCInProcessTransport", package: "grpc-swift-2"),
        ]
    ),
]

let package = Package(
    name: "OcteliumKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "OcteliumProto", targets: ["OcteliumProto"]),
        .library(name: "OcteliumCore", targets: ["OcteliumCore"]),
        .library(name: "OcteliumAPI", targets: ["OcteliumAPI"]),
        .library(name: "LibOctelium", targets: ["LibOctelium"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.1"),
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.4.3"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.10.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.4.1"),
    ],
    targets: targets
)
