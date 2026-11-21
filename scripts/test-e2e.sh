#!/bin/bash
# 打包版 E2E（无硬件；本地运行，依赖本机 GUI/端口环境）
#
# 判活与台前防污染断言（2026-09-16 教训：不能只看 TCP 建链）：
#   ① 打包版进程存活整个观测窗；
#   ② 控制环吞吐汇总行持续出现且频率 ≥ 下限（控制包真在按节拍发）；
#   ③ WebUI /api/status 报 commState=connected（127.0.0.1:6768）；
#   ④ 模拟 radio:8080 触发应用层「Radio 状态：已响应」事件；
#   ⑤ 会话日志落盘；
#   ⑥ 测试前后正式域 manualIP / 队号不变（测试设置走隔离 suite）。
# 全部产物来自 build-app.sh 打出的 .app（含包内 GHDSSim）。
#
# 用法：bash scripts/test-e2e.sh
# 可调：GHDS_E2E_HZ_FLOOR（默认 40——本机控制环 50Hz；慢机器场景用 8）
set -euo pipefail
cd "$(dirname "$0")/.."
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
export DEVELOPER_DIR
HZ_FLOOR="${GHDS_E2E_HZ_FLOOR:-40}"

# 测试隔离：每次运行生成唯一、合法的反 DNS suite 名，导出给被测进程；
# 退出时只删本脚本创建的 suite（含 cfprefsd 留下的空 plist），不碰正式域。
GHDS_SETTINGS_SUITE="org.ghfrc.driverstation.test.e2e.$$.$(date +%Y%m%d%H%M%S).$RANDOM"
export GHDS_SETTINGS_SUITE
cleanup_settings_suite() {
    local suite="${GHDS_SETTINGS_SUITE:-}"
    case "$suite" in
        org.ghfrc.driverstation.test.*) ;;
        *) return 0 ;;
    esac
    defaults delete "$suite" >/dev/null 2>&1 || true
    rm -f "$HOME/Library/Preferences/$suite.plist" 2>/dev/null || true
}

# 正式域只做前后比较：缺失键用哨兵，存在值带类型标记；任何实际值都不输出。
PROD_DOMAIN=org.ghfrc.driverstation
MISSING_SENTINEL='__GHDS_KEY_MISSING__'
production_setting() {
    local key="$1" kind value
    if ! kind="$(defaults read-type "$PROD_DOMAIN" "$key" 2>/dev/null)"; then
        printf '%s' "$MISSING_SENTINEL"
        return 0
    fi
    if ! value="$(defaults read "$PROD_DOMAIN" "$key" 2>/dev/null)"; then
        printf '%s' "$MISSING_SENTINEL"
        return 0
    fi
    printf 'present:%s\n%s' "$kind" "$value"
}

WORK=/tmp/ghds-packaged-e2e
SIM_PID=""
APP_PID=""
cleanup() {
    pkill -f "GHDS-E2E.app/Contents/MacOS" 2>/dev/null || true
    if [ -n "${SIM_PID:-}" ]; then kill "$SIM_PID" 2>/dev/null || true; fi
    for _ in 1 2 3 4 5; do
        pgrep -f "GHDS-E2E.app/Contents/MacOS" >/dev/null 2>&1 || break
        sleep 0.2
    done
    pkill -9 -f "GHDS-E2E.app/Contents/MacOS" 2>/dev/null || true
    sleep 0.5
    cleanup_settings_suite
}
trap cleanup EXIT

# 日志断言使用中文键：固定测试 suite 的语言，避免宿主系统语言把断言变成假失败。
defaults write "$GHDS_SETTINGS_SUITE" ghds.language -string chinese

fail() { echo "✗ $1" >&2; exit 1; }
if pgrep -x GHDS >/dev/null 2>&1; then fail "已有 GHDS 进程在运行，请先关闭"; fi
pkill -x GHDSSim 2>/dev/null || true

rm -rf "$WORK"; mkdir -p "$WORK"

echo "▶ 打包（universal release + ad-hoc 签名 + dmg）"
bash scripts/build-app.sh "${GHDS_E2E_VERSION:-0.0.0-e2etest}" >/dev/null
cp -R "dist/GH Driver Station.app" "$WORK/GHDS-E2E.app"

# 在启动任何被测进程前记录正式域：之后写入应由隔离 suite 承担；实际值只留在变量里。
echo "▶ 记录正式域设置快照（${PROD_DOMAIN}，不输出实际值）"
BEFORE_MANUAL_IP="$(production_setting ghds.manualIP)"
BEFORE_TEAM_NUMBER="$(production_setting ghds.teamNumber)"

echo "▶ 启动包内 GHDSSim + 打包版 app（AUTO_SIM 连 127.0.0.1，radio 端口 8080）"
"$WORK/GHDS-E2E.app/Contents/MacOS/GHDSSim" --quiet --radio-port 8080 >/dev/null 2>&1 &
SIM_PID=$!
sleep 1

GHDS_LOG_FILE="$WORK/e2e.log" GHDS_AUTO_SIM=1 GHDS_DISABLE_UPDATE=1 \
  "$WORK/GHDS-E2E.app/Contents/MacOS/GHDS" >/dev/null 2>&1 &
APP_PID=$!

stop_packaged_app() {
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

echo "▶ Radio 可达性断言（GHDSSim --radio-port 8080）"
# 不杀模拟器制造离线：只读日志，离线场景由单元测试覆盖
grep -Fq "Radio 状态：已响应" "$WORK/e2e.log" 2>/dev/null || {
    grep "Radio" "$WORK/e2e.log" 2>/dev/null | tail -5
    fail "e2e.log 未见「Radio 状态：已响应」（radio 端口 8080 未生效？）"
}
echo "  ✓ Radio 状态：已响应"

LINES="$(grep -E "控制环吞吐：|Control loop throughput:" "$WORK/e2e.log" 2>/dev/null || true)"
[ -n "$LINES" ] || { grep -v "UI stall" "$WORK/e2e.log" 2>/dev/null | tail -8; fail "未见吞吐汇总行（控制包未按节拍发？）"; }
COUNT="$(printf '%s\n' "$LINES" | wc -l | tr -d ' ')"
MIN_HZ="$(printf '%s\n' "$LINES" | sed -E -n 's/.*(吞吐：|throughput: )([0-9.]+) Hz.*/\2/p' | sort -g | head -1)"
echo "  ✓ 吞吐汇总行 ${COUNT} 条，最低 ${MIN_HZ} Hz"
awk -v hz="$MIN_HZ" -v floor="$HZ_FLOOR" 'BEGIN { exit (hz+0 >= floor+0) ? 0 : 1 }' \
    || fail "吞吐 ${MIN_HZ}Hz 低于下限 ${HZ_FLOOR}Hz"

echo "▶ 日志落盘检查（/api/logs）"
LOGS="$(curl -s --max-time 3 http://127.0.0.1:6768/api/logs 2>/dev/null || true)"
printf '%s' "$LOGS" | grep -q '"name"' || fail "打包版未产生日志文件（/api/logs 为空）"
echo "  ✓ 会话日志已落盘并列出"

# 先停进程再读正式域：确保 app 的设置写入已结算，不会在比较之后才落盘。
echo "▶ 停打包版并核对正式域未被测试改动"
stop_packaged_app
if kill -0 "$APP_PID" 2>/dev/null; then fail "打包版进程未在停止阶段退出"; fi
AFTER_MANUAL_IP="$(production_setting ghds.manualIP)"
AFTER_TEAM_NUMBER="$(production_setting ghds.teamNumber)"
CHANGED=""
[ "$BEFORE_MANUAL_IP" = "$AFTER_MANUAL_IP" ] || CHANGED="$CHANGED ghds.manualIP"
[ "$BEFORE_TEAM_NUMBER" = "$AFTER_TEAM_NUMBER" ] || CHANGED="$CHANGED ghds.teamNumber"
if [ -n "$CHANGED" ]; then
    fail "正式域 ${PROD_DOMAIN} 的设置被测试改动：${CHANGED# }（实际值不输出）"
fi
echo "  ✓ 正式域 ghds.manualIP / ghds.teamNumber 前后一致"

echo ""
echo "✅ 打包版 E2E 通过：进程存活 + 控制环吞吐 ≥ ${HZ_FLOOR}Hz + connected + radio 已响应 + 日志落盘 + 正式域设置未变"
