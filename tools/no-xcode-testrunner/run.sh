#!/bin/bash
# Runs CoachMeCore's XCTest suite WITHOUT Xcode.
#
# `swift test` needs XCTest, which ships with Xcode, not with the Command Line
# Tools. This script compiles the real test files against a minimal XCTest
# shim plus a generated runner, so the assertions execute unmodified.
#
# It is a stopgap for machines with CLT only. Once Xcode is installed, use
# `swift test` (or the Xcode test action) instead -- that is the real thing.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
core="$here/../../CoachMeCore"
build="$here/.scratch"

rm -rf "$build"
mkdir -p "$build/Sources/XCTest" "$build/Sources/RunTests"
cp "$here/XCTestShim.swift" "$build/Sources/XCTest/XCTest.swift"
cp "$core/Tests/CoachMeCoreTests/"*.swift "$build/Sources/RunTests/"

cat > "$build/Package.swift" <<'EOF'
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NoXcodeTestRunner",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "CORE_PATH")],
    targets: [
        .target(name: "XCTest"),
        .executableTarget(name: "RunTests", dependencies: [
            "XCTest",
            .product(name: "CoachMeCore", package: "CoachMeCore")
        ])
    ]
)
EOF
sed -i '' "s|CORE_PATH|$core|" "$build/Package.swift"

python3 "$here/generate_runner.py" "$build/Sources/RunTests"
cd "$build" && swift run RunTests 2>&1 | grep -v "xcrun:\|could not determine XCTest\|^Building for\|^\[[0-9]"
