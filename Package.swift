// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "swift-nostr-client",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .watchOS(.v10),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "NostrClient",
            targets: ["NostrClient"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/GigaBitcoin/secp256k1.swift", from: "0.18.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.2.0"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin.git", from: "1.4.3"),
    ],
    targets: [
        .target(
            name: "NostrClient",
            dependencies: [
                .product(name: "P256K", package: "secp256k1.swift"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(
            name: "NostrClientTests",
            dependencies: ["NostrClient"]
        ),
    ]
)
