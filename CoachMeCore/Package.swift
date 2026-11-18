// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CoachMeCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "CoachMeCore",
                 targets: ["Model", "PoseDetection", "PhaseSegmentation", "Diagnosis", "AICoach", "Avatar",
                           "AppPolicy", "Beta"])
    ],
    targets: [
        .target(name: "Model"),
        .target(name: "AppPolicy"),
        .target(name: "PoseDetection", dependencies: ["Model"]),
        .target(name: "PhaseSegmentation", dependencies: ["Model"]),
        .target(name: "Diagnosis", dependencies: ["Model"]),
        .target(name: "AICoach", dependencies: ["Model", "Diagnosis", "AppPolicy"]),
        .target(name: "Avatar", dependencies: ["Model"]),
        .target(name: "Beta", dependencies: ["Model", "Diagnosis"]),
        .testTarget(name: "ModelTests", dependencies: ["Model", "Diagnosis"]),
        .testTarget(name: "PoseDetectionTests", dependencies: ["PoseDetection"]),
        .testTarget(name: "PhaseSegmentationTests", dependencies: ["PhaseSegmentation"]),
        .testTarget(name: "DiagnosisTests", dependencies: ["Diagnosis"]),
        .testTarget(name: "AICoachTests", dependencies: ["AICoach"]),
        .testTarget(name: "AvatarTests", dependencies: ["Avatar"]),
        .testTarget(name: "BetaTests", dependencies: ["Beta", "AppPolicy", "AICoach"])
    ]
)
