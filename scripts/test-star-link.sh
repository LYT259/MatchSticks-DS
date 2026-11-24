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
  Sources/MatchSticksDS/DSModel.swift
  Sources/MatchSticksDS/LocalNetworkDiscovery.swift
  Sources/MatchSticksDS/HIDInputManager.swift
  Sources/MatchSticksDS/MacStatusMonitor.swift
  Sources/MatchSticksDS/Views/DSStyle.swift
  Sources/MatchSticksDS/Views/DSControls.swift
  Sources/MatchSticksDS/PracticeAudioPlayer.swift
  Sources/MatchSticksDS/PracticeCountdownSpeech.swift
  Sources/MatchSticksDS/UpdateFlow.swift
  Sources/MatchSticksDS/MainWindowDoubleClick.swift
  Sources/MatchSticksDS/Shortcuts.swift
  Sources/MatchSticksDS/XInputUSB/F310XInputReport.swift
  Sources/MatchSticksDS/XInputUSB/F310XInputLifecycle.swift
  Sources/MatchSticksDS/XInputUSB/F310XInputManager.swift
  Sources/MatchSticksDS/GamepadInputManager.swift
  Sources/MatchSticksDS/Views/GamepadArtwork/GamepadArtwork.swift
  Sources/MatchSticksDS/Views/GamepadArtwork/GamepadArtworkOverlay.swift
  Sources/MatchSticksDS/Views/GamepadSkinView.swift
  Sources/MatchSticksDS/AppIconAppearance.swift
  Sources/MatchSticksDS/Views/GitHubStarButton.swift
)
if [ -f Sources/MatchSticksDS/UpdateChannel.swift ]; then
  app_sources+=(Sources/MatchSticksDS/UpdateChannel.swift)
else
  echo "Integration checklist: merge feat/auto-update-channels, then rerun test-star-link.sh to compile Sources/MatchSticksDS/UpdateChannel.swift."
fi

swiftc -parse-as-library -swift-version 5 \
  -I "$BUILD_DIR" -L "$BUILD_DIR" -lDSCore \
  "${app_sources[@]}" \
  "$BUILD_DIR/BundleModuleShim.swift" \
  Tests/MatchSticksDSUITests/GitHubStarButtonTests.swift \
  -o "$BUILD_DIR/GitHubStarButtonTests"
"$BUILD_DIR/GitHubStarButtonTests"
