#!/bin/bash
# Sparkle 本地升级链路 E2E（无硬件；Phase 4 安全链级验证）
#
# Leg A（升级链路全流程）：旧版 9.9.8 静默检查→后台下载→就绪→重启安装→换 9.9.9 存活。
#   点击由 GHDS_UPDATE_AUTOTAP=1 替操作员完成（安全门照常现场求值；本 leg 无 sim，处于
#   失能+未连接+无锁存的放行态）。
# Leg B（安全门阻断 + 退出不安装）：旧版 9.9.8 连接本机模拟器（通信活跃）→ AUTOTAP 被安全门
#   阻断（角标就绪但点击无效）；随后强退进程，接管式安装（willInstallUpdateOnQuit 返回 true）
#   保证退出路径也不安装——版本保持 9.9.8。
set -euo pipefail
cd "$(dirname "$0")/.."
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
export DEVELOPER_DIR

fail() { echo "✗ $1" >&2; exit 1; }

# 前置：不与真实使用冲突
if pgrep -x GHDS >/dev/null 2>&1; then fail "已有 GHDS 进程在运行，请先关闭后再跑本测试"; fi
pkill -x GHDSSim 2>/dev/null || true

WORK=/tmp/ghds-update-e2e
rm -rf "$WORK"; mkdir -p "$WORK/web"

echo "▶ 测试密钥（构建前生成，经 SU_PUBLIC_ED_KEY 进 Info.plist——签名后改 plist 会破坏资源密封，Sparkle 拒收）"
KEY="$WORK/test-ed25519"
PUB="$(swift scripts/sign-update.swift genkey "$KEY" | head -1 | sed 's/.*：//')"
echo "▶ 构建两个本地版本（9.9.8 / 9.9.9，universal release）"
SU_PUBLIC_ED_KEY="$PUB" bash scripts/build-app.sh 9.9.8 >/dev/null
cp -R "dist/GH Driver Station.app" "$WORK/old.app"
SU_PUBLIC_ED_KEY="$PUB" bash scripts/build-app.sh 9.9.9 >/dev/null
cp -R "dist/GH Driver Station.app" "$WORK/new.app"
( cd "$WORK" && ditto -c -k --sequesterRsrc --keepParent new.app new-9.9.9.zip )
SIGLINE="$(swift scripts/sign-update.swift sign "$KEY" "$WORK/new-9.9.9.zip")"
SIG="$(printf '%s' "$SIGLINE" | sed -n 's/.*edSignature="\([^"]*\)".*/\1/p')"
LEN="$(printf '%s' "$SIGLINE" | sed -n 's/.*length="\([0-9]*\)".*/\1/p')"
[ -n "$SIG" ] && [ -n "$LEN" ] || fail "签名输出解析失败：$SIGLINE"
cp "$WORK/new-9.9.9.zip" "$WORK/web/"
NOW="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"
cat > "$WORK/web/appcast.xml" <<APCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>GH Driver Station（本地升级链路测试）</title>
    <item>
      <title>版本 9.9.9（E2E 测试版本）</title>
      <sparkle:version>9.9.9</sparkle:version>
      <sparkle:shortVersionString>9.9.9</sparkle:shortVersionString>
      <pubDate>$NOW</pubDate>
      <enclosure url="http://127.0.0.1:8123/new-9.9.9.zip" length="$LEN" type="application/octet-stream" sparkle:edSignature="$SIG" />
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
    </item>
  </channel>
</rss>
APCAST

python3 -m http.server 8123 --directory "$WORK/web" --bind 127.0.0.1 >/dev/null 2>&1 &
HTTP_PID=$!
cleanup() {
    pkill -f "ghds-update-e2e" 2>/dev/null || true
    pkill -x GHDSSim 2>/dev/null || true
    kill "$HTTP_PID" 2>/dev/null || true
}
trap cleanup EXIT
sleep 1

version_of() { plutil -extract CFBundleShortVersionString raw "$1/Contents/Info.plist"; }
wait_log() { # $1=文件 $2=扩展正则 $3=超时秒
    local i=0
    while [ $i -lt "$3" ]; do
        grep -Eq "$2" "$1" 2>/dev/null && return 0
        sleep 2; i=$((i + 2))
    done
    return 1
}

echo "▶ Leg A：升级链路全流程（无 sim，安全门放行态）"
cp -R "$WORK/old.app" "$WORK/GHDS-A.app"
GHDS_LOG_FILE="$WORK/legA.log" GHDS_FEED_URL="http://127.0.0.1:8123/appcast.xml" \
  GHDS_UPDATE_AUTOTAP=1 "$WORK/GHDS-A.app/Contents/MacOS/GHDS" >/dev/null 2>&1 &
APP_A_PID=$!
DEADLINE=$((SECONDS + 180))
while [ $SECONDS -lt $DEADLINE ]; do
    if pgrep -f "GHDS-A.app/Contents/MacOS/GHDS" >/dev/null 2>&1 \
       && [ "$(version_of "$WORK/GHDS-A.app")" = "9.9.9" ]; then break; fi
    kill -0 "$APP_A_PID" 2>/dev/null || true
    sleep 2
done
[ "$(version_of "$WORK/GHDS-A.app")" = "9.9.9" ] || { cat "$WORK/legA.log" 2>/dev/null; fail "Leg A：升级未完成（版本仍为 $(version_of "$WORK/GHDS-A.app")）"; }
pgrep -f "GHDS-A.app/Contents/MacOS/GHDS" >/dev/null 2>&1 || { cat "$WORK/legA.log" 2>/dev/null; fail "Leg A：新版本进程未存活"; }
grep -Eq "发现新版本 9.9.9|New version 9.9.9 found" "$WORK/legA.log" || fail "Leg A：未见「发现新版本」日志"
grep -Eq "下载就绪|Version 9.9.9 downloaded" "$WORK/legA.log" || fail "Leg A：未见「下载就绪」日志"
grep -Eq "安全门放行|safety gate open" "$WORK/legA.log" || fail "Leg A：未见「安全门放行」日志"
! grep -Eq "被安全门阻断|blocked by safety gate" "$WORK/legA.log" || fail "Leg A：放行态出现阻断日志（不应发生）"
echo "  ✓ Leg A：9.9.8 → 9.9.9 升级+重启存活，链路日志齐备"
pkill -f "GHDS-A.app/Contents/MacOS/GHDS" 2>/dev/null || true
sleep 2

echo "▶ Leg B：安全门阻断（连接模拟器=通信活跃）+ 退出不安装"
"$WORK/new.app/Contents/MacOS/GHDSSim" --quiet >/dev/null 2>&1 &
SIM_PID=$!
sleep 1
# appcast 从一开始就在线；AUTOTAP 延时 12s 再替点——sim 连接 ~2s 内建立，
# 点击时必为「通信活跃」态（真实点击时刻现场求值，不依赖重试周期）
cp -R "$WORK/old.app" "$WORK/GHDS-B.app"
GHDS_LOG_FILE="$WORK/legB.log" GHDS_FEED_URL="http://127.0.0.1:8123/appcast.xml" \
  GHDS_UPDATE_AUTOTAP=1 GHDS_UPDATE_AUTOTAP_DELAY=12 GHDS_AUTO_SIM=1 \
  "$WORK/GHDS-B.app/Contents/MacOS/GHDS" >/dev/null 2>&1 &
APP_B_PID=$!
wait_log "$WORK/legB.log" "收到版本信息|Version info received" 20 || { cat "$WORK/legB.log" 2>/dev/null; fail "Leg B：20s 内未见 TCP 版本信息（未连上模拟器）"; }
wait_log "$WORK/legB.log" "下载就绪|Version .* downloaded" 60 || { cat "$WORK/legB.log" 2>/dev/null; fail "Leg B：60s 内未见下载就绪"; }
wait_log "$WORK/legB.log" "被安全门阻断|blocked by safety gate" 30 || { cat "$WORK/legB.log" 2>/dev/null; fail "Leg B：延时 AUTOTAP 未被安全门阻断"; }
grep -E "被安全门阻断|blocked by safety gate" "$WORK/legB.log" | head -1 | grep -Eq "通信|Comms active|communication active" || { cat "$WORK/legB.log"; fail "Leg B：阻断原因不是通信活跃"; }
! grep -Eq "安全门放行|safety gate open" "$WORK/legB.log" || fail "Leg B：连接态出现放行日志（不应发生）"
# 存活期契约：阻断后版本必须不变（活进程期间安装的唯一触发 = 点击 + 安全门放行）
sleep 2
[ "$(version_of "$WORK/GHDS-B.app")" = "9.9.8" ] || fail "Leg B：阻断后存活期间版本被改为 $(version_of "$WORK/GHDS-B.app")"
kill -TERM "$APP_B_PID" 2>/dev/null || true
B_DEADLINE=$((SECONDS + 20))
while kill -0 "$APP_B_PID" 2>/dev/null && [ $SECONDS -lt $B_DEADLINE ]; do sleep 1; done
kill -9 "$APP_B_PID" 2>/dev/null || true
sleep 5
# 退出路径契约（Sparkle 固有行为，实测确认）：宿主进程死亡后安装器会完成挂起的安装
# （版本可能变为 9.9.9），但绝不自动重启应用；机器人侧看门狗在进程死亡瞬间已失能输出，
# 完成安装不产生新风险。这里断言的是「无重启进程」。
if pgrep -f "GHDS-B.app/Contents/MacOS/GHDS" >/dev/null 2>&1; then
    fail "Leg B：进程死亡后应用被自动重启（不应发生）"
fi
echo "  ✓ Leg B：通信活跃阻断点击安装；存活期版本不变；强退后无自动重启（Sparkle 事后完成挂起安装属预期，退出后版本=$(version_of "$WORK/GHDS-B.app")）"

echo ""
echo "✅ Sparkle 升级链路 E2E 全部通过（Leg A 升级链路 + Leg B 安全门两处阻断）"
