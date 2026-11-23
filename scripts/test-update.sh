#!/bin/bash
# MatchSticks DS Sparkle 本地升级链路 E2E（无硬件；Phase 4 安全链级验证）
#
# Leg A（升级链路全流程）：旧版 9.9.8 静默检查 → 后台下载 → 就绪 → 点击（AUTOTAP）
#   安全门现场求值放行 → Sparkle 终止并重启 → 新版本 9.9.9 存活。
#   本 leg 无 sim，处于失能 + 未连接 + 无锁存的放行态。
# Leg B（通信活跃阻断 + 退出路径不自动重启）：旧版 9.9.8 连接本机模拟器（通信活跃）→
#   AUTOTAP 被安全门阻断（角标就绪但点击无效）；随后强退进程。Sparkle 的独立安装器
#   可能完成已挂起的安装（退出后版本可能变为 9.9.9），但不会自动重启应用——断言
#   「存活期版本不变」与「强退后无重启进程」。使能 / 急停锁存分支由 UpdateSafetyGate
#   全组合单测覆盖；本 E2E 只覆盖通信活跃这一真实阻塞态。
#
# 隔离与清理：每次运行 mktemp 独立 WORK；不 pkill -x、不按宽匹配清进程，也不抢占
# 其他会话的 8123；前置发现已有 GHDS/MatchSticksDS/模拟器直接退出报告。测试副本的
# Info.plist 注入 LSEnvironment（LaunchServices 重启后仍继承测试设置）和 Sparkle 的
# SUDefaultsDomain（Sparkle 偏好也落测试 suite），随后重新 ad-hoc 签名；正式域
# org.ghfrc.driverstation 做全量 UserDefaults export 前后比较（不只 4 个键）。
set -euo pipefail
cd "$(dirname "$0")/.."
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
export DEVELOPER_DIR

EXPECTED_PROD_BUNDLE=org.ghfrc.driverstation

# 测试隔离：每次运行生成唯一、合法的反 DNS suite 名，导出给被测进程。
# 新前缀 MATCHSTICKS_DS_*；旧 GHDS_SETTINGS_SUITE 作为兼容 alias 一并导出，保证任何仍读旧名的
# 被测路径也落在隔离 suite 上。退出时只删本脚本创建的 suite（含 cfprefsd 留下的空 plist），
# 不碰正式域。
MATCHSTICKS_DS_SETTINGS_SUITE="org.ghfrc.driverstation.test.update.$$.$(date +%Y%m%d%H%M%S).$RANDOM"
GHDS_SETTINGS_SUITE="$MATCHSTICKS_DS_SETTINGS_SUITE"
export MATCHSTICKS_DS_SETTINGS_SUITE GHDS_SETTINGS_SUITE
cleanup_settings_suite() {
    local suite="${MATCHSTICKS_DS_SETTINGS_SUITE:-}"
    case "$suite" in
        org.ghfrc.driverstation.test.*) ;;
        *) return 0 ;;
    esac
    defaults delete "$suite" >/dev/null 2>&1 || true
    rm -f "$HOME/Library/Preferences/$suite.plist" 2>/dev/null || true
}

# 解析 TMPDIR 的物理路径（macOS 的 /var → /private/var），保证 pgrep -f 与
# LaunchServices 重启后的进程路径一致，WORK 前缀清理也不会因符号链接失效。
TMP_BASE="${TMPDIR:-/tmp}"
if ! TMP_BASE="$(cd "$TMP_BASE" 2>/dev/null && pwd -P)"; then
    TMP_BASE=/tmp
    TMP_BASE="$(cd "$TMP_BASE" && pwd -P)"
fi
WORK=""
HTTP_PID=""
SIM_PID=""
APP_A_PID=""
APP_B_PID=""

fail() { echo "✗ $1" >&2; exit 1; }

# 只按唯一 WORK 路径清理本测试启动的 app/sim，不碰其他会话。
work_app_pids() {
    [ -n "${WORK:-}" ] || return 0
    {
        pgrep -f "$WORK/.*/Contents/MacOS/MatchSticksDS" 2>/dev/null || true
        pgrep -f "$WORK/.*/Contents/MacOS/MatchSticksDSSim" 2>/dev/null || true
    } | sort -u
}
stop_work_processes() {
    local pids
    pids="$(work_app_pids)"
    [ -n "$pids" ] || return 0
    # shellcheck disable=SC2086
    kill -TERM $pids 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pids="$(work_app_pids)"
        [ -z "$pids" ] && break
        sleep 0.2
    done
    pids="$(work_app_pids)"
    if [ -n "$pids" ]; then
        # shellcheck disable=SC2086
        kill -9 $pids 2>/dev/null || true
    fi
}
stop_matching_app() {
    local pattern="$1" pids
    pids="$(pgrep -f "$pattern" 2>/dev/null || true)"
    [ -n "$pids" ] || return 0
    # shellcheck disable=SC2086
    kill -TERM $pids 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pids="$(pgrep -f "$pattern" 2>/dev/null || true)"
        [ -z "$pids" ] && break
        sleep 0.2
    done
    pids="$(pgrep -f "$pattern" 2>/dev/null || true)"
    if [ -n "$pids" ]; then
        # shellcheck disable=SC2086
        kill -9 $pids 2>/dev/null || true
    fi
}
stop_pid() { # $1=PID $2=TERM 等待秒数（默认 2）
    local pid="$1" timeout="${2:-2}" i=0 cmd
    [ -n "$pid" ] || return 0
    kill -0 "$pid" 2>/dev/null || return 0
    cmd="$(ps -p "$pid" -ww -o command= 2>/dev/null || true)"
    case "$cmd" in
        "$WORK"/*) ;;
        *) return 0 ;;
    esac
    kill -TERM "$pid" 2>/dev/null || true
    while [ "$i" -lt "$timeout" ]; do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 1
        i=$((i + 1))
    done
    kill -9 "$pid" 2>/dev/null || true
}
cleanup() {
    stop_work_processes
    if [ -n "${HTTP_PID:-}" ]; then
        kill -TERM "$HTTP_PID" 2>/dev/null || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$HTTP_PID" 2>/dev/null || break
            sleep 0.2
        done
        kill -9 "$HTTP_PID" 2>/dev/null || true
        wait "$HTTP_PID" 2>/dev/null || true
        HTTP_PID=""
    fi
    cleanup_settings_suite
    if [ -n "${WORK:-}" ]; then
        case "$WORK" in
            "$TMP_BASE"/matchsticks-ds-update-e2e.*) rm -rf -- "$WORK" ;;
        esac
    fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# 前置：不抢占真实使用或其他会话。发现即报告退出，不自动强杀。
require_no_existing_processes() {
    local name pids report=""
    for name in MatchSticksDS GHDS MatchSticksDSSim GHDSSim; do
        pids="$(pgrep -x "$name" 2>/dev/null || true)"
        if [ -n "$pids" ]; then
            report="${report}${report:+; }$name PID $(printf '%s' "$pids" | tr '\n' ' ')"
        fi
    done
    if [ -n "$report" ]; then
        fail "检测到已在运行的 GHDS/MatchSticksDS/模拟器进程：${report}。本测试不会强杀，请先退出后再跑。"
    fi
}
require_no_existing_processes

WORK="$(mktemp -d "$TMP_BASE/matchsticks-ds-update-e2e.XXXXXX")"
mkdir -p "$WORK/web"

# 日志断言使用中文键：固定测试 suite 的语言，避免宿主系统语言把断言变成假失败。
# 新旧设置前缀都写（新版 matchsticks.*，兼容读取的旧 ghds.*），只落在隔离 suite。
defaults write "$MATCHSTICKS_DS_SETTINGS_SUITE" matchsticks.language -string chinese
defaults write "$MATCHSTICKS_DS_SETTINGS_SUITE" ghds.language -string chinese

# 本地升级源端口：8123 空闲则用；被占用则挑 8124–8180 的空闲端口，绝不抢占。
port_is_free() {
    ! lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
}
command -v lsof >/dev/null 2>&1 || fail "需要 lsof 检测端口占用（macOS 自带）"
FEED_PORT=8123
if ! port_is_free "$FEED_PORT"; then
    echo "▶ 127.0.0.1:8123 已被占用，自动选择可用端口（不干扰现有进程）"
    FEED_PORT=""
    for candidate in $(seq 8124 8180); do
        if port_is_free "$candidate"; then FEED_PORT="$candidate"; break; fi
    done
    [ -n "$FEED_PORT" ] || fail "8123–8180 均被占用，无法启动本地升级源；本测试不会抢占其他会话端口"
fi
echo "▶ 本地升级源端口：127.0.0.1:${FEED_PORT}"

# 全量正式域快照：export 整个域再哈希，覆盖所有键（含 Sparkle 键与未来新增键），
# 不输出实际值。域不存在时 export 为空 plist，前后同样比较；导出失败则明确失败。
PROD_DOMAIN="$EXPECTED_PROD_BUNDLE"
snapshot_production_domain() {
    local payload
    payload="$(defaults export "$PROD_DOMAIN" - 2>/dev/null)" \
        || fail "无法完整导出正式域 ${PROD_DOMAIN}（全量快照不可用）"
    printf '%s' "$payload" | shasum -a 256 | awk '{print "SHA256:"$1}'
    if [ "$#" -ge 1 ]; then printf '%s' "$payload" > "$1"; fi
}

echo "▶ 测试密钥（构建前生成，经 SU_PUBLIC_ED_KEY 进 Info.plist——签名后改 plist 会破坏资源密封，Sparkle 拒收）"
KEY="$WORK/test-ed25519"
PUB="$(swift scripts/sign-update.swift genkey "$KEY" | sed -n '1s/.*：//p')"
[ -n "$PUB" ] || fail "测试公钥解析失败"
echo "▶ 构建两个本地版本（9.9.8 / 9.9.9，universal release）"
SU_PUBLIC_ED_KEY="$PUB" bash scripts/build-app.sh 9.9.8 >/dev/null
cp -R "dist/MatchSticks DS.app" "$WORK/old.app"
SU_PUBLIC_ED_KEY="$PUB" bash scripts/build-app.sh 9.9.9 >/dev/null
cp -R "dist/MatchSticks DS.app" "$WORK/new.app"

version_of() { plutil -extract CFBundleShortVersionString raw "$1/Contents/Info.plist"; }
bundle_id_of() { plutil -extract CFBundleIdentifier raw "$1/Contents/Info.plist"; }
set_plist_string() { # $1=keypath $2=value $3=plist
    plutil -insert "$1" -string "$2" "$3" 2>/dev/null \
        || plutil -replace "$1" -string "$2" "$3" \
        || fail "写入 Info.plist 失败：$3 :: $1"
}
assert_bundle_id() {
    local app="$1" actual
    actual="$(bundle_id_of "$app" 2>/dev/null || true)"
    [ "$actual" = "$EXPECTED_PROD_BUNDLE" ] \
        || fail "bundle ID 断言失败：$app = ${actual:-<空>}，预期 $EXPECTED_PROD_BUNDLE"
}
assert_version() {
    local app="$1" expected="$2" actual
    actual="$(version_of "$app" 2>/dev/null || true)"
    [ "$actual" = "$expected" ] || fail "版本断言失败：$app = ${actual:-<空>}，预期 $expected"
}
wait_for_support_log() {
    local label="$1" support="$2" timeout="${3:-30}" i=0 first
    while [ "$i" -lt "$timeout" ]; do
        first="$(find "$support/MatchSticksDS/Logs" -type f -name '*.dslog' -print -quit 2>/dev/null || true)"
        [ -n "$first" ] && return 0
        sleep 1
        i=$((i + 1))
    done
    fail "$label：${timeout}s 内测试支持目录未产生 .dslog（MATCHSTICKS_DS_APPLICATION_SUPPORT 未生效？）"
}
assert_support_logs() {
    local label="$1" support="$2" first
    first="$(find "$support/MatchSticksDS/Logs" -type f -name '*.dslog' -print -quit 2>/dev/null || true)"
    [ -n "$first" ] \
        || fail "$label：测试支持目录未产生 .dslog（MATCHSTICKS_DS_APPLICATION_SUPPORT 未生效？）"
}

# 测试副本专用：注入 LSEnvironment（Sparkle 用 LaunchServices 重启，shell 环境不会继承）
# 与 SUDefaultsDomain（Sparkle 自带偏好也写测试 suite），然后重新 ad-hoc 签名。
# 生产 .app 与 bundle ID 不变；这些键只存在于 WORK 内的副本。
prepare_leg_app() {
    local app="$1" support="$2" logfile="$3" delay="${4:-}" auto_sim="${5:-0}"
    local plist="$app/Contents/Info.plist"
    plutil -insert LSEnvironment -dictionary "$plist" 2>/dev/null \
        || plutil -replace LSEnvironment -dictionary "$plist" \
        || fail "写入 Info.plist 失败：$plist :: LSEnvironment"
    set_plist_string LSEnvironment.MATCHSTICKS_DS_SETTINGS_SUITE "$MATCHSTICKS_DS_SETTINGS_SUITE" "$plist"
    set_plist_string LSEnvironment.MATCHSTICKS_DS_APPLICATION_SUPPORT "$support" "$plist"
    set_plist_string LSEnvironment.MATCHSTICKS_DS_LOG_FILE "$logfile" "$plist"
    set_plist_string LSEnvironment.MATCHSTICKS_DS_FEED_URL "http://127.0.0.1:${FEED_PORT}/appcast.xml" "$plist"
    set_plist_string LSEnvironment.MATCHSTICKS_DS_UPDATE_AUTOTAP "1" "$plist"
    # 新前缀显式置 0：若宿主 shell 残留旧 GHDS_DISABLE_UPDATE=1，新值仍优先。
    set_plist_string LSEnvironment.MATCHSTICKS_DS_DISABLE_UPDATE "0" "$plist"
    if [ -n "$delay" ]; then
        set_plist_string LSEnvironment.MATCHSTICKS_DS_UPDATE_AUTOTAP_DELAY "$delay" "$plist"
    fi
    if [ "$auto_sim" = "1" ]; then
        set_plist_string LSEnvironment.MATCHSTICKS_DS_AUTO_SIM "1" "$plist"
    fi
    # 保险：即使某条重启路径没有继承环境，也不会去碰生产 appcast。
    set_plist_string SUFeedURL "http://127.0.0.1:${FEED_PORT}/appcast.xml" "$plist"
    set_plist_string SUDefaultsDomain "$MATCHSTICKS_DS_SETTINGS_SUITE" "$plist"
    codesign --force --deep -s - "$app" >/dev/null 2>&1 \
        || fail "测试副本重新签名失败：$app"
    codesign --verify --deep --strict "$app" >/dev/null 2>&1 \
        || fail "测试副本签名校验失败：$app"
}

SUPPORT_A="$WORK/support-A"
SUPPORT_B="$WORK/support-B"
mkdir -p "$SUPPORT_A" "$SUPPORT_B"

assert_bundle_id "$WORK/old.app"
assert_bundle_id "$WORK/new.app"
assert_version "$WORK/old.app" 9.9.8
assert_version "$WORK/new.app" 9.9.9

echo "▶ 记录正式域全量设置快照（${PROD_DOMAIN}，不输出实际值）"
BEFORE_PRODUCTION="$(snapshot_production_domain "$WORK/production-before.plist")"
[ -z "$(find "$SUPPORT_A" -type f -print -quit 2>/dev/null)" ] \
    || fail "Leg A 支持根启动前已有文件（隔离失效）"
[ -z "$(find "$SUPPORT_B" -type f -print -quit 2>/dev/null)" ] \
    || fail "Leg B 支持根启动前已有文件（隔离失效）"

# Leg A 的安装包也带 A 的 LSEnvironment：Sparkle 重启后的新进程仍使用同一测试 suite、
# 支持目录与日志文件。Leg B 不重启，同一 payload 的 A 环境不会产生额外副作用。
cp -R "$WORK/old.app" "$WORK/MatchSticksDS-A.app"
prepare_leg_app "$WORK/MatchSticksDS-A.app" "$SUPPORT_A" "$WORK/legA.log"
cp -R "$WORK/old.app" "$WORK/MatchSticksDS-B.app"
prepare_leg_app "$WORK/MatchSticksDS-B.app" "$SUPPORT_B" "$WORK/legB.log" 12 1
prepare_leg_app "$WORK/new.app" "$SUPPORT_A" "$WORK/legA.log"
assert_bundle_id "$WORK/MatchSticksDS-A.app"
assert_bundle_id "$WORK/MatchSticksDS-B.app"
assert_bundle_id "$WORK/new.app"

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
    <title>MatchSticks DS（本地升级链路测试）</title>
    <item>
      <title>版本 9.9.9（E2E 测试版本）</title>
      <sparkle:version>9.9.9</sparkle:version>
      <sparkle:shortVersionString>9.9.9</sparkle:shortVersionString>
      <pubDate>$NOW</pubDate>
      <enclosure url="http://127.0.0.1:${FEED_PORT}/new-9.9.9.zip" length="$LEN" type="application/octet-stream" sparkle:edSignature="$SIG" />
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
    </item>
  </channel>
</rss>
APCAST

python3 -m http.server "$FEED_PORT" --directory "$WORK/web" --bind 127.0.0.1 >/dev/null 2>&1 &
HTTP_PID=$!
sleep 1
kill -0 "$HTTP_PID" 2>/dev/null \
    || fail "本地升级源未能在 127.0.0.1:${FEED_PORT} 启动（端口被抢占？）"
curl -fsS --max-time 3 "http://127.0.0.1:${FEED_PORT}/appcast.xml" >/dev/null 2>&1 \
    || fail "本地升级源 127.0.0.1:${FEED_PORT} 未提供 appcast.xml"

wait_log() { # $1=文件 $2=扩展正则 $3=超时秒
    local i=0
    while [ $i -lt "$3" ]; do
        grep -Eq "$2" "$1" 2>/dev/null && return 0
        sleep 2; i=$((i + 2))
    done
    return 1
}

echo "▶ Leg A：升级链路全流程（无 sim，安全门放行态）"
# 测试钩子新旧名同时导出：MATCHSTICKS_DS_* 为新前缀，GHDS_* 保留给仍读旧名的兼容读取路径
# （两套取值一致，新前缀为准）。LSEnvironment 里也写了新前缀，供 Sparkle 重启后的进程继承。
MATCHSTICKS_DS_APPLICATION_SUPPORT="$SUPPORT_A" \
MATCHSTICKS_DS_LOG_FILE="$WORK/legA.log" GHDS_LOG_FILE="$WORK/legA.log" \
MATCHSTICKS_DS_FEED_URL="http://127.0.0.1:${FEED_PORT}/appcast.xml" GHDS_FEED_URL="http://127.0.0.1:${FEED_PORT}/appcast.xml" \
MATCHSTICKS_DS_UPDATE_AUTOTAP=1 GHDS_UPDATE_AUTOTAP=1 \
MATCHSTICKS_DS_DISABLE_UPDATE=0 \
  "$WORK/MatchSticksDS-A.app/Contents/MacOS/MatchSticksDS" >/dev/null 2>&1 &
APP_A_PID=$!
wait_for_support_log "Leg A（首次启动）" "$SUPPORT_A"
DEADLINE=$((SECONDS + 180))
while [ $SECONDS -lt $DEADLINE ]; do
    if pgrep -f "$WORK/MatchSticksDS-A.app/Contents/MacOS/MatchSticksDS" >/dev/null 2>&1 \
       && [ "$(version_of "$WORK/MatchSticksDS-A.app")" = "9.9.9" ]; then break; fi
    sleep 2
done
[ "$(version_of "$WORK/MatchSticksDS-A.app")" = "9.9.9" ] || { cat "$WORK/legA.log" 2>/dev/null; fail "Leg A：升级未完成（版本仍为 $(version_of "$WORK/MatchSticksDS-A.app")）"; }
pgrep -f "$WORK/MatchSticksDS-A.app/Contents/MacOS/MatchSticksDS" >/dev/null 2>&1 || { cat "$WORK/legA.log" 2>/dev/null; fail "Leg A：新版本进程未存活"; }
assert_bundle_id "$WORK/MatchSticksDS-A.app"
assert_version "$WORK/MatchSticksDS-A.app" 9.9.9
# Sparkle 用 LaunchServices 重启，shell 环境不会继承；LSEnvironment 是否生效由重启后的
# 9.9.9 进程仍写同一个隔离日志证明（生产支持目录/设置域不应被触碰）。
wait_log "$WORK/legA.log" "更新组件就绪（当前版本 9\.9\.9|Updater ready \(version 9\.9\.9" 30 \
    || { cat "$WORK/legA.log" 2>/dev/null; fail "Leg A：重启后的 9.9.9 进程未继承测试环境（LSEnvironment 未生效？）"; }
grep -Eq "发现新版本 9.9.9|New version 9.9.9 found" "$WORK/legA.log" || fail "Leg A：未见「发现新版本」日志"
grep -Eq "下载就绪|Version 9.9.9 downloaded" "$WORK/legA.log" || fail "Leg A：未见「下载就绪」日志"
grep -Eq "安全门放行|safety gate open" "$WORK/legA.log" || fail "Leg A：未见「安全门放行」日志"
! grep -Eq "被安全门阻断|blocked by safety gate" "$WORK/legA.log" || fail "Leg A：放行态出现阻断日志（不应发生）"
assert_support_logs "Leg A" "$SUPPORT_A"
echo "  ✓ Leg A：9.9.8 → 9.9.9 升级并重启存活，链路日志齐备，bundle ID 保持 ${EXPECTED_PROD_BUNDLE}"
stop_matching_app "$WORK/MatchSticksDS-A.app/Contents/MacOS/MatchSticksDS"
pgrep -f "$WORK/MatchSticksDS-A.app/Contents/MacOS/MatchSticksDS" >/dev/null 2>&1 \
    && fail "Leg A：升级后的进程未退出"
sleep 2

echo "▶ Leg B：通信活跃安全门阻断 + 强退后不自动重启"
"$WORK/new.app/Contents/MacOS/MatchSticksDSSim" --quiet >/dev/null 2>&1 &
SIM_PID=$!
sleep 1
# appcast 从一开始就在线；AUTOTAP 延时 12s 再替点——sim 连接 ~2s 内建立，
# 点击时必为「通信活跃」态（真实点击时刻现场求值，不依赖重试周期）
MATCHSTICKS_DS_APPLICATION_SUPPORT="$SUPPORT_B" \
MATCHSTICKS_DS_LOG_FILE="$WORK/legB.log" GHDS_LOG_FILE="$WORK/legB.log" \
MATCHSTICKS_DS_FEED_URL="http://127.0.0.1:${FEED_PORT}/appcast.xml" GHDS_FEED_URL="http://127.0.0.1:${FEED_PORT}/appcast.xml" \
MATCHSTICKS_DS_UPDATE_AUTOTAP=1 GHDS_UPDATE_AUTOTAP=1 \
MATCHSTICKS_DS_UPDATE_AUTOTAP_DELAY=12 GHDS_UPDATE_AUTOTAP_DELAY=12 \
MATCHSTICKS_DS_AUTO_SIM=1 GHDS_AUTO_SIM=1 \
MATCHSTICKS_DS_DISABLE_UPDATE=0 \
  "$WORK/MatchSticksDS-B.app/Contents/MacOS/MatchSticksDS" >/dev/null 2>&1 &
APP_B_PID=$!
wait_for_support_log "Leg B（首次启动）" "$SUPPORT_B"
wait_log "$WORK/legB.log" "收到版本信息|Version info received" 20 || { cat "$WORK/legB.log" 2>/dev/null; fail "Leg B：20s 内未见 TCP 版本信息（未连上模拟器）"; }
wait_log "$WORK/legB.log" "下载就绪|Version .* downloaded" 60 || { cat "$WORK/legB.log" 2>/dev/null; fail "Leg B：60s 内未见下载就绪"; }
wait_log "$WORK/legB.log" "被安全门阻断|blocked by safety gate" 30 || { cat "$WORK/legB.log" 2>/dev/null; fail "Leg B：延时 AUTOTAP 未被安全门阻断"; }
grep -E "被安全门阻断|blocked by safety gate" "$WORK/legB.log" | sed -n '1p' | grep -Eq "通信|Comms active|communication active" || { cat "$WORK/legB.log"; fail "Leg B：阻断原因不是通信活跃"; }
! grep -Eq "安全门放行|safety gate open" "$WORK/legB.log" || fail "Leg B：连接态出现放行日志（不应发生）"
# 存活期契约：阻断后版本必须不变（活进程期间安装的唯一触发 = 点击 + 安全门放行）
sleep 2
[ "$(version_of "$WORK/MatchSticksDS-B.app")" = "9.9.8" ] || fail "Leg B：阻断后存活期间版本被改为 $(version_of "$WORK/MatchSticksDS-B.app")"
assert_support_logs "Leg B" "$SUPPORT_B"
stop_pid "$APP_B_PID" 20
wait "$APP_B_PID" 2>/dev/null || true
kill -0 "$APP_B_PID" 2>/dev/null && fail "Leg B：进程未被强退"
sleep 5
# 退出路径契约（Sparkle 固有行为，实测确认）：宿主进程死亡后安装器可能完成挂起的安装
# （版本可能变为 9.9.9），但绝不自动重启应用；机器人侧看门狗在进程死亡瞬间已失能输出，
# 完成安装不产生新风险。这里断言的是「无重启进程」，不要求退出后版本仍为 9.9.8。
if pgrep -f "$WORK/MatchSticksDS-B.app/Contents/MacOS/MatchSticksDS" >/dev/null 2>&1; then
    fail "Leg B：进程死亡后应用被自动重启（不应发生）"
fi
# B 的安装包可能仍在被独立安装器替换；不在这里读 Info.plist，避免与安装写盘竞态。
# bundle ID 已在构建版本、A/B 启动前和升级后的 A 上断言。
AFTER_B_VERSION="$(version_of "$WORK/MatchSticksDS-B.app" 2>/dev/null || echo "安装器仍在完成")"
echo "  ✓ Leg B：通信活跃阻断点击安装；存活期版本不变；强退后无自动重启（Sparkle 可能已完成挂起安装，退出后版本=${AFTER_B_VERSION}；使能/急停分支由单测覆盖）"

stop_pid "$SIM_PID"
SIM_PID=""
stop_work_processes
AFTER_PRODUCTION="$(snapshot_production_domain "$WORK/production-after.plist")"
if [ "$BEFORE_PRODUCTION" != "$AFTER_PRODUCTION" ]; then
    python3 - "$WORK/production-before.plist" "$WORK/production-after.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as stream:
    before = plistlib.load(stream)
with open(sys.argv[2], "rb") as stream:
    after = plistlib.load(stream)
for key in sorted(set(before) | set(after)):
    if before.get(key) != after.get(key):
        print("  正式域变化键名（不输出值）：", key)
PY
    fail "正式域 ${PROD_DOMAIN} 的全量 UserDefaults 前后不一致（测试或 Sparkle 写入了真实域？实际值不输出）"
fi

echo ""
echo "✅ Sparkle 升级链路 E2E 通过（Leg A 升级+重启存活；Leg B 通信活跃安全门阻断 + 强退后不自动重启；正式域全量设置未变）"
