// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScrubKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "ScrubKit", targets: ["ScrubKit"]),
        .executable(name: "scrub", targets: ["scrub"]),
    ],
    targets: [
        .target(name: "ScrubKit"),
        .executableTarget(name: "scrub", dependencies: ["ScrubKit"]),
        .testTarget(name: "ScrubKitTests", dependencies: ["ScrubKit"]),
    ],
    swiftLanguageModes: [.v5]
)
