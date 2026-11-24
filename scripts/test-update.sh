#!/bin/bash
# MatchSticks Driver Station Sparkle 本地升级链路 E2E（无硬件；Phase 4 安全链级验证；ADR-0004）
#
# Leg A（stable 渠道 + 双条目 appcast）：旧版 9.9.8 启动 → 真实探测确认升级源可达 → 静默检查 →
#   后台下载 → 就绪 → 点击（AUTOTAP）安全门现场求值放行 → Sparkle 终止并重启 → 新版本 **9.9.9** 存活；
#   日志中绝不出现 9.9.10——同一 appcast 里带 <sparkle:channel>beta</sparkle:channel> 的条目对 stable 不可见。
#   本 leg 无 sim，处于失能 + 未连接 + 无锁存的放行态。
# Leg D（beta 渠道 + 同一双条目 appcast）：独立设置 suite 预写 matchsticks.updateChannel=beta → 启动恢复 →
#   Sparkle allowedChannels 含 beta → 9.9.8 → **9.9.10**。覆盖「设置持久化 → 恢复 → allowedChannels →
#   appcast 过滤」的真实链路。
# Leg E（beta 渠道 + 仅 stable 条目的 appcast-stable-only.xml）：9.9.8 → **9.9.9**——beta 同时接收 stable。
# Leg C（网络不可用持续重试）：升级源在启动时**离线**（连接被拒）→ 旧版记录「GitHub 不可达，N 秒后重试」
#   并退避等待，期间**一次 Sparkle 检查都不发起**（日志无「GitHub 可达，开始检查更新」/「更新检查失败」，
#   mayPerform 闸门 + 先探测后检查）→ 升级源上线 → 退避到期重新探测成功 → 恰好一次「开始检查更新」→
#   自动检查、下载、就绪 → AUTOTAP 放行 → 9.9.9 存活。
# Leg B（通信活跃阻断 + 退出路径不自动重启）：旧版 9.9.8 连接本机模拟器（通信活跃）→
#   AUTOTAP 被安全门阻断（角标就绪但点击无效）；随后强退进程。Sparkle 的独立安装器
#   可能完成已挂起的安装（退出后版本可能变为 9.9.9），但不会自动重启应用——断言
#   「存活期版本不变」与「强退后无重启进程」。使能 / 急停锁存分支由 UpdateSafetyGate
#   全组合单测覆盖；本 E2E 只覆盖通信活跃这一真实阻塞态。
#
# 顺序：A 最先跑——C/D/E 升级后的进程都带 payload 的 LSEnvironment（写到 legA.log / support-A），
# A 先跑才能保证 A 对 legA.log 的「重启后继承测试环境」断言不是被别的 leg 的重启满足的。
#
# 隔离与清理：每次运行 mktemp 独立 WORK；不 pkill -x、不按宽匹配清进程，也不抢占
# 其他会话的 8123；前置发现已有 GHDS/MatchSticksDriverStaion/模拟器直接退出报告。测试副本的
# Info.plist 注入 LSEnvironment（LaunchServices 重启后仍继承测试设置）和 Sparkle 的
# SUDefaultsDomain（Sparkle 偏好也落测试 suite），随后重新 ad-hoc 签名；beta 渠道 leg 使用
# 第二个独立 suite（预写 updateChannel=beta）；正式域 org.ghfrc.driverstation 做全量 UserDefaults
# export 前后比较（不只 4 个键）。构建三个版本（9.9.8 / 9.9.9 / 9.9.10）比旧版多一次 build-app.sh。
set -euo pipefail
cd "$(dirname "$0")/.."
# 本机完整 Xcode（CLAUDE.md 工具链钉死；Xcode-beta 已不存在时回退 /Applications/Xcode.app，与 test-ui.sh 一致）
if [ -z "${DEVELOPER_DIR:-}" ]; then
  if [ -d /Applications/Xcode-beta.app ]; then
    DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
  elif [ -d /Applications/Xcode.app ]; then
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  fi
fi
export DEVELOPER_DIR

EXPECTED_PROD_BUNDLE=org.ghfrc.driverstation

# 测试隔离：每次运行生成唯一、合法的反 DNS suite 名，导出给被测进程。
# 新前缀 MATCHSTICKS_DRIVER_STAION_*；旧 GHDS_SETTINGS_SUITE 作为兼容 alias 一并导出，保证任何仍读旧名的
# 被测路径也落在隔离 suite 上。beta 渠道 leg 用第二个 suite（见 Leg D / E）。退出时只删本脚本创建的
# suite（含 cfprefsd 留下的空 plist），不碰正式域。
MATCHSTICKS_DRIVER_STAION_SETTINGS_SUITE="org.ghfrc.driverstation.test.update.$$.$(date +%Y%m%d%H%M%S).$RANDOM"
MATCHSTICKS_DRIVER_STATION_SETTINGS_SUITE="$MATCHSTICKS_DRIVER_STAION_SETTINGS_SUITE"
MATCHSTICKS_DS_SETTINGS_SUITE="$MATCHSTICKS_DRIVER_STAION_SETTINGS_SUITE"
GHDS_SETTINGS_SUITE="$MATCHSTICKS_DRIVER_STAION_SETTINGS_SUITE"
export MATCHSTICKS_DRIVER_STAION_SETTINGS_SUITE MATCHSTICKS_DRIVER_STATION_SETTINGS_SUITE MATCHSTICKS_DS_SETTINGS_SUITE GHDS_SETTINGS_SUITE
BETA_SETTINGS_SUITE="${MATCHSTICKS_DRIVER_STAION_SETTINGS_SUITE}.beta"
cleanup_settings_suite() {
    local suite
    for suite in "$MATCHSTICKS_DRIVER_STAION_SETTINGS_SUITE" "$BETA_SETTINGS_SUITE"; do
        case "$suite" in
            org.ghfrc.driverstation.test.*) ;;
            *) continue ;;
        esac
        defaults delete "$suite" >/dev/null 2>&1 || true
        rm -f "$HOME/Library/Preferences/$suite.plist" 2>/dev/null || true
    done
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
APP_C_PID=""
APP_D_PID=""
APP_E_PID=""

fail() { echo "✗ $1" >&2; exit 1; }

# 只按唯一 WORK 路径清理本测试启动的 app/sim，不碰其他会话。
work_app_pids() {
    [ -n "${WORK:-}" ] || return 0
    {
        pgrep -f "$WORK/.*/Contents/MacOS/MatchSticksDriverStaion" 2>/dev/null || true
        pgrep -f "$WORK/.*/Contents/MacOS/MatchSticksDriverStaionSim" 2>/dev/null || true
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
            "$TMP_BASE"/matchsticks-driver-staion-update-e2e.*) rm -rf -- "$WORK" ;;
        esac
    fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# 前置：不抢占真实使用或其他会话。发现即报告退出，不自动强杀。
require_no_existing_processes() {
    local name pids report=""
    for name in MatchSticksDriverStaion GHDS MatchSticksDriverStaionSim GHDSSim; do
        pids="$(pgrep -x "$name" 2>/dev/null || true)"
        if [ -n "$pids" ]; then
            report="${report}${report:+; }$name PID $(printf '%s' "$pids" | tr '\n' ' ')"
        fi
    done
    if [ -n "$report" ]; then
        fail "检测到已在运行的 GHDS/MatchSticksDriverStaion/模拟器进程：${report}。本测试不会强杀，请先退出后再跑。"
    fi
}
require_no_existing_processes

WORK="$(mktemp -d "$TMP_BASE/matchsticks-driver-staion-update-e2e.XXXXXX")"
mkdir -p "$WORK/web"
HTTP_REQUEST_LOG="$WORK/http-requests.log"

# 日志断言使用中文键：固定测试 suite 的语言，避免宿主系统语言把断言变成假失败。
# 新旧设置前缀都写（新版 matchsticks.*，兼容读取的旧 ghds.*），只落在隔离 suite。
# beta 渠道 leg（D / E）用第二个 suite，并像一次真实的设置写入那样预写 updateChannel=beta（新旧键）。
for suite in "$MATCHSTICKS_DRIVER_STAION_SETTINGS_SUITE" "$BETA_SETTINGS_SUITE"; do
    defaults write "$suite" matchsticks.language -string chinese
    defaults write "$suite" ghds.language -string chinese
done
defaults write "$BETA_SETTINGS_SUITE" matchsticks.updateChannel -string beta
defaults write "$BETA_SETTINGS_SUITE" ghds.updateChannel -string beta

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
echo "▶ 构建三个本地版本（9.9.8 旧版 / 9.9.9 stable / 9.9.10 beta，universal release）"
SU_PUBLIC_ED_KEY="$PUB" bash scripts/build-app.sh 9.9.8 >/dev/null
cp -R "dist/MatchSticks Driver Station.app" "$WORK/old.app"
SU_PUBLIC_ED_KEY="$PUB" bash scripts/build-app.sh 9.9.9 >/dev/null
cp -R "dist/MatchSticks Driver Station.app" "$WORK/new.app"
SU_PUBLIC_ED_KEY="$PUB" bash scripts/build-app.sh 9.9.10 >/dev/null
cp -R "dist/MatchSticks Driver Station.app" "$WORK/beta.app"

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
assert_no_downloader_service() {
    local app="$1"
    python3 - "$app/Contents/Info.plist" <<'PY' || fail "产物禁止包含 SUEnableDownloaderService（防止未来绕过进程内路由改走 XPC）：$app"
import plistlib
import sys

with open(sys.argv[1], "rb") as stream:
    info = plistlib.load(stream)
if "SUEnableDownloaderService" in info:
    sys.exit(1)
PY
}
assert_routing_hit() {
    local label="$1" logfile="$2" count
    count="$(grep -Ec "更新请求命中专用传输|Update request routed through dedicated transport" "$logfile" || true)"
    [ "${count:-0}" -ge 2 ] \
        || fail "$label：未证明生产 URLProtocol 实际命中 feed 与 enclosure（命中日志 ${count:-0}，要求至少 2）"
}
wait_for_support_log() {
    local label="$1" support="$2" timeout="${3:-30}" i=0 first
    while [ "$i" -lt "$timeout" ]; do
        first="$(find "$support/MatchSticksDriverStaion/Logs" -type f -name '*.dslog' -print -quit 2>/dev/null || true)"
        [ -n "$first" ] && return 0
        sleep 1
        i=$((i + 1))
    done
    fail "$label：${timeout}s 内测试支持目录未产生 .dslog（MATCHSTICKS_DRIVER_STAION_APPLICATION_SUPPORT 未生效？）"
}
assert_support_logs() {
    local label="$1" support="$2" first
    first="$(find "$support/MatchSticksDriverStaion/Logs" -type f -name '*.dslog' -print -quit 2>/dev/null || true)"
    [ -n "$first" ] \
        || fail "$label：测试支持目录未产生 .dslog（MATCHSTICKS_DRIVER_STAION_APPLICATION_SUPPORT 未生效？）"
}

# 测试副本专用：注入 LSEnvironment（Sparkle 用 LaunchServices 重启，shell 环境不会继承）
# 与 SUDefaultsDomain（Sparkle 自带偏好也写测试 suite），然后重新 ad-hoc 签名。
# 生产 .app 与 bundle ID 不变；这些键只存在于 WORK 内的副本。
prepare_leg_app() {
    local app="$1" support="$2" logfile="$3" delay="${4:-}" auto_sim="${5:-0}"
    local suite="${6:-$MATCHSTICKS_DRIVER_STAION_SETTINGS_SUITE}" feed_path="${7:-appcast.xml}"
    local feed_url="http://127.0.0.1:${FEED_PORT}/${feed_path}"
    local plist="$app/Contents/Info.plist"
    plutil -insert LSEnvironment -dictionary "$plist" 2>/dev/null \
        || plutil -replace LSEnvironment -dictionary "$plist" \
        || fail "写入 Info.plist 失败：$plist :: LSEnvironment"
    set_plist_string LSEnvironment.MATCHSTICKS_DRIVER_STAION_SETTINGS_SUITE "$suite" "$plist"
    set_plist_string LSEnvironment.MATCHSTICKS_DRIVER_STATION_SETTINGS_SUITE "$suite" "$plist"
    set_plist_string LSEnvironment.MATCHSTICKS_DS_SETTINGS_SUITE "$suite" "$plist"
    set_plist_string LSEnvironment.GHDS_SETTINGS_SUITE "$suite" "$plist"
    set_plist_string LSEnvironment.MATCHSTICKS_DRIVER_STAION_APPLICATION_SUPPORT "$support" "$plist"
    set_plist_string LSEnvironment.MATCHSTICKS_DRIVER_STAION_LOG_FILE "$logfile" "$plist"
    set_plist_string LSEnvironment.MATCHSTICKS_DRIVER_STAION_FEED_URL "$feed_url" "$plist"
    set_plist_string LSEnvironment.MATCHSTICKS_DRIVER_STAION_UPDATE_AUTOTAP "1" "$plist"
    # 新前缀显式置 0：若宿主 shell 残留旧 GHDS_DISABLE_UPDATE=1，新值仍优先。
    set_plist_string LSEnvironment.MATCHSTICKS_DRIVER_STAION_DISABLE_UPDATE "0" "$plist"
    if [ -n "$delay" ]; then
        set_plist_string LSEnvironment.MATCHSTICKS_DRIVER_STAION_UPDATE_AUTOTAP_DELAY "$delay" "$plist"
    fi
    if [ "$auto_sim" = "1" ]; then
        set_plist_string LSEnvironment.MATCHSTICKS_DRIVER_STAION_AUTO_SIM "1" "$plist"
    fi
    # 保险：即使某条重启路径没有继承环境，也不会去碰生产 appcast。
    set_plist_string SUFeedURL "$feed_url" "$plist"
    set_plist_string SUDefaultsDomain "$suite" "$plist"
    codesign --force --deep -s - "$app" >/dev/null 2>&1 \
        || fail "测试副本重新签名失败：$app"
    codesign --verify --deep --strict "$app" >/dev/null 2>&1 \
        || fail "测试副本签名校验失败：$app"
}

# 把已 prepare 的 payload 打成 zip、用测试密钥签名，并把 edSignature / length 写入全局 SIG / LEN（供 appcast）
sign_payload() { # $1=app 目录（已 prepare） $2=zip 文件名（位于 WORK）
    ( cd "$WORK" && ditto -c -k --sequesterRsrc --keepParent "$1" "$2" )
    local sigline
    sigline="$(swift scripts/sign-update.swift sign "$KEY" "$WORK/$2")"
    SIG="$(printf '%s' "$sigline" | sed -n 's/.*edSignature="\([^"]*\)".*/\1/p')"
    LEN="$(printf '%s' "$sigline" | sed -n 's/.*length="\([0-9]*\)".*/\1/p')"
    [ -n "$SIG" ] && [ -n "$LEN" ] || fail "签名输出解析失败：$sigline"
    cp "$WORK/$2" "$WORK/web/"
}

SUPPORT_A="$WORK/support-A"
SUPPORT_B="$WORK/support-B"
SUPPORT_C="$WORK/support-C"
SUPPORT_D="$WORK/support-D"
SUPPORT_E="$WORK/support-E"
mkdir -p "$SUPPORT_A" "$SUPPORT_B" "$SUPPORT_C" "$SUPPORT_D" "$SUPPORT_E"

assert_bundle_id "$WORK/old.app"
assert_bundle_id "$WORK/new.app"
assert_bundle_id "$WORK/beta.app"
assert_version "$WORK/old.app" 9.9.8
assert_version "$WORK/new.app" 9.9.9
assert_version "$WORK/beta.app" 9.9.10
for app in "$WORK/old.app" "$WORK/new.app" "$WORK/beta.app"; do assert_no_downloader_service "$app"; done

echo "▶ 记录正式域全量设置快照（${PROD_DOMAIN}，不输出实际值）"
BEFORE_PRODUCTION="$(snapshot_production_domain "$WORK/production-before.plist")"
for support in "$SUPPORT_A" "$SUPPORT_B" "$SUPPORT_C" "$SUPPORT_D" "$SUPPORT_E"; do
    [ -z "$(find "$support" -type f -print -quit 2>/dev/null)" ] \
        || fail "$support 支持根启动前已有文件（隔离失效）"
done

# 两份 payload（9.9.9 stable / 9.9.10 beta）都带 A 的 LSEnvironment：Sparkle 用 LaunchServices 重启后的
# 新进程仍落在测试 suite / 支持目录 / 日志文件（legA.log），绝不碰生产域。A 最先跑，所以 A 对 legA.log
# 的「重启后继承测试环境」断言只来自 A 自己的重启；C / D / E 的重启进程随后也写 legA.log，无人再断言它。
prepare_leg_app "$WORK/new.app" "$SUPPORT_A" "$WORK/legA.log"
prepare_leg_app "$WORK/beta.app" "$SUPPORT_A" "$WORK/legA.log"
# 旧版副本：A / C = stable 渠道 + 双条目 appcast；B = 通信活跃阻断（AUTOTAP 延时 12s + AUTO_SIM）；
# D = beta 渠道 + 双条目 appcast；E = beta 渠道 + 仅 stable 条目的 appcast。
cp -R "$WORK/old.app" "$WORK/MatchSticksDriverStaion-A.app"
prepare_leg_app "$WORK/MatchSticksDriverStaion-A.app" "$SUPPORT_A" "$WORK/legA.log"
cp -R "$WORK/old.app" "$WORK/MatchSticksDriverStaion-B.app"
prepare_leg_app "$WORK/MatchSticksDriverStaion-B.app" "$SUPPORT_B" "$WORK/legB.log" 12 1
cp -R "$WORK/old.app" "$WORK/MatchSticksDriverStaion-C.app"
prepare_leg_app "$WORK/MatchSticksDriverStaion-C.app" "$SUPPORT_C" "$WORK/legC.log"
cp -R "$WORK/old.app" "$WORK/MatchSticksDriverStaion-D.app"
prepare_leg_app "$WORK/MatchSticksDriverStaion-D.app" "$SUPPORT_D" "$WORK/legD.log" "" 0 "$BETA_SETTINGS_SUITE"
cp -R "$WORK/old.app" "$WORK/MatchSticksDriverStaion-E.app"
prepare_leg_app "$WORK/MatchSticksDriverStaion-E.app" "$SUPPORT_E" "$WORK/legE.log" "" 0 "$BETA_SETTINGS_SUITE" appcast-stable-only.xml
for app in A B C D E; do assert_bundle_id "$WORK/MatchSticksDriverStaion-$app.app"; done
assert_bundle_id "$WORK/new.app"
assert_bundle_id "$WORK/beta.app"
for app in A B C D E; do assert_no_downloader_service "$WORK/MatchSticksDriverStaion-$app.app"; done
assert_no_downloader_service "$WORK/new.app"
assert_no_downloader_service "$WORK/beta.app"

sign_payload new.app new-9.9.9.zip
STABLE_SIG="$SIG" STABLE_LEN="$LEN"
sign_payload beta.app new-9.9.10.zip
BETA_SIG="$SIG" BETA_LEN="$LEN"
NOW="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"
# 双条目 appcast：stable 条目不带 channel（默认渠道，所有客户端可见）；beta 条目带 sparkle:channel=beta。
cat > "$WORK/web/appcast.xml" <<APCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>MatchSticks Driver Station（本地升级链路测试）</title>
    <item>
      <title>版本 9.9.9（E2E stable 条目）</title>
      <sparkle:version>9.9.9</sparkle:version>
      <sparkle:shortVersionString>9.9.9</sparkle:shortVersionString>
      <pubDate>$NOW</pubDate>
      <enclosure url="http://127.0.0.1:${FEED_PORT}/new-9.9.9.zip" length="$STABLE_LEN" type="application/octet-stream" sparkle:edSignature="$STABLE_SIG" />
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
    </item>
    <item>
      <title>版本 9.9.10（E2E beta 条目）</title>
      <sparkle:version>9.9.10</sparkle:version>
      <sparkle:shortVersionString>9.9.10</sparkle:shortVersionString>
      <sparkle:channel>beta</sparkle:channel>
      <pubDate>$NOW</pubDate>
      <enclosure url="http://127.0.0.1:${FEED_PORT}/new-9.9.10.zip" length="$BETA_LEN" type="application/octet-stream" sparkle:edSignature="$BETA_SIG" />
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
    </item>
  </channel>
</rss>
APCAST
# 仅 stable 条目的 appcast：证明 beta 渠道客户端同样接收 stable（Leg E）。
cat > "$WORK/web/appcast-stable-only.xml" <<APCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>MatchSticks Driver Station（本地升级链路测试，仅 stable）</title>
    <item>
      <title>版本 9.9.9（E2E stable 条目）</title>
      <sparkle:version>9.9.9</sparkle:version>
      <sparkle:shortVersionString>9.9.9</sparkle:shortVersionString>
      <pubDate>$NOW</pubDate>
      <enclosure url="http://127.0.0.1:${FEED_PORT}/new-9.9.9.zip" length="$STABLE_LEN" type="application/octet-stream" sparkle:edSignature="$STABLE_SIG" />
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
    </item>
  </channel>
</rss>
APCAST

wait_log() { # $1=文件 $2=扩展正则 $3=超时秒
    local i=0
    while [ $i -lt "$3" ]; do
        grep -Eq "$2" "$1" 2>/dev/null && return 0
        sleep 2; i=$((i + 2))
    done
    return 1
}

start_feed_server() {
    python3 - "$FEED_PORT" "$WORK/web" "$HTTP_REQUEST_LOG" <<'PY' &
import functools
import http.server
import sys
import threading

port, directory, request_log = int(sys.argv[1]), sys.argv[2], sys.argv[3]
log_lock = threading.Lock()

class LoggingHandler(http.server.SimpleHTTPRequestHandler):
    def log_request_headers(self):
        with log_lock, open(request_log, "a", encoding="utf-8") as stream:
            stream.write(f"{self.command} {self.path} {self.request_version}\n")
            stream.write(str(self.headers))
            stream.write("\n")

    def do_GET(self):
        self.log_request_headers()
        super().do_GET()

    def do_HEAD(self):
        self.log_request_headers()
        super().do_HEAD()

handler = functools.partial(LoggingHandler, directory=directory)
server = http.server.ThreadingHTTPServer(("127.0.0.1", port), handler)
server.serve_forever()
PY
    HTTP_PID=$!
    sleep 1
    kill -0 "$HTTP_PID" 2>/dev/null \
        || fail "本地升级源未能在 127.0.0.1:${FEED_PORT} 启动（端口被抢占？）"
    curl -fsS --max-time 3 "http://127.0.0.1:${FEED_PORT}/appcast.xml" >/dev/null 2>&1 \
        || fail "本地升级源 127.0.0.1:${FEED_PORT} 未提供 appcast.xml"
    curl -fsS --max-time 3 "http://127.0.0.1:${FEED_PORT}/appcast-stable-only.xml" >/dev/null 2>&1 \
        || fail "本地升级源 127.0.0.1:${FEED_PORT} 未提供 appcast-stable-only.xml"
}

stop_feed_server() {
    if [ -n "${HTTP_PID:-}" ]; then
        kill -TERM "$HTTP_PID" 2>/dev/null || true
        wait "$HTTP_PID" 2>/dev/null || true
        HTTP_PID=""
    fi
    sleep 1   # 给内核释放监听套接字的时间；Leg C 依赖「连接被拒」而非「连接超时」
}

# 启动一个 leg 的旧版进程。测试钩子新旧名同时导出：MATCHSTICKS_DRIVER_STAION_* 为新前缀，GHDS_* 保留给仍读旧名的
# 兼容读取路径（两套取值一致，新前缀为准）。LSEnvironment 里也写了新前缀，供 Sparkle 重启后的进程继承。
# $1=leg 字母 $2=support 根 $3=日志 $4=设置 suite $5=feed 文件名；其余参数为追加的环境变量（KEY=VALUE）。
launch_leg() {
    local leg="$1" support="$2" logfile="$3" suite="$4" feed_path="$5"; shift 5
    env "MATCHSTICKS_DRIVER_STAION_SETTINGS_SUITE=$suite" \
        "MATCHSTICKS_DRIVER_STATION_SETTINGS_SUITE=$suite" \
        "MATCHSTICKS_DS_SETTINGS_SUITE=$suite" "GHDS_SETTINGS_SUITE=$suite" \
        "MATCHSTICKS_DRIVER_STAION_APPLICATION_SUPPORT=$support" \
        "MATCHSTICKS_DRIVER_STAION_LOG_FILE=$logfile" "GHDS_LOG_FILE=$logfile" \
        "MATCHSTICKS_DRIVER_STAION_FEED_URL=http://127.0.0.1:${FEED_PORT}/${feed_path}" \
        "GHDS_FEED_URL=http://127.0.0.1:${FEED_PORT}/${feed_path}" \
        "MATCHSTICKS_DRIVER_STAION_UPDATE_AUTOTAP=1" "GHDS_UPDATE_AUTOTAP=1" \
        "MATCHSTICKS_DRIVER_STAION_DISABLE_UPDATE=0" "$@" \
        "$WORK/MatchSticksDriverStaion-$leg.app/Contents/MacOS/MatchSticksDriverStaion" >/dev/null 2>&1 &
}

# 等待某 leg 的 bundle 被 Sparkle 替换成期望版本且新进程存活
wait_for_upgrade() { # $1=leg 字母 $2=期望版本 $3=超时秒
    local leg="$1" expected="$2" deadline=$((SECONDS + $3))
    while [ $SECONDS -lt $deadline ]; do
        if pgrep -f "$WORK/MatchSticksDriverStaion-$leg.app/Contents/MacOS/MatchSticksDriverStaion" >/dev/null 2>&1 \
           && [ "$(version_of "$WORK/MatchSticksDriverStaion-$leg.app")" = "$expected" ]; then return 0; fi
        sleep 2
    done
    return 1
}

stop_leg_app() { # $1=leg 字母；升级后进程必须能正常退出
    local leg="$1"
    stop_matching_app "$WORK/MatchSticksDriverStaion-$leg.app/Contents/MacOS/MatchSticksDriverStaion"
    pgrep -f "$WORK/MatchSticksDriverStaion-$leg.app/Contents/MacOS/MatchSticksDriverStaion" >/dev/null 2>&1 \
        && fail "Leg $leg：升级后的进程未退出"
    sleep 2
}

echo "▶ 启动本地升级源（双条目 appcast：stable 9.9.9 + beta 9.9.10；另备仅 stable 的 appcast-stable-only.xml）"
start_feed_server

echo "▶ Leg A：stable 渠道 + 双条目 appcast → 只升级到 9.9.9（beta 条目 9.9.10 对 stable 必须不可见；安全门放行态）"
launch_leg A "$SUPPORT_A" "$WORK/legA.log" "$MATCHSTICKS_DRIVER_STAION_SETTINGS_SUITE" appcast.xml
APP_A_PID=$!
wait_for_support_log "Leg A（首次启动）" "$SUPPORT_A"
wait_for_upgrade A 9.9.9 180 || { cat "$WORK/legA.log" 2>/dev/null; fail "Leg A：升级未完成（版本仍为 $(version_of "$WORK/MatchSticksDriverStaion-A.app")）"; }
pgrep -f "$WORK/MatchSticksDriverStaion-A.app/Contents/MacOS/MatchSticksDriverStaion" >/dev/null 2>&1 || { cat "$WORK/legA.log" 2>/dev/null; fail "Leg A：新版本进程未存活"; }
assert_bundle_id "$WORK/MatchSticksDriverStaion-A.app"
assert_version "$WORK/MatchSticksDriverStaion-A.app" 9.9.9
# Sparkle 用 LaunchServices 重启，shell 环境不会继承；LSEnvironment 是否生效由重启后的
# 9.9.9 进程仍写同一个隔离日志证明（生产支持目录/设置域不应被触碰）。A 最先跑，这一行只可能来自 A 的重启。
wait_log "$WORK/legA.log" "更新组件就绪（当前版本 9\.9\.9|Updater ready \(version 9\.9\.9" 30 \
    || { cat "$WORK/legA.log" 2>/dev/null; fail "Leg A：重启后的 9.9.9 进程未继承测试环境（LSEnvironment 未生效？）"; }
grep -Eq "渠道 stable|channel stable" "$WORK/legA.log" || fail "Leg A：未见 stable 渠道标识"
grep -Eq "发现新版本 9\.9\.9|New version 9\.9\.9 found" "$WORK/legA.log" || fail "Leg A：未见「发现新版本 9.9.9」日志"
! grep -Eq "9\.9\.10" "$WORK/legA.log" \
    || { cat "$WORK/legA.log"; fail "Leg A：stable 渠道看到了 beta 条目 9.9.10（allowedChannels 过滤失效）"; }
grep -Eq "下载就绪|Version 9.9.9 downloaded" "$WORK/legA.log" || fail "Leg A：未见「下载就绪」日志"
grep -Eq "安全门放行|safety gate open" "$WORK/legA.log" || fail "Leg A：未见「安全门放行」日志"
! grep -Eq "被安全门阻断|blocked by safety gate" "$WORK/legA.log" || fail "Leg A：放行态出现阻断日志（不应发生）"
assert_routing_hit "Leg A" "$WORK/legA.log"
assert_support_logs "Leg A" "$SUPPORT_A"
echo "  ✓ Leg A：stable 渠道 9.9.8 → 9.9.9 升级并重启存活，beta 条目 9.9.10 全程不可见，bundle ID 保持 ${EXPECTED_PROD_BUNDLE}"
stop_leg_app A

echo "▶ Leg D：beta 渠道（独立 suite 预写 matchsticks.updateChannel=beta）+ 同一双条目 appcast → 升级到 9.9.10"
launch_leg D "$SUPPORT_D" "$WORK/legD.log" "$BETA_SETTINGS_SUITE" appcast.xml
APP_D_PID=$!
wait_for_support_log "Leg D（首次启动）" "$SUPPORT_D"
wait_for_upgrade D 9.9.10 180 || { cat "$WORK/legD.log" 2>/dev/null; fail "Leg D：升级未完成（版本仍为 $(version_of "$WORK/MatchSticksDriverStaion-D.app")）"; }
pgrep -f "$WORK/MatchSticksDriverStaion-D.app/Contents/MacOS/MatchSticksDriverStaion" >/dev/null 2>&1 || { cat "$WORK/legD.log" 2>/dev/null; fail "Leg D：新版本进程未存活"; }
assert_bundle_id "$WORK/MatchSticksDriverStaion-D.app"
assert_version "$WORK/MatchSticksDriverStaion-D.app" 9.9.10
grep -Eq "渠道 beta|channel beta" "$WORK/legD.log" || { cat "$WORK/legD.log"; fail "Leg D：未见 beta 渠道标识（设置未恢复为 beta？）"; }
grep -Eq "发现新版本 9\.9\.10|New version 9\.9\.10 found" "$WORK/legD.log" || fail "Leg D：未见「发现新版本 9.9.10」日志（beta 条目对 beta 不可见？）"
grep -Eq "下载就绪|Version 9\.9\.10 downloaded" "$WORK/legD.log" || fail "Leg D：未见「下载就绪」日志"
grep -Eq "安全门放行|safety gate open" "$WORK/legD.log" || fail "Leg D：未见「安全门放行」日志"
! grep -Eq "被安全门阻断|blocked by safety gate" "$WORK/legD.log" || fail "Leg D：放行态出现阻断日志（不应发生）"
assert_routing_hit "Leg D" "$WORK/legD.log"
assert_support_logs "Leg D" "$SUPPORT_D"
echo "  ✓ Leg D：beta 渠道 9.9.8 → 9.9.10：设置持久化 → 启动恢复 → allowedChannels → appcast 过滤链路真实生效"
stop_leg_app D

echo "▶ Leg E：beta 渠道 + 仅 stable 条目的 appcast-stable-only.xml → 升级到 9.9.9（beta 同时接收 stable）"
launch_leg E "$SUPPORT_E" "$WORK/legE.log" "$BETA_SETTINGS_SUITE" appcast-stable-only.xml
APP_E_PID=$!
wait_for_support_log "Leg E（首次启动）" "$SUPPORT_E"
wait_for_upgrade E 9.9.9 180 || { cat "$WORK/legE.log" 2>/dev/null; fail "Leg E：升级未完成（版本仍为 $(version_of "$WORK/MatchSticksDriverStaion-E.app")）"; }
pgrep -f "$WORK/MatchSticksDriverStaion-E.app/Contents/MacOS/MatchSticksDriverStaion" >/dev/null 2>&1 || { cat "$WORK/legE.log" 2>/dev/null; fail "Leg E：新版本进程未存活"; }
assert_bundle_id "$WORK/MatchSticksDriverStaion-E.app"
assert_version "$WORK/MatchSticksDriverStaion-E.app" 9.9.9
grep -Eq "渠道 beta|channel beta" "$WORK/legE.log" || { cat "$WORK/legE.log"; fail "Leg E：未见 beta 渠道标识"; }
grep -Eq "发现新版本 9\.9\.9|New version 9\.9\.9 found" "$WORK/legE.log" || fail "Leg E：未见「发现新版本 9.9.9」日志（beta 渠道收不到 stable？）"
grep -Eq "下载就绪|Version 9\.9\.9 downloaded" "$WORK/legE.log" || fail "Leg E：未见「下载就绪」日志"
grep -Eq "安全门放行|safety gate open" "$WORK/legE.log" || fail "Leg E：未见「安全门放行」日志"
! grep -Eq "被安全门阻断|blocked by safety gate" "$WORK/legE.log" || fail "Leg E：放行态出现阻断日志（不应发生）"
assert_routing_hit "Leg E" "$WORK/legE.log"
assert_support_logs "Leg E" "$SUPPORT_E"
echo "  ✓ Leg E：beta 渠道从仅 stable 的 appcast 升级到 9.9.9（默认渠道永远包含在允许集合内）"
stop_leg_app E

stop_feed_server
echo "▶ Leg C：升级源离线启动 → 退避重试且零 Sparkle 检查 → 升级源上线后恰好一次检查并自动升级"
# 升级源已关闭：首次探测「连接被拒」→ 记录「GitHub 不可达，N 秒后重试」并退避等待。
# 离线期间的真实证据：日志里没有任何一次「GitHub 可达，开始检查更新」（只在 checkForUpdatesInBackground
# 真正发出前写）与「更新检查失败」（Sparkle 周期失败收尾）——Sparkle 一次检查都没发起。
launch_leg C "$SUPPORT_C" "$WORK/legC.log" "$MATCHSTICKS_DRIVER_STAION_SETTINGS_SUITE" appcast.xml
APP_C_PID=$!
wait_for_support_log "Leg C（首次启动）" "$SUPPORT_C"
wait_log "$WORK/legC.log" "GitHub 不可达|GitHub unreachable" 30 \
    || { cat "$WORK/legC.log" 2>/dev/null; fail "Leg C：30s 内未见「GitHub 不可达」重试日志（可达探测未生效？）"; }
sleep 3   # 再跨过一个 3s 退避周期：期间仍只会有「不可达」重试日志
grep -Eq "GitHub 不可达|GitHub unreachable" "$WORK/legC.log" || fail "Leg C：退避到期后未再次探测"
! grep -Eq "GitHub 可达，开始检查更新|GitHub reachable; checking for updates" "$WORK/legC.log" \
    || { cat "$WORK/legC.log"; fail "Leg C：升级源离线期间发起了 Sparkle 检查（先探测后检查 / mayPerform 闸门失效）"; }
! grep -Eq "更新检查失败|Update check failed|发现新版本|New version .* found" "$WORK/legC.log" \
    || { cat "$WORK/legC.log"; fail "Leg C：升级源离线期间不应有任何检查结果日志（闸门失效）"; }
[ "$(version_of "$WORK/MatchSticksDriverStaion-C.app")" = "9.9.8" ] || fail "Leg C：离线期间版本被改写"

start_feed_server
wait_for_upgrade C 9.9.9 180 || { cat "$WORK/legC.log" 2>/dev/null; fail "Leg C：升级源上线后未自动重试完成升级（版本仍为 $(version_of "$WORK/MatchSticksDriverStaion-C.app")）"; }
pgrep -f "$WORK/MatchSticksDriverStaion-C.app/Contents/MacOS/MatchSticksDriverStaion" >/dev/null 2>&1 || { cat "$WORK/legC.log" 2>/dev/null; fail "Leg C：新版本进程未存活"; }
assert_bundle_id "$WORK/MatchSticksDriverStaion-C.app"
assert_version "$WORK/MatchSticksDriverStaion-C.app" 9.9.9
CHECK_STARTS="$(grep -Ec "GitHub 可达，开始检查更新|GitHub reachable; checking for updates" "$WORK/legC.log" || true)"
[ "$CHECK_STARTS" = "1" ] \
    || { cat "$WORK/legC.log"; fail "Leg C：上线后应恰好发起一次检查（实际 ${CHECK_STARTS} 次；0 = 未自动检查，>1 = 重复检查）"; }
grep -Eq "发现新版本 9\.9\.9|New version 9.9.9 found" "$WORK/legC.log" || fail "Leg C：未见「发现新版本 9.9.9」日志"
grep -Eq "下载就绪|Version 9\.9\.9 downloaded" "$WORK/legC.log" || fail "Leg C：未见「下载就绪」日志"
grep -Eq "安全门放行|safety gate open" "$WORK/legC.log" || fail "Leg C：未见「安全门放行」日志"
! grep -Eq "被安全门阻断|blocked by safety gate" "$WORK/legC.log" || fail "Leg C：放行态出现阻断日志（不应发生）"
assert_routing_hit "Leg C" "$WORK/legC.log"
assert_support_logs "Leg C" "$SUPPORT_C"
echo "  ✓ Leg C：升级源离线期间零 Sparkle 检查、只退避重试；上线后恰好一次检查并自动下载、就绪、重启到 9.9.9"
stop_leg_app C

echo "▶ Leg B：通信活跃安全门阻断 + 强退后不自动重启"
"$WORK/new.app/Contents/MacOS/MatchSticksDriverStaionSim" --quiet >/dev/null 2>&1 &
SIM_PID=$!
sleep 1
# appcast 从一开始就在线；AUTOTAP 延时 12s 再替点——sim 连接 ~2s 内建立，
# 点击时必为「通信活跃」态（真实点击时刻现场求值，不依赖重试周期）
MATCHSTICKS_DRIVER_STAION_APPLICATION_SUPPORT="$SUPPORT_B" \
MATCHSTICKS_DRIVER_STAION_LOG_FILE="$WORK/legB.log" GHDS_LOG_FILE="$WORK/legB.log" \
MATCHSTICKS_DRIVER_STAION_FEED_URL="http://127.0.0.1:${FEED_PORT}/appcast.xml" GHDS_FEED_URL="http://127.0.0.1:${FEED_PORT}/appcast.xml" \
MATCHSTICKS_DRIVER_STAION_UPDATE_AUTOTAP=1 GHDS_UPDATE_AUTOTAP=1 \
MATCHSTICKS_DRIVER_STAION_UPDATE_AUTOTAP_DELAY=12 GHDS_UPDATE_AUTOTAP_DELAY=12 \
MATCHSTICKS_DRIVER_STAION_AUTO_SIM=1 GHDS_AUTO_SIM=1 \
MATCHSTICKS_DRIVER_STAION_DISABLE_UPDATE=0 \
  "$WORK/MatchSticksDriverStaion-B.app/Contents/MacOS/MatchSticksDriverStaion" >/dev/null 2>&1 &
APP_B_PID=$!
wait_for_support_log "Leg B（首次启动）" "$SUPPORT_B"
wait_log "$WORK/legB.log" "收到版本信息|Version info received" 20 || { cat "$WORK/legB.log" 2>/dev/null; fail "Leg B：20s 内未见 TCP 版本信息（未连上模拟器）"; }
wait_log "$WORK/legB.log" "下载就绪|Version .* downloaded" 60 || { cat "$WORK/legB.log" 2>/dev/null; fail "Leg B：60s 内未见下载就绪"; }
wait_log "$WORK/legB.log" "被安全门阻断|blocked by safety gate" 30 || { cat "$WORK/legB.log" 2>/dev/null; fail "Leg B：延时 AUTOTAP 未被安全门阻断"; }
grep -E "被安全门阻断|blocked by safety gate" "$WORK/legB.log" | sed -n '1p' | grep -Eq "通信|Comms active|communication active" || { cat "$WORK/legB.log"; fail "Leg B：阻断原因不是通信活跃"; }
! grep -Eq "安全门放行|safety gate open" "$WORK/legB.log" || fail "Leg B：连接态出现放行日志（不应发生）"
# 存活期契约：阻断后版本必须不变（活进程期间安装的唯一触发 = 点击 + 安全门放行）
sleep 2
[ "$(version_of "$WORK/MatchSticksDriverStaion-B.app")" = "9.9.8" ] || fail "Leg B：阻断后存活期间版本被改为 $(version_of "$WORK/MatchSticksDriverStaion-B.app")"
assert_routing_hit "Leg B" "$WORK/legB.log"
assert_support_logs "Leg B" "$SUPPORT_B"
stop_pid "$APP_B_PID" 20
wait "$APP_B_PID" 2>/dev/null || true
kill -0 "$APP_B_PID" 2>/dev/null && fail "Leg B：进程未被强退"
sleep 5
# 退出路径契约（Sparkle 固有行为，实测确认）：宿主进程死亡后安装器可能完成挂起的安装
# （版本可能变为 9.9.9），但绝不自动重启应用；机器人侧看门狗在进程死亡瞬间已失能输出，
# 完成安装不产生新风险。这里断言的是「无重启进程」，不要求退出后版本仍为 9.9.8。
if pgrep -f "$WORK/MatchSticksDriverStaion-B.app/Contents/MacOS/MatchSticksDriverStaion" >/dev/null 2>&1; then
    fail "Leg B：进程死亡后应用被自动重启（不应发生）"
fi
# B 的安装包可能仍在被独立安装器替换；不在这里读 Info.plist，避免与安装写盘竞态。
# bundle ID 已在构建版本、A/B 启动前和升级后的 A 上断言。
AFTER_B_VERSION="$(version_of "$WORK/MatchSticksDriverStaion-B.app" 2>/dev/null || echo "安装器仍在完成")"
echo "  ✓ Leg B：通信活跃阻断点击安装；存活期版本不变；强退后无自动重启（Sparkle 可能已完成挂起安装，退出后版本=${AFTER_B_VERSION}；使能/急停分支由单测覆盖）"

stop_pid "$SIM_PID"
SIM_PID=""
stop_work_processes
[ -s "$HTTP_REQUEST_LOG" ] || fail "本地升级源未记录任何请求行与 headers"
grep -Eq '^GET /appcast\.xml HTTP/' "$HTTP_REQUEST_LOG" \
    || fail "本地源站未收到真实 appcast GET（feed 请求未到达？）"
grep -Eq '^GET /appcast-stable-only\.xml HTTP/' "$HTTP_REQUEST_LOG" \
    || fail "本地源站未收到 Leg E 的 stable-only appcast GET"
grep -Eq '^GET /new-9\.9\.9\.zip HTTP/' "$HTTP_REQUEST_LOG" \
    || fail "本地源站未收到 stable enclosure GET"
grep -Eq '^GET /new-9\.9\.10\.zip HTTP/' "$HTTP_REQUEST_LOG" \
    || fail "本地源站未收到 beta enclosure GET"
if grep -Eiq 'matchsticksds_update_request=|matchsticksds-update-request:|authorization:|proxy-authorization:|cookie:' "$HTTP_REQUEST_LOG"; then
    fail "本地源站日志发现 query/header token、Authorization 或 Cookie（不输出敏感值）"
fi
if grep -Eiq 'matchsticksds_update_request=|matchsticksds-update-request:|authorization:|cookie:' "$WORK"/leg*.log; then
    fail "App 日志发现 update token、Authorization 或 Cookie（不输出敏感值）"
fi
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
echo "✅ Sparkle 升级链路 E2E 通过（Leg A stable→9.9.9 且 beta 条目不可见；Leg D beta→9.9.10；Leg E beta 收 stable；Leg C 离线零检查、上线后自动重试升级；Leg B 通信活跃安全门阻断 + 强退后不自动重启；生产 URLProtocol 实际命中且源站零 token/凭证；正式域全量设置未变）"
