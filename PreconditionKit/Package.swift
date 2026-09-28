// swift-tools-version:5.9
import PackageDescription

// The app's platform-free core (HANDOVER.md §2): no UIKit, SwiftUI or CoreLocation, so the whole
// decision path can be tested with plain XCTest, on a Mac or on Linux.
let package = Package(
    name: "PreconditionKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PreconditionKit", targets: ["PreconditionKit"]),
    ],
    targets: [
        .target(name: "PreconditionKit"),
        .testTarget(name: "PreconditionKitTests", dependencies: ["PreconditionKit"]),
    ]
)
