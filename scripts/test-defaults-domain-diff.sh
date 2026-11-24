#!/bin/bash
# defaults-domain-diff.py 的 fixture 测试：只用 mktemp 目录里的合成 plist，不读写任何真实 defaults 域。
#
# 验证正式域键级比较的契约（打包 E2E 据此判定「测试是否写入了真实域」）：
#   ① 仅 --allow 列出的键（打包 E2E 传 NSWindow Frame main/mini）变化 → 退出 0，逐键单独报告；
#   ② 其余任何键（matchsticks.* / ghds.* / SU* / 其他）变化、新增或删除 → 退出 1，只报告键名；
#   ③ allowlist 是调用方的显式策略：不带 --allow 时窗口框架键变化同样退出 1；
#   ④ 任何输出都不得含值（fixture 里埋 sentinel，全程 grep）。
#
# 用法：bash scripts/test-defaults-domain-diff.sh
set -euo pipefail
cd "$(dirname "$0")/.."
DIFF="scripts/defaults-domain-diff.py"

fail() { echo "✗ $1" >&2; exit 1; }
[ -f "$DIFF" ] || fail "缺少 ${DIFF}（正式域键级比较 helper 尚未实现）"
command -v python3 >/dev/null 2>&1 || fail "需要 python3"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/matchsticks-driver-station-domain-diff-test.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

SECRET="SENTINEL_SECRET_VALUE_7f3a9c"
python3 - "$WORK" "$SECRET" <<'PY'
import plistlib, sys
from datetime import datetime

work, secret = sys.argv[1], sys.argv[2]


def base():
    return {
        "NSWindow Frame main": "{{100, 100}, {1180, 820}} " + secret,
        "NSWindow Frame mini": "{{100, 600}, {768, 168}} " + secret,
        "matchsticks.teamNumber": 254,
        "matchsticks.manualIP": secret,
        "ghds.language": "chinese",
        "SUEnableAutomaticChecks": True,
        "SULastCheckTime": datetime(2026, 11, 24, 7, 8, 21),
    }


def write(name, data):
    with open(f"{work}/{name}.plist", "wb") as stream:
        plistlib.dump(data, stream)


def case(name, before=None, after=None):
    b, a = base(), base()
    if before:
        before(b)
    if after:
        after(a)
    write(f"{name}-before", b)
    write(f"{name}-after", a)


def put(d, key, value):
    d[key] = value


case("identical")
case("frame-main", after=lambda a: put(a, "NSWindow Frame main", "{{0, 0}, {1180, 820}} " + secret))
case("frame-main-noallow", after=lambda a: put(a, "NSWindow Frame main", "{{0, 0}, {1180, 820}} " + secret))
case("frame-mini", after=lambda a: put(a, "NSWindow Frame mini", "{{0, 0}, {768, 168}} " + secret))
case("frame-both", after=lambda a: (put(a, "NSWindow Frame main", "x " + secret),
                                   put(a, "NSWindow Frame mini", "y " + secret)))
case("frame-main-added", before=lambda b: b.pop("NSWindow Frame main"))
case("frame-main-removed", after=lambda a: a.pop("NSWindow Frame main"))
case("matchsticks", after=lambda a: put(a, "matchsticks.teamNumber", 999))
case("ghds", after=lambda a: put(a, "ghds.language", "english"))
case("sparkle", after=lambda a: put(a, "SULastCheckTime", datetime(2026, 11, 24, 9, 0, 0)))
case("new-key", after=lambda a: put(a, "NSNavLastRootDirectory", "/Applications"))
case("removed-key", after=lambda a: a.pop("matchsticks.manualIP"))
case("mixed", after=lambda a: (put(a, "NSWindow Frame main", "x " + secret),
                               put(a, "matchsticks.teamNumber", 999)))
PY

ALLOW=(--allow "NSWindow Frame main" --allow "NSWindow Frame mini")
PASS=0

run() { # $1=name $2=expected exit $3...=helper 参数；stdout/stderr 落到 $WORK/<name>.{out,err}
    local name="$1" expect="$2" rc; shift 2
    set +e
    python3 "$DIFF" "$WORK/$name-before.plist" "$WORK/$name-after.plist" "$@" >"$WORK/$name.out" 2>"$WORK/$name.err"
    rc=$?
    set -e
    [ "$rc" = "$expect" ] || fail "${name}: 退出码 ${rc}，预期 ${expect}（stderr: $(cat "$WORK/$name.err" 2>/dev/null || true)）"
}
has() { grep -Fxq -- "$2" "$WORK/$1.out" || fail "${1}: 输出缺少「${2}」"; }
lacks() { if grep -Fxq -- "$2" "$WORK/$1.out"; then fail "${1}: 输出不应含「${2}」"; fi; }
lines() { [ "$(wc -l < "$WORK/$1.out" | tr -d ' ')" = "$2" ] || fail "${1}: 期望 ${2} 行输出，实际 $(wc -l < "$WORK/$1.out" | tr -d ' ')行"; }
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }

# ① 仅窗口框架键变化：放行并逐键报告
run identical 0 "${ALLOW[@]}"
lines identical 0
ok "无变化 → 退出 0、无输出"
run frame-main 0 "${ALLOW[@]}"
has frame-main "allowed: NSWindow Frame main"
lines frame-main 1
ok "仅 NSWindow Frame main 变化 → 放行并报告键名"
run frame-mini 0 "${ALLOW[@]}"
has frame-mini "allowed: NSWindow Frame mini"
lines frame-mini 1
ok "仅 NSWindow Frame mini 变化 → 放行并报告键名"
run frame-both 0 "${ALLOW[@]}"
has frame-both "allowed: NSWindow Frame main"
has frame-both "allowed: NSWindow Frame mini"
lines frame-both 2
ok "两个窗口框架键都变 → 放行并报告两个键名"
run frame-main-added 0 "${ALLOW[@]}"
has frame-main-added "allowed: NSWindow Frame main"
ok "窗口框架键新增 → 放行"
run frame-main-removed 0 "${ALLOW[@]}"
has frame-main-removed "allowed: NSWindow Frame main"
ok "窗口框架键删除 → 放行"

# ③ allowlist 必须显式：不带 --allow 时窗口框架键变化同样失败
run frame-main-noallow 1
has frame-main-noallow "changed: NSWindow Frame main"
ok "不带 --allow → 窗口框架键变化也失败"

# ② 其他键变化 / 新增 / 删除 → 失败，只报键名
run matchsticks 1 "${ALLOW[@]}"
has matchsticks "changed: matchsticks.teamNumber"
lacks matchsticks "allowed: NSWindow Frame main"
ok "matchsticks.* 变化 → 失败"
run ghds 1 "${ALLOW[@]}"
has ghds "changed: ghds.language"
ok "ghds.* 变化 → 失败"
run sparkle 1 "${ALLOW[@]}"
has sparkle "changed: SULastCheckTime"
ok "SU* 变化 → 失败"
run new-key 1 "${ALLOW[@]}"
has new-key "changed: NSNavLastRootDirectory"
ok "其他键新增 → 失败"
run removed-key 1 "${ALLOW[@]}"
has removed-key "changed: matchsticks.manualIP"
ok "其他键删除 → 失败"
run mixed 1 "${ALLOW[@]}"
has mixed "allowed: NSWindow Frame main"
has mixed "changed: matchsticks.teamNumber"
lines mixed 2
ok "框架键 + 真实泄漏同时出现 → 仍失败，两者分别报告"

# 损坏的快照 → 退出 2，不崩溃
printf 'not a plist' >"$WORK/bad.plist"
set +e
python3 "$DIFF" "$WORK/bad.plist" "$WORK/identical-after.plist" >"$WORK/bad.out" 2>"$WORK/bad.err"
rc=$?
set -e
[ "$rc" = 2 ] || fail "bad: 退出码 ${rc}，预期 2"
ok "损坏的 plist → 退出 2"

# ④ 任何输出都不得含值
if grep -rqF -- "$SECRET" "$WORK"/*.out "$WORK"/*.err; then fail "输出泄露了值（发现 sentinel）"; fi
ok "全部输出不含任何值"

echo ""
echo "✅ defaults-domain-diff fixture 测试通过（${PASS} 例）"
