// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WalkieCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "WalkieCore", targets: ["WalkieCore"])],
    targets: [
        .target(name: "WalkieCore"),
        .testTarget(name: "WalkieCoreTests", dependencies: ["WalkieCore"])
    ],
    swiftLanguageVersions: [.v5]
)
