#!/bin/bash
# MatchSticks DS 打包版 E2E（无硬件；本地运行，依赖本机 GUI/端口环境）
#
# 判活与台前防污染断言（2026-09-16 教训：不能只看 TCP 建链）：
#   ① 打包版进程存活整个观测窗；
#   ② 控制环吞吐汇总行持续出现且频率 ≥ 下限（控制包真在按节拍发）；
#   ③ WebUI /api/status 报 commState=connected（127.0.0.1:6768）；
#   ④ 模拟 radio:8080 触发应用层「Radio 状态：已响应」事件；
#   ⑤ 本次新建的 MATCHSTICKS_DS_APPLICATION_SUPPORT 支持目录出现新会话日志
#      （按本次启动时间校验 mtime，迁移来的旧日志不能冒充通过证据）；
#   ⑥ 正式域 org.ghfrc.driverstation 全量 UserDefaults 键级前后一致（不只看 4 个键）：只有 AppKit 为
#      SwiftUI Window 场景自动持久化的 NSWindow Frame main/mini 允许变化并单独报告，其余任何键变化都失败。
# 全部产物来自 build-app.sh 打出的 .app（含包内 MatchSticksDSSim）。
#
# 隔离与清理：每次运行 mktemp 独立 WORK；前置发现已有的 MatchSticksDS / GHDS /
# 模拟器进程直接退出报告，绝不 pkill -x 或按宽匹配抢占；结束只清理由本脚本记录
# 的 PID 或唯一 WORK 路径下的进程。测试设置只写 org.ghfrc.driverstation.test.* suite。
#
# 用法：bash scripts/test-e2e.sh
# 可调：MATCHSTICKS_DS_E2E_HZ_FLOOR（默认 40——本机控制环 50Hz；慢机器场景用 8）
set -euo pipefail
cd "$(dirname "$0")/.."
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
export DEVELOPER_DIR
HZ_FLOOR="${MATCHSTICKS_DS_E2E_HZ_FLOOR:-${GHDS_E2E_HZ_FLOOR:-40}}"

# 测试隔离：每次运行生成唯一、合法的反 DNS suite 名，导出给被测进程。
# 新前缀 MATCHSTICKS_DS_*；旧 GHDS_SETTINGS_SUITE 作为兼容 alias 一并导出，保证任何仍读旧名的
# 被测路径也落在隔离 suite 上。退出时只删本脚本创建的 suite（含 cfprefsd 留下的空 plist），
# 不碰正式域。
MATCHSTICKS_DS_SETTINGS_SUITE="org.ghfrc.driverstation.test.e2e.$$.$(date +%Y%m%d%H%M%S).$RANDOM"
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
SUPPORT_ROOT=""
APP_PID=""
SIM_PID=""

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
cleanup() {
    stop_work_processes
    cleanup_settings_suite
    if [ -n "${WORK:-}" ]; then
        case "$WORK" in
            "$TMP_BASE"/matchsticks-ds-packaged-e2e.*) rm -rf -- "$WORK" ;;
        esac
    fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

fail() { echo "✗ $1" >&2; exit 1; }

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

WORK="$(mktemp -d "$TMP_BASE/matchsticks-ds-packaged-e2e.XXXXXX")"
SUPPORT_ROOT="$WORK/support"
mkdir -p "$SUPPORT_ROOT"

# 日志断言使用中文键：固定测试 suite 的语言，避免宿主系统语言把断言变成假失败。
# 新旧设置前缀都写（新版 matchsticks.*，兼容读取的旧 ghds.*），只落在隔离 suite。
defaults write "$MATCHSTICKS_DS_SETTINGS_SUITE" matchsticks.language -string chinese
defaults write "$MATCHSTICKS_DS_SETTINGS_SUITE" ghds.language -string chinese

echo "▶ 打包（universal release + ad-hoc 签名 + dmg）"
bash scripts/build-app.sh "${MATCHSTICKS_DS_E2E_VERSION:-${GHDS_E2E_VERSION:-0.0.0-e2etest}}" >/dev/null
cp -R "dist/MatchSticks DS.app" "$WORK/MatchSticksDS-E2E.app"

# 在任何被测进程写入设置前确定正式域：从 Info.plist 读取并要求等于预期生产 bundle ID。
EXPECTED_PROD_DOMAIN=org.ghfrc.driverstation
PROD_DOMAIN="$(plutil -extract CFBundleIdentifier raw "$WORK/MatchSticksDS-E2E.app/Contents/Info.plist" 2>/dev/null || true)"
[ -n "$PROD_DOMAIN" ] || fail "无法从打包 app 读取 CFBundleIdentifier"
[ "$PROD_DOMAIN" = "$EXPECTED_PROD_DOMAIN" ] || fail "打包 app 的 CFBundleIdentifier=${PROD_DOMAIN}，预期 ${EXPECTED_PROD_DOMAIN}（正式域断言会失真）"

# 正式域全量快照：export 整个域到 WORK 里的 plist（覆盖所有键，含 Sparkle 键与未来新增键），
# 结束时交给 scripts/defaults-domain-diff.py 做键级比较；任何实际值都不输出。
# 域不存在时 export 为空 plist，前后同样比较；导出失败则明确失败。
snapshot_production_domain() {
    defaults export "$PROD_DOMAIN" "$1" 2>/dev/null \
        || fail "无法完整导出正式域 ${PROD_DOMAIN}（全量快照不可用）"
}

# 启动前支持根必须为空：之后出现的任何文件都属于本次运行；旧迁移日志若被复制进来，
# 会因 mtime 早于本次启动而失败，不能假绿。
[ -z "$(find "$SUPPORT_ROOT" -type f -print -quit 2>/dev/null)" ] \
    || fail "新支持根 $SUPPORT_ROOT 启动前已有文件（隔离失效）"

echo "▶ 记录正式域全量设置快照（${PROD_DOMAIN}，不输出实际值）"
snapshot_production_domain "$WORK/production-before.plist"

echo "▶ 启动包内 MatchSticksDSSim + 打包版 app（AUTO_SIM 连 127.0.0.1，radio 端口 8080）"
"$WORK/MatchSticksDS-E2E.app/Contents/MacOS/MatchSticksDSSim" --quiet --radio-port 8080 >/dev/null 2>&1 &
SIM_PID=$!
sleep 1

# 支持目录隔离：MATCHSTICKS_DS_APPLICATION_SUPPORT 覆盖 Application Support 根，
# 应用实际写入 $SUPPORT_ROOT/MatchSticksDS/…，不读写真实用户日志。
# 测试钩子新旧名同时导出：MATCHSTICKS_DS_* 为新前缀，GHDS_* 保留给仍读旧名的兼容读取路径；
# 两套取值一致，测试语义以新前缀为准。
RUN_START_EPOCH="$(date +%s)"
MATCHSTICKS_DS_APPLICATION_SUPPORT="$SUPPORT_ROOT" \
MATCHSTICKS_DS_LOG_FILE="$WORK/e2e.log" GHDS_LOG_FILE="$WORK/e2e.log" \
MATCHSTICKS_DS_AUTO_SIM=1 GHDS_AUTO_SIM=1 \
MATCHSTICKS_DS_DISABLE_UPDATE=1 GHDS_DISABLE_UPDATE=1 \
  "$WORK/MatchSticksDS-E2E.app/Contents/MacOS/MatchSticksDS" >/dev/null 2>&1 &
APP_PID=$!

# 尽早确认支持目录隔离生效：若 MATCHSTICKS_DS_APPLICATION_SUPPORT 被忽略，
# 应用已经开始写真实用户日志；这里在进入长观测窗前就失败，避免继续污染。
wait_for_support_log() {
    local i=0 first
    while [ "$i" -lt 30 ]; do
        first="$(find "$SUPPORT_ROOT/MatchSticksDS/Logs" -type f -name '*.dslog' -print -quit 2>/dev/null || true)"
        [ -n "$first" ] && return 0
        kill -0 "$APP_PID" 2>/dev/null || fail "打包版进程启动后立即退出"
        sleep 1
        i=$((i + 1))
    done
    fail "30s 内新支持目录未产生 .dslog（MATCHSTICKS_DS_APPLICATION_SUPPORT 未生效？）"
}
wait_for_support_log

stop_packaged_app() {
    [ -n "${APP_PID:-}" ] || return 0
    kill -TERM "$APP_PID" 2>/dev/null || true
    local i=0
    while [ "$i" -lt 20 ] && kill -0 "$APP_PID" 2>/dev/null; do
        sleep 0.25
        i=$((i + 1))
    done
    kill -9 "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
    sleep 1  # 等 cfprefsd 结算 app 已完成的偏好写入
}
stop_simulator() {
    [ -n "${SIM_PID:-}" ] || return 0
    kill -TERM "$SIM_PID" 2>/dev/null || true
    local i=0
    while [ "$i" -lt 20 ] && kill -0 "$SIM_PID" 2>/dev/null; do
        sleep 0.25
        i=$((i + 1))
    done
    kill -9 "$SIM_PID" 2>/dev/null || true
    wait "$SIM_PID" 2>/dev/null || true
    SIM_PID=""
}

echo "▶ 等待建链（WebUI /api/status，≤30s）"
CONNECTED=0
for i in $(seq 1 15); do
    STATUS="$(curl -s --max-time 2 http://127.0.0.1:6768/api/status 2>/dev/null || true)"
    if printf '%s' "$STATUS" | grep -q '"commState":"connected'; then CONNECTED=1; break; fi
    sleep 2
done
[ "$CONNECTED" = "1" ] || { cat "$WORK/e2e.log" 2>/dev/null | grep -v "UI stall" | tail -10; fail "30s 内未通过 /api/status 观测到 connected"; }
echo "  ✓ /api_status connected"

echo "▶ 观测窗 25s（进程存活 + 吞吐汇总行 ≥ ${HZ_FLOOR}Hz）"
DEADLINE=$((SECONDS + 25))
while [ $SECONDS -lt $DEADLINE ]; do
    kill -0 "$APP_PID" 2>/dev/null || fail "打包版进程中途退出（判活失败）"
    kill -0 "$SIM_PID" 2>/dev/null || fail "模拟器进程中途退出"
    sleep 5
done
kill -0 "$APP_PID" 2>/dev/null || fail "观测窗结束时进程已退出"
echo "  ✓ 进程全程存活"

echo "▶ Radio 可达性断言（MatchSticksDSSim --radio-port 8080）"
# 不杀模拟器制造离线：只读日志，离线场景由单元测试覆盖
grep -Eq "Radio 状态：已响应|Radio status: responding" "$WORK/e2e.log" 2>/dev/null || {
    grep "Radio" "$WORK/e2e.log" 2>/dev/null | tail -5
    fail "e2e.log 未见「Radio 状态：已响应」（radio 端口 8080 未生效？）"
}
echo "  ✓ Radio 状态：已响应"

LINES="$(grep -E "控制环吞吐：|Control loop throughput:" "$WORK/e2e.log" 2>/dev/null || true)"
[ -n "$LINES" ] || { grep -v "UI stall" "$WORK/e2e.log" 2>/dev/null | tail -8; fail "未见吞吐汇总行（控制包未按节拍发？）"; }
COUNT="$(printf '%s\n' "$LINES" | wc -l | tr -d ' ')"
MIN_HZ="$(printf '%s\n' "$LINES" | sed -E -n 's/.*(吞吐：|throughput: )([0-9.]+) Hz.*/\2/p' | sort -g | sed -n '1p')"
echo "  ✓ 吞吐汇总行 ${COUNT} 条，最低 ${MIN_HZ} Hz"
awk -v hz="$MIN_HZ" -v floor="$HZ_FLOOR" 'BEGIN { exit (hz+0 >= floor+0) ? 0 : 1 }' \
    || fail "吞吐 ${MIN_HZ}Hz 低于下限 ${HZ_FLOOR}Hz"

echo "▶ 日志落盘检查（/api/logs + 本次新支持目录）"
LOGS="$(curl -s --max-time 3 http://127.0.0.1:6768/api/logs 2>/dev/null || true)"
printf '%s' "$LOGS" | grep -q '"name"' || fail "打包版未产生日志文件（/api/logs 为空）"

SESSION_LOG_DIR="$SUPPORT_ROOT/MatchSticksDS/Logs"
FIRST_SUPPORT_LOG="$(find "$SESSION_LOG_DIR" -type f \( -name '*.dslog' -o -name '*.wpilog' \) -print -quit 2>/dev/null || true)"
[ -n "$FIRST_SUPPORT_LOG" ] \
    || fail "本次新支持目录未产生 .dslog/.wpilog（${SESSION_LOG_DIR}；MATCHSTICKS_DS_APPLICATION_SUPPORT 未生效？）"
HAS_DSLOG=0
HAS_WPILOG=0
MATCHED_API_NAME=0
while IFS= read -r logfile; do
    [ -n "$logfile" ] || continue
    mtime="$(stat -f %m "$logfile" 2>/dev/null || echo 0)"
    [ "$mtime" -ge "$RUN_START_EPOCH" ] \
        || fail "新支持目录出现早于本次启动的旧日志：$(basename "$logfile")（迁移日志不能作为通过证据）"
    case "$logfile" in
        *.dslog) HAS_DSLOG=1 ;;
        *.wpilog) HAS_WPILOG=1 ;;
    esac
    if printf '%s' "$LOGS" | grep -Fq "$(basename "$logfile")"; then MATCHED_API_NAME=1; fi
done <<EOF_LOGS
$(find "$SESSION_LOG_DIR" -type f \( -name '*.dslog' -o -name '*.wpilog' \) 2>/dev/null | sort)
EOF_LOGS
[ "$HAS_DSLOG" = "1" ] || fail "本次新支持目录未见 .dslog 会话日志"
[ "$HAS_WPILOG" = "1" ] || fail "本次新支持目录未见 .wpilog 会话日志"
[ "$MATCHED_API_NAME" = "1" ] || fail "/api/logs 未列出本次新支持目录中的日志（日志目录未隔离？）"
echo "  ✓ 本次新支持目录已落盘 .dslog + .wpilog，且 /api/logs 列出同一批文件"

# 先停进程再读正式域：确保 app 的设置写入已结算，不会在比较之后才落盘。
echo "▶ 停打包版并核对正式域全量设置未被测试改动（键级比较，只输出变化键名）"
stop_packaged_app
if kill -0 "$APP_PID" 2>/dev/null; then fail "打包版进程未在停止阶段退出"; fi
stop_simulator
stop_work_processes
snapshot_production_domain "$WORK/production-after.plist"
# 键级比较：打包 app 与正式版同一个 bundle id，SwiftUI Window 场景（main/mini）的窗口框架由 AppKit
# 写进 UserDefaults.standard 的 NSWindow Frame <场景 id>，测试 suite 隔离覆盖不到这一层——这两个键
# 允许变化并逐键单独报告（allowed: 行）。其余任何键（matchsticks.*/ghds.*/SU* 及未来新增键）变化、
# 新增或删除仍然失败，并在上面以 changed: 行列出键名；任何实际值都不输出。
set +e
python3 scripts/defaults-domain-diff.py "$WORK/production-before.plist" "$WORK/production-after.plist" \
    --allow "NSWindow Frame main" --allow "NSWindow Frame mini"
DOMAIN_DIFF_RC=$?
set -e
case "$DOMAIN_DIFF_RC" in
    0) ;;
    2) fail "正式域快照无法比较（plist 解析失败，见上）" ;;
    *) fail "正式域 ${PROD_DOMAIN} 存在 AppKit 窗口框架键之外的变化（测试写入了真实域？变化键名见上，实际值不输出）" ;;
esac
echo "  ✓ 正式域 ${PROD_DOMAIN} 除 AppKit 窗口框架键外全部一致（框架键变化已逐键报告，实际值不输出）"

echo ""
echo "✅ 打包版 E2E 通过：进程存活 + 控制环吞吐 ≥ ${HZ_FLOOR}Hz + connected + radio 已响应 + 本次新支持目录日志 + 正式域除 AppKit 窗口框架键外未变"
