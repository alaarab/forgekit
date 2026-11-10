// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ForgeKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "ForgeKit", targets: ["ForgeKit"]),
    ],
    targets: [
        .target(name: "ForgeKit"),
        .testTarget(
            name: "ForgeKitTests",
            dependencies: ["ForgeKit"]
        ),
    ]
)
