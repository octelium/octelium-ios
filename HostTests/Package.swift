// swift-tools-version: 6.0

import Foundation
import PackageDescription

let hostLibDir = ProcessInfo.processInfo.environment["OCTELIUM_HOST_LIB_DIR"]
    ?? URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("build/host-libs")
    .path

let package = Package(
    name: "HostTests",
    platforms: [
        .macOS(.v15),
    ],
    dependencies: [
        .package(path: "../OcteliumKit"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.1"),
    ],
    targets: [
        .testTarget(
            name: "LibOcteliumTests",
            dependencies: [
                .product(name: "LibOctelium", package: "OcteliumKit"),
                .product(name: "OcteliumCore", package: "OcteliumKit"),
                .product(name: "OcteliumProto", package: "OcteliumKit"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            linkerSettings: [
                .unsafeFlags(["-L\(hostLibDir)"]),
                .linkedLibrary("octelium"),
                .linkedLibrary("resolv", .when(platforms: [.macOS])),
                .linkedFramework("CoreFoundation", .when(platforms: [.macOS])),
                .linkedFramework("Security", .when(platforms: [.macOS])),
            ]
        ),
    ]
)
