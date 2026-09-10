#!/bin/bash
# Regenerates CoachMe.xcodeproj and installs the pods, then downgrades both
# project files to a format Xcode 15.x can open.
#
# WHY THE DOWNGRADE: XcodeGen 2.45 and CocoaPods 1.16 both write
# `objectVersion = 77`, the Xcode 16 project format. Xcode 15.4 refuses it with
#     "The project cannot be opened because it is in a future Xcode project
#      file format (77)."
# Neither generator exposes a working knob for this (XcodeGen ignores an
# `objectVersion` spec option; `installer.pods_project.object_version=` does not
# exist on CocoaPods' Project). Rewriting the field is safe here because neither
# project uses any format-77-only feature -- checked for
# PBXFileSystemSynchronizedRootGroup, zero occurrences in both files.
#
# Delete this script once the project moves to Xcode 16+.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

: "${DEVELOPER_DIR:=}"
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

xcodegen generate
pod install

for f in CoachMe.xcodeproj/project.pbxproj Pods/Pods.xcodeproj/project.pbxproj; do
  if grep -q "PBXFileSystemSynchronizedRootGroup" "$f"; then
    echo "ERROR: $f uses a format-77-only feature; downgrading would corrupt it." >&2
    exit 1
  fi
  sed -i '' 's/objectVersion = 77;/objectVersion = 56;/' "$f"
  echo "  downgraded $f -> objectVersion 56"
done

echo "Done. Open CoachMe.xcworkspace (not the .xcodeproj)."
