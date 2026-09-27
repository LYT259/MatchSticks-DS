#!/bin/bash
# Dry app-state regression tests; no network or simulator startup.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
swift build
UI_BUILD_DIR="$(swift build --show-bin-path)"
swiftc -parse-as-library -swift-version 5 \
  -I "$UI_BUILD_DIR" "$UI_BUILD_DIR/DSCore.o" \
  Sources/GHDS/DSModel.swift Sources/GHDS/HIDInputManager.swift \
  Sources/GHDS/MacStatusMonitor.swift Sources/GHDS/Views/DSStyle.swift \
  Tests/GHDSUITests/main.swift -o .build/GHDSUIStateTests
.build/GHDSUIStateTests
