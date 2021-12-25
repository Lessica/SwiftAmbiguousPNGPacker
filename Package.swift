// swift-tools-version:5.5
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftAmbiguousPNGPacker",
    platforms: [.macOS(.v11), .iOS(.v14)], 
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "SwiftAmbiguousPNGPacker",
            targets: ["SwiftAmbiguousPNGPacker"]
        ),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url */, from: "1.0.0"),
        .package(url: "https://github.com/Lessica/compress-nio.git", branch: "ambiguous-png"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.36.0"),
        .package(url: "https://github.com/mw99/DataCompression.git", from: "3.6.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "SwiftAmbiguousPNGPacker",
            dependencies: [
                .product(name: "CompressNIO", package: "compress-nio"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "DataCompression", package: "DataCompression"),
            ]
        ),
        .testTarget(
            name: "SwiftAmbiguousPNGPackerTests",
            dependencies: ["SwiftAmbiguousPNGPacker"],
            resources: [
                .copy("Fixtures")
            ]
        ),
    ]
)
