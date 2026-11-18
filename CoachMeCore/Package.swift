// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CoachMeCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "CoachMeCore", targets: ["CoachMeCore"])
    ],
    targets: [
        // Deliberately dependency-free: no SwiftUI, no AVFoundation, no MediaPipe.
        // That is what lets the metric and rule logic be unit-tested without a
        // device, and what lets the pose SDK be swapped later.
        .target(name: "CoachMeCore"),
        .testTarget(name: "CoachMeCoreTests", dependencies: ["CoachMeCore"])
    ]
)
