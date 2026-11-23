#!/bin/bash
# scripts/test-core.sh — 跨平台核心回归（DSCore + DSCoreTests）的统一入口
#
# 在 macOS / Linux / Windows（原生 Swift 工具链，Git Bash 下运行）上构建并运行 DSCoreTests（自带 runner，无 XCTest）。
# 只构建 `--product DSCoreTests`：Sparkle 与 SwiftUI 主程序（macOS 专用）不参与，Linux/Windows 也能跑。
#
# 覆盖范围（三平台同一套断言）：
#   NI / MRC 编解码金样本与往返、msgpack / protobuf-lite、NT4 WebSocket 握手与帧、控制环 / 看门狗 /
#   E-Stop 锁存 / 安全闩锁、有界 TCP connect 分类、Radio 探测、日志 .dslog/.wpilog 与 .dsrec 录制回放、
#   手柄识别与映射、练习时序、设置前缀迁移、数据目录迁移、双语表、WebUI 路由与回环 socket、
#   SocketCompat 薄层回环往返（Linux 用 poll，Windows 用 Winsock select）。
# 不覆盖：macOS App / SwiftUI / Sparkle / 打包版 E2E（由 test-ui.sh、test-update.sh、test-e2e.sh 承担）。
#
# 用法：scripts/test-core.sh [--release]
#       scripts/test-core.sh --filter-netstat < netstat-ano.txt   （测试钩子：对 stdin 应用 Windows 端口过滤）
# 环境：
#   DEVELOPER_DIR                  macOS 上完整 Xcode 的路径（未设时默认 /Applications/Xcode.app）
#   MATCHSTICKS_DS_TEST_PORT_WAIT  DSClient 固定绑定 UDP 1150（协议要求），控制口默认 1110、TCP 1740；
#                                  被其他实例占用时最多等待的秒数（默认 0 = 占用即失败并提示占用者）。
#                                  本机并行跑多份 DSCoreTests 必须串行；不得抢占他人端口。
#   端口预检：macOS 用 lsof，Linux 用 ss，Windows（Git Bash 无 lsof/ss）用 netstat -ano。
set -euo pipefail
cd "$(dirname "$0")/.."

# Windows `netstat -ano` 过滤：UDP 行没有 State 列，只看本地端口 1150/1110；TCP 只认 1740 的 LISTENING
netstat_filter() {
    awk '$1 == "UDP" && $2 ~ /:(1150|1110)$/ { print; next } $1 == "TCP" && $2 ~ /:1740$/ && $4 == "LISTENING" { print }'
}

CONFIG=()
for arg in "$@"; do
    case "$arg" in
        --release) CONFIG+=(--release) ;;
        --filter-netstat) netstat_filter; exit $? ;;
        -h|--help) sed -n '2,/^set -euo pipefail/{/^set -euo pipefail/!p;}' "$0"; exit 0 ;;
        *) echo "test-core.sh: 未知参数：${arg}（可用：--release）" >&2; exit 2 ;;
    esac
done

PORT_WAIT="${MATCHSTICKS_DS_TEST_PORT_WAIT:-0}"

platform_name() {
    case "$(uname -s)" in
        Darwin) echo "macOS" ;;
        Linux) echo "Linux" ;;
        MINGW*|MSYS*|CYGWIN*) echo "Windows" ;;
        *) uname -s ;;
    esac
}
PLATFORM="$(platform_name)"

# 本机默认 Xcode（CLT 无 SwiftUI 宏插件）；其他环境沿用系统默认工具链
if [ -z "${DEVELOPER_DIR:-}" ] && [ "$PLATFORM" = "macOS" ] && [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# 固定端口预检：DSClient 的 UDP 应答口 1150 是协议要求（roboRIO 2.0 固定回 1150），无法隔离；
# 同机另一份 DSCoreTests 或残留的 MatchSticksDS 进程会让应答被抢走，表现为大面积「0 应答」假失败。
# 注意：macOS 的 lsof 有输出时也可能以 1 退出，管道必须吞掉非零状态（脚本启用了 pipefail）。
ports_busy() {
    if command -v lsof >/dev/null 2>&1; then
        { lsof -nP -iUDP:1150 -iUDP:1110 -iTCP:1740 2>/dev/null || true; } | tail -n +2
    elif command -v ss >/dev/null 2>&1; then
        { ss -Hlun 2>/dev/null || true; } | awk '$5 ~ /:(1150|1110)$/ {print $0}'
        { ss -Hltn 2>/dev/null || true; } | awk '$4 ~ /:1740$/ {print $0}'
    elif [ "$PLATFORM" = "Windows" ] && command -v netstat >/dev/null 2>&1; then
        { netstat -ano 2>/dev/null || true; } | netstat_filter
    fi
}
busy="$(ports_busy)"
if [ -n "$busy" ]; then
    if [ "$PORT_WAIT" -gt 0 ]; then
        echo "test-core.sh: 测试端口被占用，最多等待 ${PORT_WAIT}s（只读探测，不抢占）：" >&2
        echo "$busy" >&2
        waited=0
        quiet=0
        while [ $waited -lt "$PORT_WAIT" ]; do
            sleep 10; waited=$((waited + 10))
            busy="$(ports_busy)"
            if [ -z "$busy" ]; then
                # 连续两次空闲才起跑：降低与并行的其他验证实例同时启动、互相抢端口的概率
                quiet=$((quiet + 1))
                [ "$quiet" -ge 2 ] && break
            else
                quiet=0
            fi
        done
    fi
    if [ -n "$busy" ]; then
        echo "test-core.sh: UDP 1150/1110 或 TCP 1740 被其他进程占用（如下），DSClient 固定绑定 1150，无法并行：" >&2
        echo "$busy" >&2
        echo "  处置：等占用者结束，或设置 MATCHSTICKS_DS_TEST_PORT_WAIT=<秒数> 让本脚本等待；不得强杀他人进程。" >&2
        exit 3
    fi
fi

echo "== test-core.sh [$PLATFORM] =="
echo "swift: $(swift --version 2>&1 | head -1)"
swift build --product DSCoreTests ${CONFIG[@]+"${CONFIG[@]}"}
BIN="$(swift build --show-bin-path ${CONFIG[@]+"${CONFIG[@]}"} | tail -1)"
# Windows（Git Bash）：SwiftPM 输出的是反斜杠路径，转成 MSYS 路径再给 [ -x ] 与执行用
if command -v cygpath >/dev/null 2>&1; then BIN="$(cygpath -u "$BIN")"; fi
if [ -x "$BIN/DSCoreTests" ]; then
    EXEC="$BIN/DSCoreTests"
elif [ -x "$BIN/DSCoreTests.exe" ]; then
    EXEC="$BIN/DSCoreTests.exe"
else
    EXEC=""  # 回落到 swift run（由 SwiftPM 自行定位产物）
fi
set +e
if [ -n "$EXEC" ]; then
    "$EXEC"
else
    swift run DSCoreTests ${CONFIG[@]+"${CONFIG[@]}"}
fi
RC=$?
set -e
echo "== test-core.sh [$PLATFORM] 退出码 ${RC}（覆盖：DSCore 协议/控制环/安全/日志/映射/迁移/双语/WebUI/SocketCompat；不含 macOS App/UI/E2E）=="
exit $RC
