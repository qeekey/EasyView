// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "EasyView",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "EasyView", targets: ["EasyView"])
    ],
    targets: [
        .executableTarget(
            name: "EasyView",
            path: "Sources/EasyView"
        )
    ]
)
