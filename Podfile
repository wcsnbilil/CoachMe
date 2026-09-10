# CoachMe — CocoaPods dependencies.
#
# MediaPipeTasksVision is distributed through CocoaPods only. The official iOS
# guide for Pose Landmarker lists no Swift Package Manager option:
#   https://developers.google.com/edge/mediapipe/solutions/vision/pose_landmarker/ios
#
# VERSION IS PINNED ON PURPOSE.
# google-ai-edge/mediapipe issue #6258 reports that the XCFramework layout in
# 0.10.33+ does not match the podspec, which breaks linking. 0.10.21 is the last
# version reported working there. Do not bump this without building on a device
# and re-running the analysis end to end.
#   https://github.com/google-ai-edge/mediapipe/issues/6258
#
# Run `pod install` AFTER `xcodegen generate`, then open CoachMe.xcworkspace.

platform :ios, '17.0'
use_frameworks!

target 'CoachMe' do
  pod 'MediaPipeTasksVision', '0.10.21'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      # Pods must not undercut the app's deployment target.
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
      # MediaPipe ships without module-level Swift concurrency annotations.
      config.build_settings['SWIFT_STRICT_CONCURRENCY'] = 'minimal'
    end
  end
end
