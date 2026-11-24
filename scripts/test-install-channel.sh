#!/bin/bash
# MatchSticks DS 终端安装通道与门禁回归测试。
# 执行真实 install.sh / shasum；PATH 假命令隔离 GitHub、DMG 挂载与 /Applications。
# 可由 validate-all.sh 按 test-*.sh 自动发现，不需要网络或真实安装包。
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
INSTALL="$ROOT/scripts/install.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/matchsticks-install-channel.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

BIN="$WORK/bin"
mkdir -p "$BIN" "$WORK/fixtures"
PASS=0
FAIL=0
FAILED=()
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); FAILED+=("$1"); }
assert_contains() { # $1=描述 $2=文件 $3=文本
    if grep -Fq -- "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1"; fi
}
assert_line() { # $1=描述 $2=文件 $3=完整行
    if grep -Fqx -- "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1"; fi
}
assert_no_line() { # $1=描述 $2=文件 $3=完整行
    if grep -Fqx -- "$3" "$2" 2>/dev/null; then bad "$1"; else ok "$1"; fi
}
assert_not_installed() { # $1=描述 $2=case目录
    if [ ! -e "$2/rsync.log" ] && [ ! -e "$2/cp.log" ]; then
        ok "$1"
    else
        bad "$1（安装命令已被调用）"
    fi
}
new_case() { mkdir -p "$WORK/$1"; printf '%s\n' "$WORK/$1"; }

cat > "$BIN/curl" <<'EOF'
#!/bin/bash
set -euo pipefail
url="${!#}"
printf '%s\n' "$url" >> "$INSTALL_TEST_CURL_LOG"
out=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    if [ "${args[$i]}" = "-o" ]; then out="${args[$((i + 1))]}"; fi
done
if [ -n "${INSTALL_TEST_FAIL_URL:-}" ] && [ "$url" = "$INSTALL_TEST_FAIL_URL" ]; then
    echo "injected curl failure: $url" >&2
    exit 22
fi
case "$url" in
    "https://api.github.com/repos/LYT259/MatchSticks-DS/releases") cat "$INSTALL_TEST_LIST_JSON" ;;
    "https://api.github.com/repos/LYT259/MatchSticks-DS/releases/latest") cat "$INSTALL_TEST_LATEST_JSON" ;;
    https://github.com/LYT259/MatchSticks-DS/releases/download/*/SHA256SUMS) cat "$INSTALL_TEST_SUMS" ;;
    https://github.com/LYT259/MatchSticks-DS/releases/download/*/MatchSticks-DS-*.dmg)
        [ -n "$out" ] || exit 64
        /bin/cp "$INSTALL_TEST_DMG" "$out"
        ;;
    *) exit 64 ;;
esac
EOF
cat > "$BIN/hdiutil" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$INSTALL_TEST_HDIUTIL_LOG"
if [ "${1:-}" = attach ] && [ -n "${INSTALL_TEST_HDIUTIL_FAIL:-}" ]; then
    echo "injected hdiutil failure" >&2
    exit 23
fi
case "${1:-}" in attach|detach) exit 0 ;; *) exit 64 ;; esac
EOF
cat > "$BIN/rsync" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$INSTALL_TEST_RSYNC_LOG"
EOF
cat > "$BIN/cp" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$INSTALL_TEST_CP_LOG"
EOF
chmod +x "$BIN"/*

API="https://api.github.com/repos/LYT259/MatchSticks-DS"
STABLE="v1.4.2"
BETA="v1.5.0-beta.1"
STABLE_BASE="https://github.com/LYT259/MatchSticks-DS/releases/download/$STABLE"
BETA_BASE="https://github.com/LYT259/MatchSticks-DS/releases/download/$BETA"
STABLE_DMG="$STABLE_BASE/MatchSticks-DS-1.4.2.dmg"
BETA_DMG="$BETA_BASE/MatchSticks-DS-1.5.0-beta.1.dmg"
printf 'stable-test-dmg\n' > "$WORK/fixtures/payload.dmg"
PAYLOAD_SHA="$(shasum -a 256 "$WORK/fixtures/payload.dmg" | awk '{print $1}')"
printf '%s  MatchSticks-DS-1.4.2.dmg\n%s  MatchSticks-DS-1.5.0-beta.1.dmg\n' \
    "$PAYLOAD_SHA" "$PAYLOAD_SHA" > "$WORK/fixtures/SHA256SUMS"
cat > "$WORK/fixtures/latest.json" <<EOF
{
  "tag_name": "$STABLE",
  "name": "MatchSticks DS 1.4.2",
  "draft": false,
  "prerelease": false,
  "created_at": "2026-11-01T00:00:00Z",
  "published_at": "2026-11-01T00:00:00Z"
}
EOF
cat > "$WORK/fixtures/releases.json" <<EOF
[
  {
    "tag_name": "$BETA",
    "name": "MatchSticks DS 1.5.0 beta 1",
    "draft": false,
    "prerelease": true,
    "created_at": "2026-11-23T00:00:00Z",
    "published_at": "2026-11-23T00:00:00Z"
  },
  {
    "tag_name": "$STABLE",
    "name": "MatchSticks DS 1.4.2",
    "draft": false,
    "prerelease": false,
    "created_at": "2026-11-01T00:00:00Z",
    "published_at": "2026-11-01T00:00:00Z"
  }
]
EOF

run_installer() { # $1=case目录；其余参数原样传给 install.sh
    local case_dir="$1"
    shift
    (
        export PATH="$BIN:$PATH"
        export INSTALL_TEST_CURL_LOG="$case_dir/curl.log"
        export INSTALL_TEST_HDIUTIL_LOG="$case_dir/hdiutil.log"
        export INSTALL_TEST_RSYNC_LOG="$case_dir/rsync.log"
        export INSTALL_TEST_CP_LOG="$case_dir/cp.log"
        export INSTALL_TEST_LIST_JSON="$WORK/fixtures/releases.json"
        export INSTALL_TEST_LATEST_JSON="${INSTALL_TEST_LATEST_JSON:-$WORK/fixtures/latest.json}"
        export INSTALL_TEST_DMG="$WORK/fixtures/payload.dmg"
        export INSTALL_TEST_SUMS="${INSTALL_TEST_SUMS:-$WORK/fixtures/SHA256SUMS}"
        export INSTALL_TEST_FAIL_URL="${INSTALL_TEST_FAIL_URL:-}"
        export INSTALL_TEST_HDIUTIL_FAIL="${INSTALL_TEST_HDIUTIL_FAIL:-}"
        bash "$INSTALL" "$@" > "$case_dir/stdout" 2> "$case_dir/stderr"
    )
}

echo "▶ T1 无参数：即使 beta pre-release 更新，也查询 latest 并安装 stable"
CASE="$(new_case default-stable)"
if run_installer "$CASE"; then ok "默认安装成功"; else bad "默认安装失败（exit=$?）"; fi
assert_line "默认调用 /releases/latest" "$CASE/curl.log" "$API/releases/latest"
assert_no_line "默认不调用 /releases 列表" "$CASE/curl.log" "$API/releases"
assert_line "默认下载 stable DMG" "$CASE/curl.log" "$STABLE_DMG"
assert_no_line "默认不下载 beta DMG" "$CASE/curl.log" "$BETA_DMG"
assert_contains "默认安装使用原 rsync 流程" "$CASE/rsync.log" "/Applications/"
assert_contains "完成信息保持 stable 版本" "$CASE/stdout" "1.4.2"

echo "▶ T2 显式 beta tag：兼容原有首参数指定版本用法"
CASE="$(new_case explicit-beta)"
if run_installer "$CASE" "$BETA"; then ok "显式 beta 安装成功"; else bad "显式 beta 安装失败"; fi
assert_no_line "显式 tag 不查询 latest" "$CASE/curl.log" "$API/releases/latest"
assert_no_line "显式 tag 不查询 /releases 列表" "$CASE/curl.log" "$API/releases"
assert_line "显式 tag 下载 beta DMG" "$CASE/curl.log" "$BETA_DMG"
assert_no_line "显式 tag 不下载 stable DMG" "$CASE/curl.log" "$STABLE_DMG"
assert_contains "显式 tag 仍走校验后的安装流程" "$CASE/rsync.log" "/Applications/"

echo "▶ T3 latest 请求失败：不回退到含 beta 的 /releases 列表"
CASE="$(new_case latest-http-failure)"
if INSTALL_TEST_FAIL_URL="$API/releases/latest" run_installer "$CASE"; then
    bad "latest 失败时安装竟然成功"
else
    ok "latest 失败时安装以非零码退出"
fi
assert_no_line "latest HTTP 失败不查询 /releases 列表" "$CASE/curl.log" "$API/releases"
assert_no_line "latest HTTP 失败不下载 stable" "$CASE/curl.log" "$STABLE_DMG"
assert_no_line "latest HTTP 失败不下载 beta" "$CASE/curl.log" "$BETA_DMG"
assert_not_installed "latest HTTP 失败不调用安装命令" "$CASE"

echo "▶ T4 latest 空响应：不把列表中的 beta 当作回退版本"
CASE="$(new_case latest-empty)"
if INSTALL_TEST_LATEST_JSON=/dev/null run_installer "$CASE"; then
    bad "latest 空响应时安装竟然成功"
else
    ok "latest 空响应时安装以非零码退出"
fi
assert_no_line "latest 空响应不查询 /releases 列表" "$CASE/curl.log" "$API/releases"
assert_no_line "latest 空响应不下载 beta" "$CASE/curl.log" "$BETA_DMG"
assert_not_installed "latest 空响应不调用安装命令" "$CASE"

echo "▶ T5 DMG 下载失败：不进入 SHA256 或安装"
CASE="$(new_case dmg-failure)"
if INSTALL_TEST_FAIL_URL="$STABLE_DMG" run_installer "$CASE" "$STABLE"; then
    bad "DMG 下载失败时安装竟然成功"
else
    ok "DMG 下载失败时安装以非零码退出"
fi
assert_no_line "DMG 失败不读取 SHA256SUMS" "$CASE/curl.log" "$STABLE_BASE/SHA256SUMS"
assert_not_installed "DMG 失败不调用安装命令" "$CASE"

echo "▶ T6 SHA256 不匹配：不挂载、不安装"
CASE="$(new_case sha-mismatch)"
MISMATCH_SHA="0000000000000000000000000000000000000000000000000000000000000000"
printf '%s  MatchSticks-DS-1.4.2.dmg\n' "$MISMATCH_SHA" > "$CASE/SHA256SUMS"
if INSTALL_TEST_SUMS="$CASE/SHA256SUMS" run_installer "$CASE" "$STABLE"; then
    bad "SHA256 不匹配时安装竟然成功"
else
    ok "SHA256 不匹配时安装以非零码退出"
fi
assert_line "SHA256 错误完整显示期望与实际摘要" "$CASE/stderr" "✗ 校验失败（期望 ${MISMATCH_SHA}，得到 ${PAYLOAD_SHA}）"
assert_not_installed "SHA256 不匹配不调用安装命令" "$CASE"
if [ ! -e "$CASE/hdiutil.log" ]; then ok "SHA256 不匹配不挂载 DMG"; else bad "SHA256 不匹配仍挂载了 DMG"; fi

echo "▶ T7 SHA256SUMS 缺少条目：不挂载、不安装"
CASE="$(new_case sha-missing)"
printf '%s  another.dmg\n' "$PAYLOAD_SHA" > "$CASE/SHA256SUMS"
if INSTALL_TEST_SUMS="$CASE/SHA256SUMS" run_installer "$CASE" "$STABLE"; then
    bad "SHA256SUMS 缺少条目时安装竟然成功"
else
    ok "SHA256SUMS 缺少条目时安装以非零码退出"
fi
assert_contains "缺少条目给出明确错误" "$CASE/stderr" "SHA256SUMS 中找不到"
assert_not_installed "SHA256SUMS 缺少条目不调用安装命令" "$CASE"
if [ ! -e "$CASE/hdiutil.log" ]; then ok "缺少条目不挂载 DMG"; else bad "缺少条目仍挂载了 DMG"; fi

echo "▶ T8 SHA256SUMS 请求失败：不挂载、不安装"
CASE="$(new_case sums-failure)"
if INSTALL_TEST_FAIL_URL="$STABLE_BASE/SHA256SUMS" run_installer "$CASE" "$STABLE"; then
    bad "SHA256SUMS 请求失败时安装竟然成功"
else
    ok "SHA256SUMS 请求失败时安装以非零码退出"
fi
assert_not_installed "SHA256SUMS 失败不调用安装命令" "$CASE"
if [ ! -e "$CASE/hdiutil.log" ]; then ok "SHA256SUMS 失败不挂载 DMG"; else bad "SHA256SUMS 失败仍挂载了 DMG"; fi

echo "▶ T9 挂载失败：不调用安装命令"
CASE="$(new_case mount-failure)"
if INSTALL_TEST_HDIUTIL_FAIL=1 run_installer "$CASE" "$STABLE"; then
    bad "挂载失败时安装竟然成功"
else
    ok "挂载失败时安装以非零码退出"
fi
assert_contains "挂载失败确实到达 hdiutil 门禁" "$CASE/hdiutil.log" "attach"
assert_not_installed "挂载失败不调用安装命令" "$CASE"

echo
echo "结果：$PASS 通过 / $FAIL 失败"
if [ "$FAIL" -gt 0 ]; then
    printf '失败项：%s\n' "${FAILED[*]}"
    exit 1
fi
echo "✅ 安装通道选择、SHA256 与安装门禁全部符合契约"
