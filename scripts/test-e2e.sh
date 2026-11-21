#!/bin/bash
# 打包版 E2E（无硬件；本地运行，依赖本机 GUI/端口环境）
#
# 判活三重断言（2026-09-16 教训：不能只看 TCP 建链）：
#   ① 打包版进程存活整个观测窗；
#   ② 控制环吞吐汇总行持续出现且频率 ≥ 下限（控制包真在按节拍发）；
#   ③ WebUI /api/status 报 commState=connected（127.0.0.1:6768）。
# 全部产物来自 build-app.sh 打出的 .app（含包内 GHDSSim）。
#
# 用法：bash scripts/test-e2e.sh
# 可调：GHDS_E2E_HZ_FLOOR（默认 40——本机控制环 50Hz；慢机器场景用 8）
set -euo pipefail
cd "$(dirname "$0")/.."
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
export DEVELOPER_DIR
HZ_FLOOR="${GHDS_E2E_HZ_FLOOR:-40}"

fail() { echo "✗ $1" >&2; exit 1; }
if pgrep -x GHDS >/dev/null 2>&1; then fail "已有 GHDS 进程在运行，请先关闭"; fi
pkill -x GHDSSim 2>/dev/null || true

WORK=/tmp/ghds-packaged-e2e
rm -rf "$WORK"; mkdir -p "$WORK"

echo "▶ 打包（universal release + ad-hoc 签名 + dmg）"
bash scripts/build-app.sh "${GHDS_E2E_VERSION:-0.0.0-e2etest}" >/dev/null
cp -R "dist/GH Driver Station.app" "$WORK/GHDS-E2E.app"

echo "▶ 启动包内 GHDSSim + 打包版 app（AUTO_SIM 连 127.0.0.1）"
"$WORK/GHDS-E2E.app/Contents/MacOS/GHDSSim" --quiet >/dev/null 2>&1 &
SIM_PID=$!
cleanup() {
    pkill -f "GHDS-E2E.app/Contents/MacOS" 2>/dev/null || true
    kill "$SIM_PID" 2>/dev/null || true
}
trap cleanup EXIT
sleep 1

GHDS_LOG_FILE="$WORK/e2e.log" GHDS_AUTO_SIM=1 GHDS_DISABLE_UPDATE=1 \
  "$WORK/GHDS-E2E.app/Contents/MacOS/GHDS" >/dev/null 2>&1 &
APP_PID=$!

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

echo ""
echo "✅ 打包版 E2E 通过：进程存活 + 控制环吞吐 ≥ ${HZ_FLOOR}Hz + connected + 日志落盘"
