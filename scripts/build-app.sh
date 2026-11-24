#!/bin/bash
# MatchSticks Driver Station 打包：universal .app + ad-hoc 签名 + DMG + SHA256
# 用法：scripts/build-app.sh [版本号，默认 0.1.0]
# 依赖：Xcode（DEVELOPER_DIR 指向完整 Xcode，SPM 宏需要）；打包红线见可行性研究报告 §5.5
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.1.0}"
# SwiftUI 宏需要完整 Xcode：优先环境变量，其次探测 Xcode-beta / Xcode（本机装了哪个用哪个）
if [ -z "${DEVELOPER_DIR:-}" ]; then
    for CAND in /Applications/Xcode-beta.app /Applications/Xcode.app; do
        [ -d "$CAND" ] && DEVELOPER_DIR="$CAND/Contents/Developer" && break
    done
fi
export DEVELOPER_DIR

APP_NAME="MatchSticks Driver Station"
# 兼容例外：生产 bundle ID 不随产品改名变化（设置域、Sparkle 身份与用户数据都挂在它上面）
BUNDLE_ID="org.ghfrc.driverstation"
BUILD_DIR=".build/release"
OUT_DIR="dist"
APP="$OUT_DIR/$APP_NAME.app"

echo "▶ 构建 universal release（arm64 + x86_64）"
swift build -c release --arch arm64 --arch x86_64
lipo -info "$BUILD_DIR/MatchSticksDriverStaion"

echo "▶ 组装 .app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/MatchSticksDriverStaion" "$APP/Contents/MacOS/"
cp "$BUILD_DIR/MatchSticksDriverStaionSim" "$APP/Contents/MacOS/"

# Sparkle 框架入 bundle + rpath（应用内更新，报告 §5.5）
if [ ! -d "$BUILD_DIR/Sparkle.framework" ]; then
    echo "  ✗ $BUILD_DIR 下未找到 Sparkle.framework——依赖缺失即失败，不出残缺包" >&2
    exit 1
fi
mkdir -p "$APP/Contents/Frameworks"
cp -R "$BUILD_DIR/Sparkle.framework" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/MatchSticksDriverStaion"

# 中英双语资源：SPM 资源 bundle（en.lproj 双语表所在）须进 Contents/Resources，
# Bundle.module 才能在打包 app 内解析；缺失即失败——不出「英文系统却只有中文界面」的残缺包
if [ ! -d "$BUILD_DIR/MatchSticksDriverStaion_DSCore.bundle" ]; then
    echo "  ✗ $BUILD_DIR 下未找到 MatchSticksDriverStaion_DSCore.bundle——双语表缺失即失败" >&2
    exit 1
fi
cp -R "$BUILD_DIR/MatchSticksDriverStaion_DSCore.bundle" "$APP/Contents/Resources/"

# 应用音频与手柄实机图片必须随包分发；缺失即失败，避免安全事件无声或外观缺失
if [ ! -d "$BUILD_DIR/MatchSticksDriverStaion_MatchSticksDriverStaion.bundle" ]; then
    echo "  ✗ $BUILD_DIR 下未找到 MatchSticksDriverStaion_MatchSticksDriverStaion.bundle——应用音频或手柄图片缺失" >&2
    exit 1
fi
cp -R "$BUILD_DIR/MatchSticksDriverStaion_MatchSticksDriverStaion.bundle" "$APP/Contents/Resources/"
RESOURCE_DIR="$APP/Contents/Resources/MatchSticksDriverStaion_MatchSticksDriverStaion.bundle/Contents/Resources"
for REQUIRED in FOGHORN.wav ArtworkCredits.txt dualsense.png dualshock4.png xbox-series.png f310.png direwolf4.png \
    extreme3dpro.png extreme3dpro-base.png extreme3dpro-handle.png; do
    if [ ! -f "$RESOURCE_DIR/$REQUIRED" ]; then
        echo "  ✗ 应用资源缺失：$REQUIRED" >&2
        exit 1
    fi
done

# ── 图标链：全部图标必须来自用户原稿 Sources/.../AppIcons（淘汰程序绘制图标）；
#    任何缺失/失败都阻断打包——不出无图标包，更不出残留旧图标的包。注入先于 codesign ──
echo "▶ 图标：iconset → AppIcon.icns + actool Assets.car（浅/深外观）"
ICON_SRC_DIR="Sources/MatchSticksDriverStaion/Resources/AppIcons"
# 四张白名单原稿缺一不可：day/night 供 bundle 图标（icns + Assets.car），
# mono-day/mono-night 供应用内单色变体。损坏（非图片内容/非 1024×1024）同样阻断——
# sips 对损坏文件不报错，但尺寸输出为 <nil>，因此必须比对解析值而非退出码
for ICON_SRC in app-icon-day.png app-icon-night.png app-icon-mono-day.png app-icon-mono-night.png; do
  if [ ! -f "$ICON_SRC_DIR/$ICON_SRC" ]; then
    echo "  ✗ 图标原稿缺失：$ICON_SRC_DIR/$ICON_SRC" >&2
    exit 1
  fi
  DIMS="$(sips -g pixelWidth -g pixelHeight "$ICON_SRC_DIR/$ICON_SRC" 2>/dev/null | awk '/^  pixel(Width|Height):/ {print $2}' | paste -sd 'x' -)"
  if [ "$DIMS" != "1024x1024" ]; then
    echo "  ✗ 图标原稿损坏或非 1024×1024：$ICON_SRC_DIR/$ICON_SRC（实际：${DIMS:-不可解码}）" >&2
    exit 1
  fi
done

# 1) 10 尺寸 iconset（每次全量重建，不跳过）→ AppIcon.icns（传统 CFBundleIconFile 兼容）
swift scripts/make-icon.swift scripts || { echo "  ✗ iconset 生成失败（见上）" >&2; exit 1; }
for ICON_FILE in icon_16x16.png icon_16x16@2x.png icon_32x32.png icon_32x32@2x.png \
                 icon_128x128.png icon_128x128@2x.png icon_256x256.png icon_256x256@2x.png \
                 icon_512x512.png icon_512x512@2x.png; do
  if [ ! -s "scripts/AppIcon.iconset/$ICON_FILE" ]; then
    echo "  ✗ iconset 不完整：缺 $ICON_FILE" >&2
    exit 1
  fi
done
iconutil -c icns scripts/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns" \
  || { echo "  ✗ iconutil 转 icns 失败" >&2; exit 1; }
if [ ! -s "$APP/Contents/Resources/AppIcon.icns" ]; then
  echo "  ✗ AppIcon.icns 未产出" >&2
  exit 1
fi

# 2) Icon Composer 图标包（.build 下临时组装，全幅输入由仓库图稿派生，不重复入库）→
#    actool 编译 Assets.car：浅色 Aqua + 深色 DarkAqua，macOS 按 CFBundleIconName 优先
#    选它做外观切换。深色变体用「双层 + hidden-specializations」结构（day 层 dark 时
#    隐藏、night 层 light 时隐藏）——本机实测（Xcode 27.2 / 27B52，矩阵实验存档
#    .build/icon-test/matrix）：actool 会静默丢弃 image-name-specializations 的
#    dark→night 替换（PathBlender 参考包同车翻车，car 里只剩日间图像素），双层结构
#    是唯一能让两张原图都真实编入且按外观翻转的写法。其余要点沿用 PathBlender 实测：
#    glass:false 禁 Liquid Glass、组级 shadow 键整体省略（kind:"none" 会让 actool
#    静默零产出）、translucency 置 false——不改变用户图稿、不加边圈
# ICON_WORK 必须是绝对路径：actool 经 XPC 守护进程执行，相对 --compile 路径按守护进程
# 自身 cwd（可能是别的 worktree）解析——会把产物写进别处、本地零 Assets.car
ICON_WORK="$PWD/.build/icon-work"
rm -rf "$ICON_WORK"
ICON_PKG="$ICON_WORK/AppIcon.icon"
mkdir -p "$ICON_PKG/Assets" "$ICON_WORK/actool-out"
# FULLBLEED-SEGMENT-START：Icon Composer 输入必须全幅无透明边距（test-icon-gate.sh G3 抽取本段）
# 仓库图稿是 824 参考轮廓的圆角稿；带透明边距/圆角的图稿直接编译，系统底板会从透明区
# 透出——Stage Manager/侧边白圈（用户 2026-11 实测）。先派生全幅日/夜间输入（824 底板
# 等比放大满幅、四角填底板色、内部图形比例与背景色不变），系统负责最终原生圆角/尺寸。
swift scripts/calibrate-icon.swift full-bleed --out "$ICON_WORK/fullbleed" \
  || { echo "  ✗ Icon Composer 全幅输入生成失败（见上）" >&2; exit 1; }
for FB_NAME in icon-day.png icon-night.png; do
  if [ ! -s "$ICON_WORK/fullbleed/$FB_NAME" ]; then
    echo "  ✗ 全幅输入缺失：$ICON_WORK/fullbleed/$FB_NAME" >&2
    exit 1
  fi
done
# PNG 一律 cat 重定向新写（不用 cp）：图稿带下载隔离属性（com.apple.quarantine）时，
# cp 的 clonefile 拷贝会让本机 actool 的 IconStudio 导出间歇性报「image does not
# exist」（实测对照各 3 次：cp 失败 / cat 新写稳定）
cat "$ICON_WORK/fullbleed/icon-day.png"   > "$ICON_PKG/Assets/icon-day.png"
cat "$ICON_WORK/fullbleed/icon-night.png" > "$ICON_PKG/Assets/icon-night.png"
cat > "$ICON_PKG/icon.json" <<'ICONJSON'
{
  "groups": [
    {
      "layers": [
        {
          "blend-mode": "normal",
          "fill": "none",
          "glass": false,
          "image-name": "icon-day.png",
          "hidden-specializations": [
            {
              "appearance": "dark",
              "value": true
            }
          ]
        },
        {
          "blend-mode": "normal",
          "fill": "none",
          "glass": false,
          "image-name": "icon-night.png",
          "hidden-specializations": [
            {
              "appearance": "light",
              "value": true
            }
          ]
        }
      ],
      "translucency": {
        "enabled": false,
        "value": 0.2
      }
    }
  ],
  "supported-platforms": {
    "circles": [
      "watchOS"
    ],
    "squares": "shared"
  }
}
ICONJSON

ACTOOL="$(xcrun --find actool 2>/dev/null)" || ACTOOL=""
if [ -z "$ACTOOL" ]; then
  echo "  ✗ 找不到 actool——Assets.car 编译需要完整 Xcode（仅 Command Line Tools 不够）" >&2
  exit 1
fi
if ! "$ACTOOL" "$ICON_PKG" --app-icon AppIcon \
    --compile "$ICON_WORK/actool-out" \
    --output-partial-info-plist "$ICON_WORK/actool-out/partial.plist" \
    --minimum-deployment-target 14.0 --platform macosx --target-device mac \
    >"$ICON_WORK/actool.log" 2>&1; then
  echo "  ✗ actool 编译图标目录失败：" >&2
  tail -20 "$ICON_WORK/actool.log" >&2
  exit 1
fi
if [ ! -s "$ICON_WORK/actool-out/Assets.car" ]; then
  echo "  ✗ actool 未产出 Assets.car（icon.json 配置错误会静默零产出）：" >&2
  tail -20 "$ICON_WORK/actool.log" >&2
  exit 1
fi

# 硬检查：深色变体必须「真实存在且方向正确」。只比 Aqua/DarkAqua digest 差异不够——
# 日夜倒置（浅色显示夜图）同样 digest 不同，会假绿；必须按 car 实际输出的可见层
# 断言：Aqua=AppIcon_Assets/icon-day、DarkAqua=AppIcon_Assets/icon-night，
# 并保留 digest 不同与双 1024 像素载荷断言。car 结构里的 DarkAqua 条目在纯日间
# car 上同样存在，grep 计数不能作证据
if [ ! -x /usr/bin/python3 ]; then
  echo "  ✗ 需要 /usr/bin/python3 做 Assets.car 深色变体硬检查" >&2
  exit 1
fi
ASSETUTIL="$(xcrun --find assetutil 2>/dev/null)" || ASSETUTIL="/usr/bin/assetutil"
if ! "$ASSETUTIL" --info "$ICON_WORK/actool-out/Assets.car" 2>/dev/null | /usr/bin/python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("  ✗ assetutil 无法解析 Assets.car", file=sys.stderr); sys.exit(1)
def visible_layer(group):
    layers = [l for l in (group.get("Layers") or [])
              if l.get("AssetType") in (None, "Image") and l.get("LayerOpacity", 1) >= 1]
    return layers[0] if layers else None
aqua = dark = None
images = set()
for e in d:
    if e.get("AssetType") == "Image" and e.get("PixelWidth") == 1024:
        images.add(e.get("SHA1Digest"))
    if e.get("AssetType") == "IconGroup":
        v = visible_layer(e)
        if e.get("Appearance") == "NSAppearanceNameAqua": aqua = v
        if e.get("Appearance") == "NSAppearanceNameDarkAqua": dark = v
def name(x): return x.get("Name") if x else None
def sha(x): return str(x.get("SHA1Digest"))[:12] if x else None
ok = (aqua and dark
      and name(aqua) == "AppIcon_Assets/icon-day"
      and name(dark) == "AppIcon_Assets/icon-night"
      and aqua.get("SHA1Digest") != dark.get("SHA1Digest")
      and len(images) >= 2)
if ok:
    sys.exit(0)
print(f"  ✗ Assets.car 深色变体未正确编入（Aqua 可见层={name(aqua)}/{sha(aqua)} "
      f"DarkAqua 可见层={name(dark)}/{sha(dark)} 1024 像素载荷={len(images)}；"
      f"要求 Aqua=AppIcon_Assets/icon-day、DarkAqua=AppIcon_Assets/icon-night 且 digest 不同）",
      file=sys.stderr)
sys.exit(1)
'; then
  exit 1
fi
cp "$ICON_WORK/actool-out/Assets.car" "$APP/Contents/Resources/Assets.car"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>MatchSticksDriverStaion</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <!-- 控制环 20ms 与看门狗是安全链上的延迟敏感活动：双保险禁用 App Nap
         （运行期另有 ProcessInfo.beginActivity(.latencyCritical)，见 DSModel.start） -->
    <key>NSAppSleepDisabled</key><true/>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <!-- macOS 优先按名字取 Assets.car 里的 AppIcon iconstack（浅/深外观自动切换，见上方 actool 段）；
         icns 仅作旧路径兜底，两者同名 AppIcon -->
    <key>CFBundleIconName</key><string>AppIcon</string>
    <!-- 双语：开发区域 en（非中英系统回退英文）；Localizations 声明供系统与 Sparkle 识别 -->
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>zh-Hans</string>
    </array>
    <key>NSLocalNetworkUsageDescription</key>
    <string>MatchSticks Driver Station 需要访问本地网络以连接 roboRIO / SystemCore 机器人（UDP 1110/1150、TCP 1740、mDNS 发现）。机器人连不上时请先在 设置 → 隐私与安全性 → 本地网络 中允许本应用。</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_ni._tcp</string>
        <string>_http._tcp</string>
    </array>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 GH-FRC — Practice Only（第三方 DS 不得用于正式比赛）</string>
    <!-- Sparkle 应用内更新（报告 §5.5）：appcast 托管 GitHub Releases；
         公钥对应私钥 ~/.ghds-release-keys/ghds-ed25519（历史路径按兼容例外保留，本机保管，勿入库） -->
    <key>SUFeedURL</key>
    <string>${SU_FEED_URL:-https://github.com/LYT259/MatchSticks-DriverStaion/releases/latest/download/appcast.xml}</string>
    <key>SUPublicEDKey</key>
    <string>${SU_PUBLIC_ED_KEY:-YHHW4wKUsjO8HlZkuZc4vdJWZj4y4ftbiFcEsJkNop4=}</string>
</dict>
</plist>
PLIST

# Sparkle downloader XPC 是独立进程，进程内 URLProtocol / route / 凭据清理不会覆盖它。
# 任何未来开启 SUEnableDownloaderService 的改动都必须显式重审更新路由，不能由打包静默带入。
python3 - "$APP/Contents/Info.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as stream:
    info = plistlib.load(stream)
if "SUEnableDownloaderService" in info:
    print("  ✗ 产物 Info.plist 不得包含 SUEnableDownloaderService（会绕过进程内更新路由）", file=sys.stderr)
    sys.exit(1)
PY

echo "PBPB" > "$APP/Contents/PkgInfo"

# 权限弹窗与版权文案双语（Info.plist 键的 per-language 覆盖；中文为主表值，英文走 en.lproj）
mkdir -p "$APP/Contents/Resources/en.lproj" "$APP/Contents/Resources/zh-Hans.lproj"
cat > "$APP/Contents/Resources/en.lproj/InfoPlist.strings" <<'STRINGS'
"NSLocalNetworkUsageDescription" = "MatchSticks Driver Station needs local network access to connect to roboRIO / SystemCore robots (UDP 1110/1150, TCP 1740, mDNS discovery). If the robot won't connect, first allow this app under Settings → Privacy & Security → Local Network.";
"NSHumanReadableCopyright" = "© 2026 GH-FRC — Practice Only (third-party DS must not be used in official matches)";
STRINGS
cat > "$APP/Contents/Resources/zh-Hans.lproj/InfoPlist.strings" <<'STRINGS'
"NSLocalNetworkUsageDescription" = "MatchSticks Driver Station 需要访问本地网络以连接 roboRIO / SystemCore 机器人（UDP 1110/1150、TCP 1740、mDNS 发现）。机器人连不上时请先在 设置 → 隐私与安全性 → 本地网络 中允许本应用。";
"NSHumanReadableCopyright" = "© 2026 GH-FRC — Practice Only（第三方 DS 不得用于正式比赛）";
STRINGS

# ad-hoc 签名（打包红线：保留有效签名；未公证分发按报告 §5.5 方案 A）
codesign --force --deep -s - "$APP"
# --deep --strict：连同嵌套可执行文件（MatchSticksDriverStaionSim）一起做资源密封校验；
# 打包红线「签名损坏=只剩 xattr 终端路的死胡同」依赖这道门禁真正兜住嵌套代码
codesign --verify --deep --strict --verbose=2 "$APP" >/dev/null && echo "  ✓ 签名校验通过（deep+strict，含嵌套 MatchSticksDriverStaionSim）"

echo "▶ 打 DMG"
rm -rf "$OUT_DIR/stage"
mkdir -p "$OUT_DIR/stage"
cp -R "$APP" "$OUT_DIR/stage/"
ln -sf /Applications "$OUT_DIR/stage/Applications"
DMG="$OUT_DIR/MatchSticks-DriverStaion-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$OUT_DIR/stage" -ov -format UDZO "$DMG" | tail -1

echo "▶ SHA256"
(cd "$OUT_DIR" && shasum -a 256 "MatchSticks-DriverStaion-$VERSION.dmg" | tee SHA256SUMS)

echo "✅ 完成：$APP / $DMG"
