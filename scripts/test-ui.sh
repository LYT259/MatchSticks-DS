#!/bin/bash
# Dry app-state regression tests; no network or simulator startup.
set -euo pipefail
cd "$(dirname "$0")/.."
# 本机默认 Xcode-beta；CI 等环境沿用系统默认工具链
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode-beta.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi
swift build
UI_BUILD_DIR="$(swift build --show-bin-path)"
swiftc -parse-as-library -swift-version 5 \
  -I "$UI_BUILD_DIR" "$UI_BUILD_DIR/DSCore.o" \
  Sources/GHDS/DSModel.swift Sources/GHDS/HIDInputManager.swift \
  Sources/GHDS/MacStatusMonitor.swift Sources/GHDS/Views/DSStyle.swift \
  Tests/GHDSUITests/main.swift -o .build/GHDSUIStateTests
.build/GHDSUIStateTests
