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
            name: "NostrCore",
            targets: ["NostrCore"]
        ),
        .library(
            name: "NostrClient",
            targets: ["NostrClient"]
        ),
        .library(
            name: "NostrWalletConnect",
            targets: ["NostrWalletConnect"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1", from: "0.23.2"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.2.0"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin.git", from: "1.4.3"),
    ],
    targets: [
        .target(
            name: "NostrCore",
            dependencies: [
                .product(name: "P256K", package: "swift-secp256k1"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "NostrClient",
            dependencies: [
                "NostrCore",
                .product(name: "P256K", package: "swift-secp256k1"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "NostrWalletConnect",
            dependencies: [
                "NostrClient",
                "NostrCore",
                .product(name: "P256K", package: "swift-secp256k1"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ]
        ),
        .testTarget(
            name: "NostrCoreTests",
            dependencies: ["NostrCore"]
        ),
        .testTarget(
            name: "NostrClientTests",
            dependencies: ["NostrClient", "NostrCore"]
        ),
        .testTarget(
            name: "NostrWalletConnectTests",
            dependencies: ["NostrWalletConnect", "NostrCore"]
        ),
    ]
)
