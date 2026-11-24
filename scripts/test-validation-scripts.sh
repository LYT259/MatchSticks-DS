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

echo
if [ "$FAIL" -eq 0 ]; then
    echo "validation script tests: $PASS passed"
else
    echo "validation script tests: $FAIL failed, $PASS passed" >&2
    exit 1
fi
