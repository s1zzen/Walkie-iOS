// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FieldLabCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "FieldLabCore", targets: ["FieldLabCore"])],
    targets: [
        .target(name: "FieldLabCore", path: "Sources/Core"),
        .testTarget(name: "FieldLabCoreTests", dependencies: ["FieldLabCore"], path: "Tests/FieldLabCoreTests")
    ],
    swiftLanguageVersions: [.v5]
)
