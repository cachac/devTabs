// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "devTabs",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "devTabs", targets: ["devTabs"]),
    ],
    targets: [
        .target(name: "DevTabsCore"),
        .executableTarget(name: "devTabs", dependencies: ["DevTabsCore"]),
        .testTarget(name: "DevTabsCoreTests", dependencies: ["DevTabsCore"]),
    ],
    swiftLanguageModes: [.v5]
)
