#!/bin/bash
# 三端验证脚本的离线回归：结构断言、ss 样例与全 mock 的 validate-all 流程。
# 可由 validate-all.sh 自动发现；不会连接 SSH/GitHub，不会启动 App。
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
mkdir -p "$ROOT/.build"
WORK="$(mktemp -d "$ROOT/.build/validation-script-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PASS=0
FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }
assert_contains() { # $1=描述 $2=文件 $3=文本
    if grep -Fq -- "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1"; fi
}
assert_absent() { # $1=描述 $2=文件 $3=文本
    if grep -Fq -- "$3" "$2" 2>/dev/null; then bad "$1"; else ok "$1"; fi
}
SHA="1111111111111111111111111111111111111111"
CHANGED_SHA="2222222222222222222222222222222222222222"
REMOTE_DIR="/tmp/matchsticks-ds-validation.abc123"

make_fixture() { # $1=名称；向 stdout 输出临时夹具目录
    local dir="$WORK/$1"
    mkdir -p "$dir/scripts" "$dir/bin" "$dir/.github/workflows"
    cp scripts/validate-all.sh "$dir/scripts/"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$dir/scripts/test-core.sh"
    : > "$dir/Package.swift"
    printf '%s\n' "$SHA" > "$dir/head"
    printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted on' > "$dir/df.txt"
    printf '%s\n' '/dev/root 1000000 1000 2097152 1% /' >> "$dir/df.txt"
    printf '%s\n' 'tmpfs 1000000 1000 2097152 1% /tmp' >> "$dir/df.txt"
    printf '%s\n' 'name: Full validation (Windows)' > "$dir/.github/workflows/full-validation.yml"
    local step
    for step in test-ui test-icon test-icon-gate test-icon-geometry test-star-link test-update test-e2e; do
        printf '%s\n' '#!/bin/sh' 'exit 0' > "$dir/scripts/$step.sh"
    done
    cat > "$dir/scripts/test-auto-discovery.sh" <<'EOF'
#!/bin/bash
printf 'auto-discovered\n' >> "$VALIDATION_TEST_LOG"
EOF

    cat > "$dir/bin/git" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'git-prompt=%s\n' "${GIT_TERMINAL_PROMPT:-unset}" >> "$VALIDATION_TEST_LOG"
printf 'git\t%s\n' "$*" >> "$VALIDATION_TEST_LOG"
case "$*" in
    'rev-parse --is-inside-work-tree') echo true ;;
    'status --porcelain') ;;
    'rev-parse --verify HEAD') cat "$VALIDATION_TEST_HEAD" ;;
    'rev-parse --abbrev-ref HEAD') echo beta ;;
    'check-ref-format --branch beta') ;;
    'ls-remote --exit-code --heads origin refs/heads/beta')
        printf '%s\trefs/heads/beta\n' "$VALIDATION_TEST_SHA" ;;
    archive*) ;;
    *) echo "unexpected git args: $*" >&2; exit 44 ;;
esac
EOF

    cat > "$dir/bin/swift" <<'EOF'
#!/bin/bash
printf 'swift\t%s\n' "$*" >> "$VALIDATION_TEST_LOG"
EOF

    cat > "$dir/bin/ssh" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'ssh\t%s\n' "$*" >> "$VALIDATION_TEST_LOG"
if [ -n "${VALIDATION_TEST_SSH_OFFLINE:-}" ]; then
    exit 255
fi
if [[ "$*" == *'uname=$(uname -s)'* ]]; then
    printf '%s\n' 'uname=Linux' 'bash=/bin/bash' 'tar=/bin/tar' 'mktemp=/usr/bin/mktemp' 'swift=Swift version 6.4.2'
elif [[ "$*" == *'mktemp -d'* ]]; then
    printf '%s\n' "$VALIDATION_TEST_REMOTE_DIR"
elif [[ "$*" == *'df -Pk /tmp /'* ]]; then
    cat "$VALIDATION_TEST_DF"
elif [[ "$*" == *'tar -xf -'* ]]; then
    cat >/dev/null
elif [[ "$*" == *'scripts/test-core.sh'* ]]; then
    :
elif [[ "$*" == *'rm -rf --'* ]]; then
    :
else
    echo "unexpected ssh args: $*" >&2
    exit 45
fi
EOF

    cat > "$dir/bin/gh" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'gh\t%s\n' "$*" >> "$VALIDATION_TEST_LOG"
case "$*" in
    'auth status') ;;
    'run list '*)
        if [ -n "${VALIDATION_TEST_CHANGE_ON_RUN_LIST:-}" ]; then
            printf '%s\n' "$VALIDATION_TEST_CHANGED_SHA" > "$VALIDATION_TEST_HEAD"
        fi
        printf '1\tpush\t%s\tcompleted/success\tbeta\tFull validation (Windows)\thttps://example.invalid/run/1\n' "$VALIDATION_TEST_SHA" ;;
    *) echo "unexpected gh args: $*" >&2; exit 46 ;;
esac
EOF
    chmod +x "$dir/bin/"*
    printf '%s\n' "$dir"
}

run_validation() { # $1=夹具目录
    (
        cd "$1"
        PATH="$1/bin:$PATH" \
        MATCHSTICKS_DS_LINUX_SSH_HOST=fixture-host \
        MATCHSTICKS_DS_LINUX_SWIFT_BIN=/opt/swift/bin/swift \
        GIT_TERMINAL_PROMPT=1 \
        VALIDATION_TEST_HEAD="$1/head" \
        VALIDATION_TEST_LOG="$1/commands.log" \
        VALIDATION_TEST_DF="$1/df.txt" \
        VALIDATION_TEST_SHA="$SHA" \
        VALIDATION_TEST_CHANGED_SHA="$CHANGED_SHA" \
        VALIDATION_TEST_REMOTE_DIR="$REMOTE_DIR" \
            bash scripts/validate-all.sh >"$1/stdout" 2>&1
    )
}

echo "== workflow：checkout 必须验证 PR 的精确 head，而非 merge ref =="
checkout_block="$(sed -n '/uses: actions\/checkout@/,/      - name:/p' .github/workflows/full-validation.yml)"
if grep -Fq 'ref: ${{ github.event.pull_request.head.sha || github.sha }}' <<< "$checkout_block"; then
    ok "checkout ref 使用 PR head SHA，非 PR 回退 github.sha"
else
    bad "checkout 缺少精确 ref：github.event.pull_request.head.sha || github.sha"
fi
# GitHub 只认固定的步骤级键；把动作输入（如 checkout 的 ref）写在步骤级会让整个 workflow
# 被判为 workflow file issue：任何事件都不产生 job（PR 也没有 check），Windows 端形同未运行。
echo "== workflow：步骤级只允许 GitHub Actions 认可的键；动作输入（checkout 的 ref）必须在 with: 之下 =="
step_key_violations="$(awk '
    /^[^ \t#]/ { steps_indent = -1 }
    match($0, /^ *steps:[ \t]*$/) { steps_indent = match($0, /[^ ]/) - 1; step_indent = -1; next }
    steps_indent < 0 { next }
    {
        if (!match($0, /[^ ]/)) next
        indent = RSTART - 1
        if (indent <= steps_indent || substr($0, RSTART, 1) == "#") next
        if (indent == steps_indent + 2 && substr($0, indent + 1, 2) == "- ") {
            step_indent = indent
            key = substr($0, indent + 3)
        } else if (step_indent >= 0 && indent == step_indent + 2) {
            key = substr($0, RSTART)
        } else {
            next
        }
        sub(/:.*/, "", key)
        if (key !~ /^(name|id|if|uses|run|shell|working-directory|env|with|continue-on-error|timeout-minutes)$/) print NR ": " key
    }' .github/workflows/full-validation.yml)"
if [ -z "$step_key_violations" ]; then
    ok "步骤级键均在 GitHub Actions 允许集合内"
else
    bad "步骤级出现未知键，GitHub 判 workflow file issue、整个 workflow 不运行：$step_key_violations"
fi
if awk '
    {
        if (prev_is_with) {
            match(prev, /^ */); w = RLENGTH
            match($0, /^ */); n = RLENGTH
            if (n == w + 2 && $0 ~ /^ *ref: \$\{\{ github\.event\.pull_request\.head\.sha \|\| github\.sha \}\}[ \t]*$/) ok = 1
        }
        prev = $0
        prev_is_with = (prev ~ /^ *with:[ \t]*$/)
    }
    END { exit ok ? 0 : 1 }' <<< "$checkout_block"; then
    ok "checkout 的 ref 作为 with: 输入传入（紧随 with: 之下）"
else
    bad "checkout 的 ref 不是 with: 输入（写在步骤级会被 GitHub 拒绝）"
fi
# windows-2025 标签 2026-11-24 实测已切到 VS 2026 镜像（windows-2025-vs2026）：写死 VS 年份/版本路径会让
# vcvarsall.bat 找不到。Visual Studio 一律经镜像自带的 vswhere 定位；Swift 的 Windows SDK 由同一安装器装到
# <安装根>\Platforms\<版本>\Windows.platform\Developer\SDKs\Windows.sdk 并写入 SDKROOT 环境变量，当前进程
# 不会刷新，必须从注册表读或按安装布局找（旧实现只找 <root>\usr\Platforms，永远找不到）。
echo "== workflow：Visual Studio 经 vswhere 定位；SDKROOT 取自安装器写入的环境或安装布局 =="
if grep -Eq 'Microsoft Visual Studio\\[0-9]{4}\\' .github/workflows/full-validation.yml; then
    bad "写死了 Visual Studio 年份/版本的安装路径（runner 镜像换 VS 版本即 vcvarsall.bat 找不到）"
else
    ok "未写死 Visual Studio 年份/版本安装路径"
fi
assert_contains "用镜像自带的 vswhere 定位 Visual Studio" .github/workflows/full-validation.yml 'vswhere.exe'
assert_contains "vswhere 要求 x64 C++ 工具集并取 installationPath" .github/workflows/full-validation.yml \
    '-requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath'
assert_contains "构建步骤调用定位到的 vcvarsall（经 GITHUB_ENV 传出）" .github/workflows/full-validation.yml \
    'call "%VCVARSALL%" x64'
assert_contains "SDKROOT 从安装器写入的环境读取" .github/workflows/full-validation.yml \
    "GetEnvironmentVariable('SDKROOT'"
assert_contains "SDKROOT 回退到安装布局 Platforms\…\Windows.sdk" .github/workflows/full-validation.yml \
    'Windows.platform\Developer\SDKs\Windows.sdk'
# 安装器写进注册表的目录属性带末尾反斜杠（…\Windows.sdk\）：导出前统一去掉。
assert_contains "SDKROOT 导出前去掉末尾反斜杠" .github/workflows/full-validation.yml ".TrimEnd('\')"
# SwiftPM 的清单编译在 Windows 上可能无任何诊断地非零退出（日志只剩「Invalid manifest」「Missing or empty
# JSON output」）；test-core.sh 失败后必须补打 verbose 输出与最小编译/运行探针，并且仍以非零码退出。
assert_contains "test-core 成功即以 0 退出，失败才进入诊断分支" .github/workflows/full-validation.yml \
    'scripts/test-core.sh && exit /b 0'
assert_contains "诊断分支输出 verbose SwiftPM" .github/workflows/full-validation.yml 'swift build --verbose --product DSCoreTests'
assert_contains "诊断分支编译并运行最小 Foundation 程序" .github/workflows/full-validation.yml 'msds-hello.exe'
# 新编译出的可执行文件（SwiftPM 清单程序、DSCoreTests.exe）在运行期需要安装器放在
# <安装根>\Runtimes\<版本>\usr\bin 的 swiftCore.dll 与 VC++ 运行库；安装器只把该目录追加进用户 PATH，
# 当前进程看不到。不把它加进 PATH，可执行文件一启动就是 STATUS_DLL_NOT_FOUND（0xC0000135）。
assert_contains "定位运行期目录 Runtimes\…\usr\bin" .github/workflows/full-validation.yml 'Runtimes\$toolchainVersion\usr\bin'
assert_contains "运行期目录校验 swiftCore.dll 存在" .github/workflows/full-validation.yml "'swiftCore.dll'"
assert_contains "运行期目录经 GITHUB_ENV 传出" .github/workflows/full-validation.yml 'SWIFT_RUNTIME_BIN='
assert_contains "构建步骤把运行期目录加进 PATH" .github/workflows/full-validation.yml \
    'set "PATH=%SWIFT_ROOT%\bin;%SWIFT_RUNTIME_BIN%;%PATH%"'
build_block="$(sed -n '/- name: Build and run DSCoreTests (native Winsock, Git Bash)/,/- name: Coverage/p' .github/workflows/full-validation.yml | sed '$d')"
build_last_line="$(printf '%s\n' "$build_block" | grep -v -E '^[[:space:]]*$' | tail -1 | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
if [ "$build_last_line" = "exit /b 1" ]; then
    ok "构建步骤以 exit /b 1 收尾（失败不被诊断分支吞掉）"
else
    bad "构建步骤没有以 exit /b 1 收尾（实际最后一行：${build_last_line}）"
fi

echo "== workflow：Linux fallback 仅在明确批准后运行 =="
assert_contains "Linux job 存在" .github/workflows/full-validation.yml 'linux-core:'
assert_contains "workflow_dispatch 输入明确写允许" .github/workflows/full-validation.yml "github.event.inputs.linux_approval == '允许'"
assert_contains "PR 仅在批准提交信息下触发 Linux fallback" .github/workflows/full-validation.yml \
    "github.event.pull_request.head_commit.message, '允许使用 GitHub Linux 验证'"
assert_contains "Linux fallback 使用 GitHub 托管 Ubuntu" .github/workflows/full-validation.yml 'runs-on: ubuntu-24.04'
assert_contains "云端结果不冒充实体验证" .github/workflows/full-validation.yml '不冒充实体 SSH 主机验证'

echo "== test-core：ss UDP 样例只按 Local Address:Port（第 4 列）过滤 =="
ss_sample="UNCONN 0      0                                 0.0.0.0:4000 0.0.0.0:1150
UNCONN 0      0                               127.0.0.1:323  0.0.0.0:*
UNCONN 0      0                                    [::]:1110 [::]:*
UNCONN 0      0      [fe80::452f:1aad:8a3e:3f3c]%wlp1s0:1150     [::]:*"
ss_expected="UNCONN 0      0                                    [::]:1110 [::]:*
UNCONN 0      0      [fe80::452f:1aad:8a3e:3f3c]%wlp1s0:1150     [::]:*"
ss_status=0
ss_actual="$(printf '%s\n' "$ss_sample" | bash scripts/test-core.sh --filter-ss)" || ss_status=$?
if [ "$ss_status" -eq 0 ] && [ "$ss_actual" = "$ss_expected" ]; then
    ok "保留本地 1150/1110（含 IPv6），忽略本地 4000 与 Peer 1150"
else
    bad "ss UDP 过滤结果错误（退出码 ${ss_status}）：$ss_actual"
fi
assert_contains "ports_busy 复用 ss UDP 过滤器" scripts/test-core.sh 'ss -Hlun 2>/dev/null || true; } | ss_udp_filter'

echo "== validate-all：固定 SHA、磁盘预检、缓存隔离、PATH 与自动发现 =="
case_dir="$(make_fixture full)"
if run_validation "$case_dir"; then
    ok "全 mock 三端流程通过"
else
    bad "全 mock 三端流程失败：$(cat "$case_dir/stdout")"
fi
assert_contains "Mac 前固定并禁止 git 终端凭据提示" "$case_dir/commands.log" 'git-prompt=0'
assert_contains "Linux 归档使用显式固定 SHA" "$case_dir/commands.log" "git	archive --format=tar $SHA"
assert_absent "Linux 不归档可变 HEAD" "$case_dir/commands.log" 'git	archive --format=tar HEAD'
assert_contains "远端 PATH 前置已验证的 Swift bin" "$case_dir/commands.log" "PATH='/opt/swift/bin':\$PATH"
assert_contains "SwiftPM cache 指向本次远端目录" "$case_dir/commands.log" "SWIFTPM_CACHE_PATH='$REMOTE_DIR/swiftpm-cache'"
assert_contains "manifest cache 固定在本次包的 build 目录" "$case_dir/commands.log" 'SWIFTPM_MANIFEST_CACHE=local'
assert_contains "Clang module cache 指向本次远端目录" "$case_dir/commands.log" "CLANG_MODULE_CACHE_PATH='$REMOTE_DIR/clang-module-cache'"
assert_contains "全部 test-*.sh 仍自动发现并执行" "$case_dir/commands.log" 'auto-discovered'

echo "== validate-all：磁盘空间不足时明确失败，不归档也不跑 Linux 测试 =="
case_dir="$(make_fixture low-disk)"
printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted on' > "$case_dir/df.txt"
printf '%s\n' '/dev/root 1000000 1000 675840 61% /' >> "$case_dir/df.txt"
printf '%s\n' 'tmpfs 1000000 1000 2097152 1% /tmp' >> "$case_dir/df.txt"
if run_validation "$case_dir"; then
    bad "根分区空间不足仍然通过"
else
    ok "根分区空间不足时失败"
fi
assert_contains "失败说明包含可用空间与未运行测试" "$case_dir/stdout" '未运行 DSCoreTests'
assert_absent "空间不足时不执行 git archive" "$case_dir/commands.log" 'git	archive'
assert_absent "空间不足时不执行远端 test-core" "$case_dir/commands.log" 'scripts/test-core.sh'
assert_contains "失败路径仍只清理本次远端目录" "$case_dir/commands.log" "fixture-host rm -rf -- '$REMOTE_DIR'"

echo "== validate-all：Windows 等待期间 HEAD 改变也必须失败 =="
case_dir="$(make_fixture changed-head)"
if VALIDATION_TEST_CHANGE_ON_RUN_LIST=1 run_validation "$case_dir"; then
    bad "HEAD 已改变仍然输出三端通过"
else
    ok "结束时复核 HEAD 并拒绝变化"
fi
assert_contains "失败报告包含原 SHA 与新 SHA" "$case_dir/stdout" "$SHA"
assert_contains "失败报告包含变化后的 SHA" "$case_dir/stdout" "$CHANGED_SHA"

echo "== validate-all：实体 Linux 不可达且未批准会立即停止 =="
case_dir="$(make_fixture offline-unapproved)"
if VALIDATION_TEST_SSH_OFFLINE=1 run_validation "$case_dir"; then
    bad "SSH 不可达且未批准仍然通过"
else
    ok "SSH 不可达且未批准会失败"
fi
assert_contains "失败时询问是否允许 GitHub Linux" "$case_dir/stdout" '是否允许使用 GitHub 提供的 Linux 环境进行验证'
assert_contains "提示批准的明确环境变量" "$case_dir/stdout" 'MATCHSTICKS_DS_LINUX_GITHUB_APPROVED=允许'
assert_absent "未批准不执行 Linux 归档" "$case_dir/commands.log" 'git\tarchive'
assert_absent "未批准不启动 Mac 构建" "$case_dir/commands.log" 'swift\t'
assert_absent "未批准不触发云端 dispatch" "$case_dir/commands.log" 'workflow run'

echo "== validate-all：明确批准后才允许 GitHub Linux fallback =="
case_dir="$(make_fixture offline-approved)"
if MATCHSTICKS_DS_LINUX_GITHUB_APPROVED=允许 VALIDATION_TEST_SSH_OFFLINE=1 run_validation "$case_dir"; then
    ok "明确批准后 Linux fallback 可完成"
else
    bad "明确批准后 Linux fallback 仍失败：$(cat "$case_dir/stdout")"
fi
assert_contains "云端结果明确标为 GitHub Ubuntu" "$case_dir/stdout" 'Linux GitHub Actions ubuntu-24.04 DSCoreTests'
assert_contains "云端结果不冒充实体验证" "$case_dir/stdout" '用户已批准'
assert_absent "批准 fallback 后不跑实体 Linux 测试" "$case_dir/commands.log" 'scripts/test-core.sh'

echo
if [ "$FAIL" -eq 0 ]; then
    echo "validation script tests: $PASS passed"
else
    echo "validation script tests: $FAIL failed, $PASS passed" >&2
    exit 1
fi
