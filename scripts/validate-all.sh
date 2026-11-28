#!/bin/bash
# scripts/validate-all.sh — 三端一键验证：Mac 本机 + 实体 Linux SSH 主机 + GitHub Actions Windows
#
# 每次功能合入 beta 后、以及 stable 发布前都必须跑完本脚本且全绿。三端验证的是同一个 commit：
#   Mac     跑当前 HEAD（预检要求工作树干净，所以磁盘内容 == HEAD；Mac 开始前固定 SHA 并在结束时复核）；
#   Linux   用 git archive <固定 SHA>（只含已提交的跟踪文件：不含 .git、未跟踪文件与任何本地秘密）解包到
#           远端每次 mktemp -d 新建的独立目录，在该目录跑 scripts/test-core.sh；
#   Windows 消费 GitHub Actions 上 headSha == 同一 SHA 的运行。
# 任何一端缺失（SSH 主机不可达 / 远端非 Linux 或无 Swift / gh 未登录 / HEAD 未推送 / workflow 不可用）都失败；
# 任何一端测试失败都失败。脚本只做验证：不合并 beta/stable、不发 Release、不替换 /Applications、
# 不自动重试 GitHub 操作（dispatch 至多一次；任何 gh 调用失败即停，交人工）。
#
# 用法：
#   scripts/validate-all.sh                                   # Linux 端默认用 SSH 别名 dkc-home
#   MATCHSTICKS_DS_LINUX_SSH_HOST=<别名或 user@host> scripts/validate-all.sh
#   MATCHSTICKS_DS_WINDOWS_REF=<已推送的分支> scripts/validate-all.sh   # 默认当前分支；detached HEAD 时必须显式给
#
# 流程（预检不过 = 一个测试、一条 SSH、一次 Actions 调用都不会发生）：
#   [0/4] 预检：环境变量 → 所需工具 → 仓库根 → Mac 脚本清单齐全 → 工作树干净 → HEAD 已推送且与 origin 一致
#         → gh 已登录 → workflow 文件已提交 → 实体 Linux SSH 优先；不可达时未获明确批准立即停
#   [1/4] Mac：swift build + Mac 脚本清单（必需基础脚本 + 自动发现的 scripts/test-*.sh，去重后各跑一次）
#   [2/4] Linux：探测远端（Linux / bash / tar / mktemp / Swift >= 6）→ mktemp -d 独立目录
#         → df 预检 /tmp 与根分区 → git archive <固定 SHA> | ssh tar -xf -
#         → 缓存隔离到本次目录 → bash scripts/test-core.sh → 复核 HEAD → 退出（含失败/Ctrl-C）只删本次目录
#   [3/4] Windows：读取 headSha == HEAD 的运行；pull_request（目标 beta/stable）、beta/stable push 与此前
#         workflow_dispatch 的运行一并消费，全部成功才算通过；一条都没有时才 dispatch 一次，且只在
#         workflow 已进入默认分支（dispatch 可用）时——否则立即失败并说明处置办法，不空等、不重发
#   汇总：三端各记同一个 commit SHA，全部通过时给出一致性结论
#
# Mac 脚本清单：
#   必需基础脚本（缺任一即 fail-closed，不静默跳过；按下表顺序运行，快 → 慢）：
#     scripts/test-core.sh           DSCoreTests（协议、控制环、安全闩锁、日志/录制、手柄映射、迁移、双语、WebUI、SocketCompat）
#     scripts/test-ui.sh             App 层状态回归（DSModel / HID / 手柄渲染 / 图标外观）
#     scripts/test-icon.sh           图标生成器行为
#     scripts/test-icon-gate.sh      打包图标链两道门
#     scripts/test-icon-geometry.sh  图标几何契约
#     scripts/test-star-link.sh      GitHub Star 链接回归
#     scripts/test-update.sh         Sparkle 升级链路 + 更新安全门（启动 App）
#     scripts/test-e2e.sh            打包版 E2E（启动 App + 模拟器，占用 1150/1110/6768 等端口）
#   自动发现：scripts/test-*.sh 的全部普通文件（与必需清单去重）；新增测试脚本无需改本文件，
#   按路径名字典序（LC_ALL=C）排在必需清单之后。
#
# Linux（优先实体主机，经 SSH；GitHub ubuntu-24.04 fallback 仅在明确批准后运行）
#   与 Mac/Windows 同一套 DSCoreTests（glibc/musl 原生 Swift）；不含 macOS App/UI/E2E。
# Windows（GitHub Actions，windows-2025 原生 Swift + Winsock；不是 WSL）
#   workflow：.github/workflows/full-validation.yml（pull_request 目标 beta/stable、push beta/stable、workflow_dispatch）。
#
# 环境变量：
#   MATCHSTICKS_DS_LINUX_SSH_HOST    Linux 主机（~/.ssh/config 别名或 user@host），默认 dkc-home；
#                                    SSH 原配置（ProxyCommand/密钥/跳板等）照常生效，脚本只追加
#                                    -o BatchMode=yes -o ConnectTimeout=15
#   MATCHSTICKS_DS_LINUX_SWIFT_BIN   远端 swift 可执行文件：swift（默认，按非交互 SSH 的 PATH 查找）或绝对路径。
#                                    非交互 SSH 看不到交互终端里由 swiftly/自定义 .bashrc 加的 PATH 时，用它指定；
#                                    给绝对路径时脚本会在远端把其所在目录前置到 PATH 再跑 test-core.sh
#   MATCHSTICKS_DS_LINUX_GITHUB_APPROVED  仅留空或填“允许”：实体主机 SSH 不通时，留空 = 停止并询问；
#                                    填“允许” = 本次使用 GitHub ubuntu-24.04 fallback，结果不冒充实体验证。
#                                    首次进入 stable 前用提交信息“ci: 允许使用 GitHub Linux 验证”的 PR head 提交触发；
#                                    进入 stable 后也可由脚本 dispatch 并传 linux_approval=允许。
#   MATCHSTICKS_DS_WINDOWS_WORKFLOW   workflow 文件名（默认 full-validation.yml）
#   MATCHSTICKS_DS_WINDOWS_REF        Windows 端验证的分支（默认当前分支）：其远端 tip 必须等于本地 HEAD
#   MATCHSTICKS_DS_WINDOWS_WAIT       等待 Actions 完成的最长分钟数（默认 90）
#   MATCHSTICKS_DS_TEST_PORT_WAIT     透传给 test-core.sh：固定端口被占时最多等待秒数（默认 900）
#   DEVELOPER_DIR                    macOS 完整 Xcode 路径（未设时默认 /Applications/Xcode.app）
set -uo pipefail
export GIT_TERMINAL_PROMPT=0  # 凭据不可用时让 git 立即失败，不在预检或归档阶段挂起
cd "$(dirname "$0")/.."

HOST="${MATCHSTICKS_DS_LINUX_SSH_HOST:-dkc-home}"
SWIFT_BIN="${MATCHSTICKS_DS_LINUX_SWIFT_BIN:-swift}"
WORKFLOW="${MATCHSTICKS_DS_WINDOWS_WORKFLOW:-full-validation.yml}"
WINDOWS_REF="${MATCHSTICKS_DS_WINDOWS_REF:-}"
WINDOWS_WAIT="${MATCHSTICKS_DS_WINDOWS_WAIT:-90}"
MATCHSTICKS_DS_TEST_PORT_WAIT="${MATCHSTICKS_DS_TEST_PORT_WAIT:-900}"
LINUX_GITHUB_APPROVAL="${MATCHSTICKS_DS_LINUX_GITHUB_APPROVED:-}"
LINUX_MODE="ssh"

# Mac 必需基础脚本（顺序即运行顺序；缺任一即失败，任何步骤都不跑）。其余 scripts/test-*.sh 自动发现。
REQUIRED_MAC_STEPS=(
    "scripts/test-core.sh"
    "scripts/test-ui.sh"
    "scripts/test-icon.sh"
    "scripts/test-icon-gate.sh"
    "scripts/test-icon-geometry.sh"
    "scripts/test-star-link.sh"
    "scripts/test-update.sh"
    "scripts/test-e2e.sh"
)
MAC_STEPS=()

if [ "$#" -gt 0 ]; then
    case "$1" in
        -h|--help) sed -n '2,/^set -uo pipefail/{/^set -uo pipefail/!p;}' "$0"; exit 0 ;;
        *) echo "validate-all.sh: 本脚本不接受位置参数（用环境变量配置，见 --help）" >&2; exit 2 ;;
    esac
fi

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

MAC_STATUS="未运行"; LINUX_STATUS="未运行"; WINDOWS_STATUS="未运行"
MAC_DETAIL="—"; LINUX_DETAIL="—"; WINDOWS_DETAIL="—"
SUMMARY_PRINTED=0
HEAD_SHA=""
REMOTE_DIR=""

summary() {
    SUMMARY_PRINTED=1
    echo
    echo "== 三端验证汇总 =="
    printf '  %-8s %-8s commit=%s · %s\n' "Mac" "$MAC_STATUS" "${HEAD_SHA:-未确定}" "Mac ${MAC_DETAIL}"
    if [ "$LINUX_MODE" = "github" ]; then
        printf '  %-8s %-8s commit=%s · %s\n' "Linux" "$LINUX_STATUS" "${HEAD_SHA:-未确定}" "Linux GitHub Actions ubuntu-24.04 DSCoreTests ${LINUX_DETAIL}"
    else
        printf '  %-8s %-8s commit=%s · %s\n' "Linux" "$LINUX_STATUS" "${HEAD_SHA:-未确定}" "Linux git archive ${HEAD_SHA:-未确定} → 远端独立目录 DSCoreTests ${LINUX_DETAIL}"
    fi
    printf '  %-8s %-8s commit=%s · %s\n' "Windows" "$WINDOWS_STATUS" "${HEAD_SHA:-未确定}" "Windows GitHub Actions windows-2025 DSCoreTests ${WINDOWS_DETAIL}"
    [ "$MAC_STATUS$LINUX_STATUS$WINDOWS_STATUS" = "通过通过通过" ] && echo "三端 commit 一致：$HEAD_SHA"
    return 0
}
fail() {
    echo "validate-all.sh: $*" >&2
    summary
    exit 1
}
head_unchanged() {
    local current
    if ! current="$(git rev-parse --verify HEAD 2>/dev/null)"; then
        echo "validate-all.sh: 无法复核 HEAD（固定 SHA=${HEAD_SHA}）" >&2
        return 1
    fi
    [ "$current" = "$HEAD_SHA" ] && return 0
    echo "validate-all.sh: HEAD 已从固定 SHA=$HEAD_SHA 变为 ${current}；三端结果不再属于同一 commit" >&2
    return 1
}
# 只清理本次 mktemp 创建的远端目录（REMOTE_DIR 为空 = 尚未创建）；失败路径与 Ctrl-C 同样执行
cleanup() {
    if [ -n "$REMOTE_DIR" ]; then
        if ! "${SSH[@]}" "rm -rf -- '$REMOTE_DIR'" >/dev/null 2>&1; then
            echo "validate-all.sh: 警告：无法清理远端临时目录 $HOST:${REMOTE_DIR}（请手动删除）" >&2
        fi
    fi
    [ "$SUMMARY_PRINTED" = "1" ] || summary
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST")

# 加入 Mac 清单（去重）。返回 0 = 新加入，1 = 已存在。
add_mac_step() {
    local existing
    for existing in ${MAC_STEPS[@]+"${MAC_STEPS[@]}"}; do
        [ "$existing" = "$1" ] && return 1
    done
    MAC_STEPS+=("$1")
    return 0
}

# 本机已有 Sparkle 检出/artifact 时，将它们复制到本次远端临时目录，避免实体主机必须访问 GitHub。
# 没有完整缓存时保留正常 SwiftPM 依赖获取路径，不伪造依赖或跳过解析。
copy_sparkle_cache_if_available() {
    [ -d .build/checkouts/Sparkle ] && [ -d .build/artifacts/sparkle ] && [ -f .build/workspace-state.json ] || return 0
    command -v scp >/dev/null 2>&1 || linux_fail "本机存在 Sparkle 缓存但缺少 scp，无法把它送入远端临时目录"
    "${SSH[@]}" "mkdir -p '$REMOTE_DIR/.build/checkouts' '$REMOTE_DIR/.build/artifacts'" \
        || linux_fail "远端缓存目录创建失败"
    scp -q -o BatchMode=yes -o ConnectTimeout=15 -r .build/checkouts/Sparkle "$HOST:$REMOTE_DIR/.build/checkouts/" \
        || linux_fail "Sparkle 检出复制失败"
    scp -q -o BatchMode=yes -o ConnectTimeout=15 -r .build/artifacts/sparkle "$HOST:$REMOTE_DIR/.build/artifacts/" \
        || linux_fail "Sparkle artifact 复制失败"
    scp -q -o BatchMode=yes -o ConnectTimeout=15 .build/workspace-state.json "$HOST:$REMOTE_DIR/.build/workspace-state.json" \
        || linux_fail "Sparkle workspace 状态复制失败"
    "${SSH[@]}" "python3 -c \"import json; p='$REMOTE_DIR/.build/workspace-state.json'; d=json.load(open(p)); [a.update(path='$REMOTE_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework') for a in d['object']['artifacts']]; json.dump(d,open(p,'w'))\"" \
        || linux_fail "Sparkle workspace 状态的远端 artifact 路径更新失败"
}

# ---- [0/4] 预检：以下任何一项不过，都不得运行测试、SSH 或 Actions ----
preflight() {
    local value missing tool step path discovered discovered_count=0 dirty_sample
    pf() { echo "validate-all.sh: 预检失败：$*（未运行任何测试、SSH 或 Actions）" >&2; exit 1; }

    # 环境变量（会被拼进远端命令 / gh 参数，逐项校验）
    case "$MATCHSTICKS_DS_TEST_PORT_WAIT" in
        ''|*[!0-9]*) pf "MATCHSTICKS_DS_TEST_PORT_WAIT 必须是非负整数秒数（得到：${MATCHSTICKS_DS_TEST_PORT_WAIT}）" ;;
    esac
    case "$WINDOWS_WAIT" in
        ''|*[!0-9]*) pf "MATCHSTICKS_DS_WINDOWS_WAIT 必须是非负整数分钟数（得到：${WINDOWS_WAIT}）" ;;
    esac
    # 远端 swift 路径会被拼进远端 shell 命令：只接受纯路径字符（拒绝空格/引号/分号等），防止误配置变成任意命令
    case "$SWIFT_BIN" in
        ''|*[!A-Za-z0-9_./-]*) pf "MATCHSTICKS_DS_LINUX_SWIFT_BIN 只能是 swift 或绝对路径（允许字符 A-Z a-z 0-9 _ . / -；得到：${SWIFT_BIN}）" ;;
    esac
    case "$SWIFT_BIN" in
        /*) REMOTE_PATH_PREFIX="PATH='$(dirname "$SWIFT_BIN")':\$PATH " ;;
        *)  [ "$SWIFT_BIN" = "swift" ] || pf "MATCHSTICKS_DS_LINUX_SWIFT_BIN 含目录时必须是绝对路径（得到：${SWIFT_BIN}）"
            REMOTE_PATH_PREFIX="" ;;
    esac
    case "$LINUX_GITHUB_APPROVAL" in
        ''|允许) ;;
        *) pf "MATCHSTICKS_DS_LINUX_GITHUB_APPROVED 只能留空或填“允许”；其他值不代表用户明确批准" ;;
    esac
    case "$WORKFLOW" in
        ''|*[!A-Za-z0-9._-]*|.*/*) pf "MATCHSTICKS_DS_WINDOWS_WORKFLOW 只能是 .github/workflows/ 下的文件名（得到：${WORKFLOW}）" ;;
    esac
    case "$HOST" in
        '') pf "MATCHSTICKS_DS_LINUX_SSH_HOST 不能为空" ;;
    esac

    # 所需工具（本脚本直接调用的）
    missing=""
    for tool in git swift ssh gh; do
        command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
    done
    [ -z "$missing" ] || pf "缺少工具：$missing"

    # 仓库根
    [ -f Package.swift ] || pf "当前目录不是仓库根（缺少 Package.swift）"
    [ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ] || pf "当前目录不是 git 工作树"

    # Mac 清单：必需基础脚本必须齐全（fail-closed），再并入自动发现
    missing=""
    for step in "${REQUIRED_MAC_STEPS[@]}"; do
        [ -f "$step" ] || missing="$missing $step"
    done
    [ -z "$missing" ] || pf "Mac 清单缺少必需脚本：${missing}（集成对应分支后必须存在并运行；不得静默跳过）"
    discovered="$(for path in scripts/test-*.sh; do [ -f "$path" ] && printf '%s\n' "$path"; done | LC_ALL=C sort)"
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        discovered_count=$((discovered_count + 1))
    done <<EOF
$discovered
EOF
    echo "Mac 脚本清单（必需 ${#REQUIRED_MAC_STEPS[@]} 个 + 自动发现 ${discovered_count} 个 scripts/test-*.sh，去重后按下列顺序各跑一次）："
    for step in "${REQUIRED_MAC_STEPS[@]}"; do
        add_mac_step "$step"
        echo "  $step  必需"
    done
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        if add_mac_step "$path"; then echo "  $path  自动发现"; fi
    done <<EOF
$discovered
EOF

    # 工作树必须干净：Mac 端只验证已提交的 HEAD（否则三端验证的不是同一个 commit）
    value="$(git status --porcelain)"
    if [ -n "$value" ]; then
        dirty_sample="$(printf '%s' "$value" | head -3 | tr '\n' ' ')"
        pf "工作树有未提交改动，先提交：${dirty_sample}"
    fi

    # HEAD 已推送且与 origin 一致（一次只读 ls-remote，不 fetch、不 push）
    HEAD_SHA="$(git rev-parse --verify HEAD 2>/dev/null)"
    case "$HEAD_SHA" in
        *[!0-9a-f]*|'') pf "无法读取 HEAD 的提交 SHA（得到：${HEAD_SHA:-空}）" ;;
    esac
    [ -n "$WINDOWS_REF" ] || WINDOWS_REF="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
    [ -n "$WINDOWS_REF" ] && [ "$WINDOWS_REF" != "HEAD" ] \
        || pf "当前处于 detached HEAD：请用 MATCHSTICKS_DS_WINDOWS_REF 指定远端分支（其远端 tip 必须等于本地 HEAD；Windows 端按它查运行/触发 dispatch）"
    git check-ref-format --branch "$WINDOWS_REF" >/dev/null 2>&1 || pf "MATCHSTICKS_DS_WINDOWS_REF 不是合法分支名：$WINDOWS_REF"
    value="$(git ls-remote --exit-code --heads origin "refs/heads/$WINDOWS_REF" 2>&1)"
    case "$?" in
        0) ;;
        2) pf "分支 $WINDOWS_REF 尚未推送到 origin（本地 HEAD $HEAD_SHA 不在远端）；先推送再验证（本脚本不替用户 push）" ;;
        *) pf "无法访问 origin（git ls-remote 失败，不自动重试）：$value" ;;
    esac
    REMOTE_SHA="$(printf '%s\n' "$value" | sed -n '1s/^\([0-9a-f]*\)[[:space:]].*/\1/p')"
    [ "$REMOTE_SHA" = "$HEAD_SHA" ] \
        || pf "本地 HEAD $HEAD_SHA 与 origin/${WINDOWS_REF}（${REMOTE_SHA:-无}）不一致；先推送（本脚本不替用户 push）"

    # gh 已登录（Windows 端靠它读取运行；只读一次，失败不重试）
    value="$(gh auth status 2>&1)"
    [ "$?" = "0" ] || pf "gh 未登录（gh auth login）：$value"

    # workflow 文件已提交（工作树已确认干净，磁盘上有 = HEAD 内有）
    [ -f ".github/workflows/$WORKFLOW" ] || pf "缺少 .github/workflows/${WORKFLOW}（Windows 端的验证 workflow）"

    # 实体 Linux 主机优先：SSH 不通时先停，不跑其他平台。只有用户明确批准后才进入 GitHub Linux fallback。
    REMOTE_PROBE='echo "uname=$(uname -s)"; echo "bash=$(command -v bash || true)"; echo "tar=$(command -v tar || true)"; echo "mktemp=$(command -v mktemp || true)"; echo "swift=$('"$SWIFT_BIN"' --version 2>&1 | head -1)"'
    probe="$("${SSH[@]}" "$REMOTE_PROBE" 2>&1)"
    if [ "$?" -ne 0 ]; then
        if [ "$LINUX_GITHUB_APPROVAL" = "允许" ]; then
            LINUX_MODE="github"
            LINUX_DETAIL="github ubuntu-24.04 · 用户已批准"
        else
            LINUX_STATUS="不可达"
            fail "Linux 主机 ${HOST} 不可达，已停止：${probe}。是否允许使用 GitHub 提供的 Linux 环境进行验证？请用户明确回答“允许”后，以 MATCHSTICKS_DS_LINUX_GITHUB_APPROVED=允许 重跑；未授权时不自动切云端，云端结果也不冒充实体验证"
        fi
    fi

    echo "预检通过：commit=${HEAD_SHA}（分支 $WINDOWS_REF 已推送且与 origin 一致；工作树干净；Linux=${LINUX_MODE}）"
}
preflight
export MATCHSTICKS_DS_TEST_PORT_WAIT

# ---- [1/4] Mac：当前 HEAD ----
echo
echo "== [1/4] Mac 本机：commit=$HEAD_SHA =="
MAC_STATUS="运行中"
MAC_DETAIL="swift build"
mac_fail() { MAC_STATUS="失败"; MAC_DETAIL="${MAC_DETAIL} ✗"; fail "Mac $*"; }
head_unchanged || mac_fail "开始前 HEAD 已改变或无法复核"
swift build || mac_fail "swift build 失败"
for step in "${MAC_STEPS[@]}"; do
    echo "-- Mac：$step"
    MAC_DETAIL="$MAC_DETAIL · ${step#scripts/}"
    bash "$step" || mac_fail "$step 失败"
done
MAC_STATUS="通过"

# ---- [2/4] Linux：实体主机优先；只有明确批准时才走 GitHub Linux fallback ----
if [ "$LINUX_MODE" = "github" ]; then
    echo
    echo "== [2/4] Linux：GitHub ubuntu-24.04 fallback（用户已批准；不冒充实体验证）=="
    LINUX_STATUS="待云端"
else
    echo
    echo "== [2/4] Linux：git archive $HEAD_SHA → 实体 SSH 主机 =="
    LINUX_STATUS="运行中"
linux_fail() { LINUX_STATUS="失败"; fail "Linux $*"; }
# 一次 SSH 探测远端环境（系统 / 解包与建目录所需工具 / Swift 版本）；连接失败即停，不重试
REMOTE_PROBE='echo "uname=$(uname -s)"; echo "bash=$(command -v bash || true)"; echo "tar=$(command -v tar || true)"; echo "mktemp=$(command -v mktemp || true)"; echo "swift=$('"$SWIFT_BIN"' --version 2>&1 | head -1)"'
probe="$("${SSH[@]}" "$REMOTE_PROBE" 2>&1)"
[ "$?" = "0" ] || linux_fail "无法 SSH 到主机 ${HOST}（不自动重试）：$probe"
remote_uname="$(printf '%s\n' "$probe" | sed -n 's/^uname=//p')"
remote_bash="$(printf '%s\n' "$probe" | sed -n 's/^bash=//p')"
remote_tar="$(printf '%s\n' "$probe" | sed -n 's/^tar=//p')"
remote_mktemp="$(printf '%s\n' "$probe" | sed -n 's/^mktemp=//p')"
remote_swift="$(printf '%s\n' "$probe" | sed -n 's/^swift=//p')"
[ "$remote_uname" = "Linux" ] || linux_fail "$HOST 不是 Linux（uname -s = ${remote_uname:-空}）；不得用其他系统冒充 Linux 端"
[ -n "$remote_bash" ] && [ -n "$remote_tar" ] && [ -n "$remote_mktemp" ] \
    || linux_fail "$HOST 缺少解包/建目录所需工具（bash=${remote_bash:-无} tar=${remote_tar:-无} mktemp=${remote_mktemp:-无}）"
remote_major="$(printf '%s' "$remote_swift" | sed -nE 's/.*Swift version ([0-9]+)\..*/\1/p')"
if [ -z "$remote_major" ]; then
    linux_fail "$HOST 上找不到 swift（${remote_swift}）。非交互 SSH 看到的 PATH 与交互终端不同：Swift 装在非标准位置时请设 MATCHSTICKS_DS_LINUX_SWIFT_BIN=/绝对路径/swift；未安装则先装 swift.org 6.x 工具链或 swiftly"
fi
[ "$remote_major" -ge 6 ] || linux_fail "$HOST 的 Swift 版本不满足 swift-tools-version 6.0：${remote_swift}"
# 每次运行一个全新的远端目录：不做任何删除式同步，退出时只删这一个目录
remote_tmp_raw="$("${SSH[@]}" 'umask 077 && mktemp -d "${TMPDIR:-/tmp}/matchsticks-driver-staion-validation.XXXXXX"' 2>&1)"
[ "$?" = "0" ] || linux_fail "无法在 $HOST 上用 mktemp -d 创建独立临时目录：${remote_tmp_raw}"
# 只接受「绝对路径 + 末段以 matchsticks-driver-staion-validation. 开头 + 仅含保守字符集」的单行路径（它会被拼进远端 rm -rf）
case "$remote_tmp_raw" in
    /*/matchsticks-driver-staion-validation.*) ;;
    *) linux_fail "$HOST 的 mktemp 返回了意外路径（拒绝使用）：$remote_tmp_raw" ;;
esac
if [ "$(printf '%s\n' "$remote_tmp_raw" | wc -l | tr -d ' ')" != "1" ] \
    || printf '%s' "$remote_tmp_raw" | LC_ALL=C grep -q '[^A-Za-z0-9._/:-]'; then
    linux_fail "远端临时目录不是单行路径或含不允许的字符（拒绝使用）：$remote_tmp_raw"
fi
REMOTE_DIR="$remote_tmp_raw"
echo "远端临时目录：$HOST:${REMOTE_DIR}（仅本次使用，退出时删除）"
# 归档和测试前检查 /tmp 与根分区：缓存虽已隔离到本次目录，可用空间不足仍须明确拒绝，不能等编译写满
remote_df="$("${SSH[@]}" 'df -Pk /tmp /' 2>&1)"
[ "$?" = "0" ] || linux_fail "无法读取远端 /tmp 与根分区可用空间（df 失败；未运行 DSCoreTests）：${remote_df}"
space_status=0
printf '%s\n' "$remote_df" | awk '
    NR > 1 {
        count++
        if ($4 < 1048576) {
            printf("可用空间不足：%s 仅 %d KiB（至少需要 1048576 KiB）\n", $6, $4)
            insufficient=1
        }
    }
    END {
        if (count != 2) {
            printf("df 预检需要 /tmp 与 / 两行记录，实际 %d 行\n", count)
            exit 1
        }
        if (insufficient) exit 1
    }' || space_status=$?
[ "$space_status" = "0" ] || linux_fail "远端 /tmp 与根分区可用空间预检失败（各需至少 1 GiB；未运行 DSCoreTests）：${remote_df}"
# 只同步 Mac 开始前固定的 SHA：git archive 输出不含 .git、未跟踪文件与被忽略的本地文件；经 stdin 送入远端 tar，无 --delete
git archive --format=tar "$HEAD_SHA" | "${SSH[@]}" "tar -xf - -C '$REMOTE_DIR'"
archive_status=("${PIPESTATUS[@]}")
[ "${archive_status[0]}" = "0" ] || linux_fail "git archive ${HEAD_SHA} 失败（退出码 ${archive_status[0]}；141 = 远端提前关闭了管道，原因见上方 ssh/tar 报错）"
[ "${archive_status[1]}" = "0" ] || linux_fail "远端解包失败（ssh / tar 退出码 ${archive_status[1]}）"
copy_sparkle_cache_if_available
# 远端 PATH 沿用上面实际探测成功的 swift；SwiftPM/Clang 缓存全部留在本次目录，不写根分区默认缓存位置
remote_test_env="${REMOTE_PATH_PREFIX}SWIFTPM_CACHE_PATH='${REMOTE_DIR}/swiftpm-cache' SWIFTPM_MANIFEST_CACHE=local CLANG_MODULE_CACHE_PATH='${REMOTE_DIR}/clang-module-cache' "
if ! "${SSH[@]}" "cd '$REMOTE_DIR' && ${remote_test_env}MATCHSTICKS_DS_TEST_PORT_WAIT=${MATCHSTICKS_DS_TEST_PORT_WAIT} bash scripts/test-core.sh"; then
    linux_fail "主机 $HOST 上 DSCoreTests 失败"
fi
head_unchanged || linux_fail "验证结束时 HEAD 已改变或无法复核"
LINUX_STATUS="通过"
LINUX_DETAIL="host=$HOST · ${remote_swift} ✓"
fi

# ---- [3/4] Windows：GitHub Actions 原生 Swift DSCoreTests，headSha == HEAD ----
echo
echo "== [3/4] Windows：GitHub Actions 原生 Swift DSCoreTests（headSha == ${HEAD_SHA}）=="
WINDOWS_STATUS="运行中"
windows_fail() {
    WINDOWS_STATUS="失败"
    [ "$LINUX_MODE" != "github" ] || LINUX_STATUS="失败"
    fail "Windows $*"
}
# 运行记录里的 name 是 workflow 的显示名（YAML 顶层 name；缺省时 GitHub 用文件名）
WF_NAME="$(sed -n 's/^name:[[:space:]]*//p' ".github/workflows/$WORKFLOW" | head -1)"
DQ='"'
SQ="'"
case "$WF_NAME" in
    $DQ*) WF_NAME="${WF_NAME#$DQ}" ;;
    $SQ*) WF_NAME="${WF_NAME#$SQ}" ;;
esac
case "$WF_NAME" in
    *$DQ) WF_NAME="${WF_NAME%$DQ}" ;;
    *$SQ) WF_NAME="${WF_NAME%$SQ}" ;;
esac
[ -n "$WF_NAME" ] || WF_NAME="$WORKFLOW"
# gh 的 jq 表达式：每条运行一行 TSV。字段故意不留空值——bash 的 read 会把连续制表符合并成一个分隔符，
# 空字段会让后面的列错位；所以 status/conclusion 合成一个字段，缺失的分支名用占位符 "?"（git 分支名不允许 ?）
RUNS_JQ='.[] | [.databaseId, .event, .headSha, (.status + "/" + (.conclusion // "")), ((.headBranch // "") | if . == "" then "?" else . end), .name, .url] | @tsv'
WORKFLOWS_JQ='.[] | [.path, .state] | @tsv'

RUNS_FIELDS=databaseId,event,headSha,status,conclusion,headBranch,name,url
RUN_IDS=(); RUN_EVENTS=(); RUN_STATES=(); RUN_URLS=()
# 读取 headSha == HEAD_SHA 的运行（一条 gh 调用，失败即停、不重试），筛出本 workflow 可消费的运行：
#   pull_request（目标 beta/stable，由 workflow 触发器限定）、push 到 beta/stable、对本分支的 workflow_dispatch
refresh_runs() {
    local listing id event sha state branch name url
    RUN_IDS=(); RUN_EVENTS=(); RUN_STATES=(); RUN_URLS=()
    listing="$(gh run list --commit "$HEAD_SHA" --limit 50 --json "$RUNS_FIELDS" --jq "$RUNS_JQ" 2>&1)"
    [ "$?" = "0" ] || windows_fail "读取 Actions 运行列表失败（不自动重试）：$listing"
    while IFS=$'\t' read -r id event sha state branch name url; do
        [ -n "$id" ] || continue
        [ "$sha" = "$HEAD_SHA" ] || continue
        [ "$name" = "$WF_NAME" ] || continue
        case "$event" in
            pull_request) ;;
            push) case "$branch" in beta|stable) ;; *) continue ;; esac ;;
            workflow_dispatch) [ "$branch" = "$WINDOWS_REF" ] || continue ;;
            *) continue ;;
        esac
        RUN_IDS+=("$id"); RUN_EVENTS+=("$event"); RUN_STATES+=("$state"); RUN_URLS+=("$url")
    done <<EOF
$listing
EOF
    return 0
}
describe_runs() {
    local i=0 text=""
    while [ "$i" -lt "${#RUN_IDS[@]}" ]; do
        text="${text:+$text, }${RUN_EVENTS[$i]} run ${RUN_IDS[$i]}=${RUN_STATES[$i]} ${RUN_URLS[$i]}"
        i=$((i + 1))
    done
    printf '%s' "$text"
}

refresh_runs
if [ "${#RUN_IDS[@]}" -eq 0 ]; then
    # 没有可消费的运行：只有这时才考虑 dispatch，且至多一次
    registered="$(gh workflow list --all --json name,path,state --jq "$WORKFLOWS_JQ" 2>&1)"
    [ "$?" = "0" ] || windows_fail "读取 workflow 列表失败（不自动重试）：$registered"
    wf_state=""
    while IFS=$'\t' read -r path state; do
        [ "$path" = ".github/workflows/$WORKFLOW" ] || continue
        wf_state="$state"
    done <<EOF
$registered
EOF
    if [ -z "$wf_state" ]; then
        # 首次：workflow 文件尚未进入默认分支 stable，GitHub 未注册、workflow_dispatch 不可用——立即失败，不空等
        if [ "$LINUX_MODE" = "github" ]; then
            windows_fail "没有 headSha=${HEAD_SHA} 的 Linux fallback 运行，且 ${WORKFLOW} 尚未进入默认分支 stable，dispatch 不可用。请先创建提交信息为“ci: 允许使用 GitHub Linux 验证”的空提交并推送，使 PR 以该 head SHA 触发 Linux job；或在 workflow 进入 stable 后用 linux_approval=允许 dispatch。不得擅自创建批准提交或推送"
        else
            windows_fail "没有 headSha=${HEAD_SHA} 的运行，且 ${WORKFLOW} 尚未进入默认分支 stable（GitHub 未注册，dispatch 不可用）。处置：先开 PR 到 beta（pull_request 触发）或把该提交推到 beta/stable（push 触发），Windows 运行出现后重跑本脚本；本脚本不代开 PR、不推送"
        fi
    elif [ "$wf_state" != "active" ]; then
        windows_fail "${WORKFLOW} 在 GitHub 上的状态是 ${wf_state}（已停用），dispatch 不可用；请到仓库 Actions 设置启用后重跑（不自动重试）"
    else
        if [ "$LINUX_MODE" = "github" ]; then
            gh workflow run "$WORKFLOW" --ref "$WINDOWS_REF" -f linux_approval=允许 \
                || windows_fail "dispatch Linux fallback ${WORKFLOW}@${WINDOWS_REF} 失败（不自动重试）"
        else
            gh workflow run "$WORKFLOW" --ref "$WINDOWS_REF" \
                || windows_fail "dispatch ${WORKFLOW}@${WINDOWS_REF} 失败（不自动重试）"
        fi
        echo "已 dispatch 一次（${WORKFLOW}@${WINDOWS_REF}，期望 headSha=${HEAD_SHA}）；等待运行出现……"
        appeared=0
        for _ in $(seq 1 40); do
            sleep 15
            refresh_runs
            if [ "${#RUN_IDS[@]}" -gt 0 ]; then appeared=1; break; fi
        done
        [ "$appeared" = "1" ] || windows_fail "dispatch 已发出一次，但没有出现 headSha=${HEAD_SHA} 的运行（${WORKFLOW}@${WINDOWS_REF}）；不重发、不自动重试——请到 GitHub Actions 页面核对"
    fi
fi

WINDOWS_DETAIL="$(describe_runs)"
echo "消费 headSha=${HEAD_SHA} 的运行（pull_request / beta·stable push / workflow_dispatch，全部成功才算通过）："
echo "  $WINDOWS_DETAIL"
# 只读轮询结论（不是重试）：每 30s 读一次，最多 WINDOWS_WAIT 分钟；任一运行失败即失败，读取失败即停
deadline=$((SECONDS + WINDOWS_WAIT * 60))
while :; do
    [ "${#RUN_IDS[@]}" -gt 0 ] || windows_fail "运行列表变为空（GitHub 异常？不自动重试）：$WINDOWS_DETAIL"
    bad=""; pending=0; i=0
    while [ "$i" -lt "${#RUN_IDS[@]}" ]; do
        case "${RUN_STATES[$i]}" in
            completed/success) ;;
            completed/*) bad="${bad:+$bad, }${RUN_EVENTS[$i]} run ${RUN_IDS[$i]}=${RUN_STATES[$i]} ${RUN_URLS[$i]}" ;;
            *) pending=1 ;;
        esac
        i=$((i + 1))
    done
    [ -z "$bad" ] || windows_fail "Actions 运行未通过：${bad}（不自动重试、不重新 dispatch）"
    [ "$pending" = "0" ] && break
    [ "$SECONDS" -lt "$deadline" ] || windows_fail "Actions 运行未在 ${WINDOWS_WAIT} 分钟内完成（$(describe_runs)）"
    sleep 30
    refresh_runs
    WINDOWS_DETAIL="$(describe_runs)"
done
head_unchanged || windows_fail "三端验证结束时 HEAD 已改变或无法复核"
WINDOWS_STATUS="通过"
if [ "$LINUX_MODE" = "github" ]; then
    LINUX_STATUS="通过"
    LINUX_DETAIL="github ubuntu-24.04 · 用户已批准"
fi

summary
echo
echo "三端全部通过。本脚本不合并 beta/stable、不发 Release——后续动作需另行点名。"
