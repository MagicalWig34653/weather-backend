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
            dependencies: ["RadarCore", .product(name: "PNG", package: "swift-png")],
            exclude: ["Fixtures"]
        ),
    ]
)
