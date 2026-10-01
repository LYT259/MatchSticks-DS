#!/bin/bash
# Dry app-state regression tests; no network or simulator startup.
# Builds DSCore from source into its own dylib+swiftmodule, then compiles the
# app layer and tests against them — independent of SPM's build layout, which
# differs between the Xcode and native toolchains (CI runners).
set -euo pipefail
cd "$(dirname "$0")/.."
# 本机默认 Xcode-beta；CI 等环境沿用系统默认工具链
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode-beta.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi
swift build   # 先确认主工程可构建（与 CI 其余步骤一致的常规门禁）
mkdir -p .build/uitest
swiftc -swift-version 5 -emit-library -emit-module -module-name DSCore \
  -emit-module-path .build/uitest/DSCore.swiftmodule \
  Sources/DSCore/*.swift -o .build/uitest/libDSCore.dylib
swiftc -parse-as-library -swift-version 5 \
  -I .build/uitest -L .build/uitest -lDSCore \
  Sources/GHDS/DSModel.swift Sources/GHDS/HIDInputManager.swift \
  Sources/GHDS/MacStatusMonitor.swift Sources/GHDS/Views/DSStyle.swift \
  Sources/GHDS/UpdateFlow.swift \
  Tests/GHDSUITests/main.swift -o .build/GHDSUIStateTests
.build/GHDSUIStateTests
