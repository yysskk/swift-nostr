// swift-tools-version: 6.3
import PackageDescription

// SE-0335: require the `any` keyword for existential types. The code base
// already conforms; enabling the upcoming feature on every target keeps new
// code from drifting until the syntax becomes the language default.
let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny")
]

let package = Package(
    name: "swift-nostr",
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
        .library(
            name: "NostrConnect",
            targets: ["NostrConnect"]
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
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "NostrClient",
            dependencies: [
                "NostrCore",
                .product(name: "P256K", package: "swift-secp256k1"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "NostrWalletConnect",
            dependencies: [
                "NostrCore",
                .product(name: "P256K", package: "swift-secp256k1"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "NostrConnect",
            dependencies: [
                "NostrCore"
            ],
            swiftSettings: swiftSettings
        ),
        // Test-only doubles shared by the test targets. Deliberately not a product: nothing
        // outside this package's tests depends on it, so it never reaches library consumers.
        .target(
            name: "NostrTestSupport",
            dependencies: ["NostrCore"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "NostrCoreTests",
            dependencies: ["NostrCore"],
            // `.copy` rather than `.process` so the official NIP-44 vectors are bundled byte for
            // byte and stay verifiable against their published checksum.
            resources: [
                .copy("Resources/nip44.vectors.json")
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "NostrClientTests",
            dependencies: ["NostrClient", "NostrCore", "NostrTestSupport"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "NostrWalletConnectTests",
            dependencies: ["NostrWalletConnect", "NostrCore"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "NostrConnectTests",
            dependencies: ["NostrConnect", "NostrCore"],
            swiftSettings: swiftSettings
        ),
    ]
)
