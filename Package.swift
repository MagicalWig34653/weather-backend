// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "radar",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "radar", targets: ["radar"])],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.122.3"),
        .package(url: "https://github.com/vapor/mysql-kit.git", from: "4.10.2"),
        .package(url: "https://github.com/tayloraswift/swift-png.git", from: "4.5.2"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.24.0"),
        // Dashboard passkeys (WebAuthn); pinned exactly, pre-release (docs/dashboard-plan.md 2.4).
        .package(url: "https://github.com/swift-server/swift-webauthn.git", exact: "1.0.0-beta.1"),
        // X.509 chain validation for the StoreKit AppTransaction JWS (device link, D14); already part of the resolved graph.
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.0.0"),
    ],
    targets: [
        // libwebp (lossless encoder) from the system: libwebp-dev at build time, libwebp7 at run time.
        .systemLibrary(
            name: "CWebP",
            pkgConfig: "libwebp",
            providers: [.apt(["libwebp-dev"]), .brew(["webp"])]
        ),
        .target(
            name: "RadarCore",
            dependencies: [
                "CWebP",
                .product(name: "PNG", package: "swift-png"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "MySQLKit", package: "mysql-kit"),
                .product(name: "WebAuthn", package: "swift-webauthn"),
                .product(name: "X509", package: "swift-certificates"),
            ]
        ),
        .executableTarget(
            name: "radar",
            dependencies: [
                "RadarCore",
                .product(name: "Vapor", package: "vapor"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
            ]
        ),
        .testTarget(
            name: "RadarCoreTests",
            dependencies: [
                "RadarCore", "radar", .product(name: "PNG", package: "swift-png"),
                .product(name: "XCTVapor", package: "vapor"),
                .product(name: "X509", package: "swift-certificates"), .product(name: "SwiftASN1", package: "swift-asn1"),
            ],
            exclude: ["Fixtures"]
        ),
    ]
)
