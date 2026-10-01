#!/bin/bash
# GH Driver Station 打包：universal .app + ad-hoc 签名 + DMG + SHA256
# 用法：scripts/build-app.sh [版本号，默认 0.1.0]
# 依赖：Xcode（DEVELOPER_DIR 指向完整 Xcode，SPM 宏需要）；打包红线见可行性研究报告 §5.5
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.1.0}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
export DEVELOPER_DIR

APP_NAME="GH Driver Station"
BUNDLE_ID="org.ghfrc.driverstation"
BUILD_DIR=".build/release"
OUT_DIR="dist"
APP="$OUT_DIR/$APP_NAME.app"

echo "▶ 构建 universal release（arm64 + x86_64）"
swift build -c release --arch arm64 --arch x86_64
lipo -info "$BUILD_DIR/GHDS"

echo "▶ 组装 .app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/GHDS" "$APP/Contents/MacOS/"
cp "$BUILD_DIR/GHDSSim" "$APP/Contents/MacOS/"

# Sparkle 框架入 bundle + rpath（应用内更新，报告 §5.5）
if [ ! -d "$BUILD_DIR/Sparkle.framework" ]; then
    echo "  ✗ $BUILD_DIR 下未找到 Sparkle.framework——依赖缺失即失败，不出残缺包" >&2
    exit 1
fi
mkdir -p "$APP/Contents/Frameworks"
cp -R "$BUILD_DIR/Sparkle.framework" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/GHDS"

# 图标（缺失时跳过，不阻塞打包）
if [ ! -f "scripts/AppIcon.iconset/icon_512x512@2x.png" ]; then
  echo "  生成图标…"
  swift scripts/make-icon.swift scripts >/dev/null 2>&1 || echo "  ⚠ 图标生成失败，跳过"
fi
if [ -d "scripts/AppIcon.iconset" ]; then
  iconutil -c icns scripts/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || echo "  ⚠ icns 转换失败，跳过"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>GHDS</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <!-- 控制环 20ms 与看门狗是安全链上的延迟敏感活动：双保险禁用 App Nap
         （运行期另有 ProcessInfo.beginActivity(.latencyCritical)，见 DSModel.start） -->
    <key>NSAppSleepDisabled</key><true/>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>GH Driver Station 需要访问本地网络以连接 roboRIO / SystemCore 机器人（UDP 1110/1150、TCP 1740、mDNS 发现）。机器人连不上时请先在 设置 → 隐私与安全性 → 本地网络 中允许本应用。</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_ni._tcp</string>
        <string>_http._tcp</string>
    </array>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 GH-FRC — Practice Only（第三方 DS 不得用于正式比赛）</string>
    <!-- Sparkle 应用内更新（报告 §5.5）：appcast 托管 GitHub Releases；
         公钥对应私钥 ~/.ghds-release-keys/ghds-ed25519（本机保管，勿入库） -->
    <key>SUFeedURL</key>
    <string>${SU_FEED_URL:-https://github.com/LYT259/ghdriverstation/releases/latest/download/appcast.xml}</string>
    <key>SUPublicEDKey</key>
    <string>${SU_PUBLIC_ED_KEY:-YHHW4wKUsjO8HlZkuZc4vdJWZj4y4ftbiFcEsJkNop4=}</string>
</dict>
</plist>
PLIST

echo "PBPB" > "$APP/Contents/PkgInfo"

# ad-hoc 签名（打包红线：保留有效签名；未公证分发按报告 §5.5 方案 A）
codesign --force --deep -s - "$APP"
# --deep --strict：连同嵌套可执行文件（GHDSSim）一起做资源密封校验；
# 打包红线「签名损坏=只剩 xattr 终端路的死胡同」依赖这道门禁真正兜住嵌套代码
codesign --verify --deep --strict --verbose=2 "$APP" >/dev/null && echo "  ✓ 签名校验通过（deep+strict，含嵌套 GHDSSim）"

echo "▶ 打 DMG"
rm -rf "$OUT_DIR/stage"
mkdir -p "$OUT_DIR/stage"
cp -R "$APP" "$OUT_DIR/stage/"
ln -sf /Applications "$OUT_DIR/stage/Applications"
DMG="$OUT_DIR/GHDS-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$OUT_DIR/stage" -ov -format UDZO "$DMG" | tail -1

echo "▶ SHA256"
(cd "$OUT_DIR" && shasum -a 256 "GHDS-$VERSION.dmg" | tee SHA256SUMS)

echo "✅ 完成：$APP / $DMG"
