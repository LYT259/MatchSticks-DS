#!/bin/bash
# GitHub Star link regression: hosted-button test with an injected opener only.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

BUILD_DIR=".build/star-link-test"
trap 'rm -rf "$BUILD_DIR"' EXIT
mkdir -p "$BUILD_DIR"
cat > "$BUILD_DIR/BundleModuleShim.swift" <<'EOF'
import Foundation
extension Bundle { static let module = Bundle.main }
EOF

swiftc -swift-version 5 -emit-library -emit-module -module-name DSCore \
  -emit-module-path "$BUILD_DIR/DSCore.swiftmodule" \
  Sources/DSCore/*.swift "$BUILD_DIR/BundleModuleShim.swift" \
  -o "$BUILD_DIR/libDSCore.dylib"
app_sources=(
  Sources/MatchSticksDriverStaion/DSModel.swift
  Sources/MatchSticksDriverStaion/LocalNetworkDiscovery.swift
  Sources/MatchSticksDriverStaion/HIDInputManager.swift
  Sources/MatchSticksDriverStaion/MacStatusMonitor.swift
  Sources/MatchSticksDriverStaion/PermissionRuntimeMonitor.swift
  Sources/MatchSticksDriverStaion/FirewallVerificationProbe.swift
  Sources/MatchSticksDriverStaion/Views/PermissionsView.swift
  Sources/MatchSticksDriverStaion/Views/DSStyle.swift
  Sources/MatchSticksDriverStaion/Views/DSControls.swift
  Sources/MatchSticksDriverStaion/PracticeAudioPlayer.swift
  Sources/MatchSticksDriverStaion/PracticeCountdownSpeech.swift
  Sources/MatchSticksDriverStaion/UpdateFlow.swift
  Sources/MatchSticksDriverStaion/MainWindowDoubleClick.swift
  Sources/MatchSticksDriverStaion/Shortcuts.swift
  Sources/MatchSticksDriverStaion/XInputUSB/F310XInputReport.swift
  Sources/MatchSticksDriverStaion/XInputUSB/F310XInputLifecycle.swift
  Sources/MatchSticksDriverStaion/XInputUSB/F310XInputManager.swift
  Sources/MatchSticksDriverStaion/GamepadInputManager.swift
  Sources/MatchSticksDriverStaion/Views/GamepadArtwork/ThumbstickMotion.swift
  Sources/MatchSticksDriverStaion/Views/GamepadArtwork/ThumbstickSceneView.swift
  Sources/MatchSticksDriverStaion/Views/GamepadArtwork/ArtworkContour.swift
  Sources/MatchSticksDriverStaion/Views/GamepadArtwork/FlightStickSceneView.swift
  Sources/MatchSticksDriverStaion/Views/GamepadArtwork/GamepadArtwork.swift
  Sources/MatchSticksDriverStaion/Views/GamepadArtwork/GamepadArtworkOverlay.swift
  Sources/MatchSticksDriverStaion/Views/GamepadSkinView.swift
  Sources/MatchSticksDriverStaion/AppIconAppearance.swift
  Sources/MatchSticksDriverStaion/Views/GitHubStarButton.swift
)
if [ -f Sources/MatchSticksDriverStaion/UpdateChannel.swift ]; then
  app_sources+=(Sources/MatchSticksDriverStaion/UpdateChannel.swift)
else
  echo "Integration checklist: merge feat/auto-update-channels, then rerun test-star-link.sh to compile Sources/MatchSticksDriverStaion/UpdateChannel.swift."
fi

swiftc -parse-as-library -swift-version 5 \
  -I "$BUILD_DIR" -L "$BUILD_DIR" -lDSCore \
  "${app_sources[@]}" \
  "$BUILD_DIR/BundleModuleShim.swift" \
  Tests/MatchSticksDriverStaionUITests/GitHubStarButtonTests.swift \
  -o "$BUILD_DIR/GitHubStarButtonTests"
"$BUILD_DIR/GitHubStarButtonTests"
