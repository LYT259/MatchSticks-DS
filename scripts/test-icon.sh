#!/bin/bash
# scripts/test-icon.sh — 图标生成器（make-icon.swift）行为测试
# 契约：所有生成的图标必须派生自用户原稿 Sources/MatchSticksDriverStation/Resources/AppIcons/，
# 彻底淘汰旧 CoreGraphics 程序绘制图标。本脚本只测生成器行为，不跑完整 build-app.sh、
# 不触碰 dist/。用法：scripts/test-icon.sh（退出码 0=全绿，1=有失败）
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
GEN="$ROOT/scripts/make-icon.swift"
MASTER_SRC="$ROOT/Sources/MatchSticksDriverStation/Resources/AppIcons/app-icon-day.png"

if [ ! -f "$MASTER_SRC" ]; then
  echo "test-icon.sh: 母版缺失：$MASTER_SRC" >&2
  exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/matchsticks-icon-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
FAILED=()

ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); FAILED+=("$1"); }

# gen <outDir> <sourcePNG>：静默运行生成器，stderr 落盘供断言错误信息
gen() {
  swift "$GEN" "$1" "$2" >/dev/null 2>"$TMP/gen.err"
}

# px <png>：输出 "WxH"
px() {
  local w h
  w="$(sips -g pixelWidth "$1" 2>/dev/null | awk '/pixelWidth/ {print $2}')"
  h="$(sips -g pixelHeight "$1" 2>/dev/null | awk '/pixelHeight/ {print $2}')"
  echo "${w}x${h}"
}

echo "▶ 准备：母版副本（测试不写仓库路径）"
cp "$MASTER_SRC" "$TMP/master.png"
OUT="$TMP/out"

echo "▶ T1 生成器以母版成功退出"
if gen "$OUT" "$TMP/master.png"; then
  ok "生成器成功退出"
else
  bad "生成器未能成功退出（stderr：$(tail -n 1 "$TMP/gen.err" 2>/dev/null || true)）"
fi

echo "▶ T2 完整 10 尺寸（文件存在 + 像素尺寸逐一正确）"
for NAME in icon_16x16.png icon_16x16@2x.png icon_32x32.png icon_32x32@2x.png \
            icon_128x128.png icon_128x128@2x.png icon_256x256.png icon_256x256@2x.png \
            icon_512x512.png icon_512x512@2x.png; do
  WANT=""
  case "$NAME" in
    icon_16x16.png) WANT=16 ;;
    icon_16x16@2x.png) WANT=32 ;;
    icon_32x32.png) WANT=32 ;;
    icon_32x32@2x.png) WANT=64 ;;
    icon_128x128.png) WANT=128 ;;
    icon_128x128@2x.png) WANT=256 ;;
    icon_256x256.png) WANT=256 ;;
    icon_256x256@2x.png) WANT=512 ;;
    icon_512x512.png) WANT=512 ;;
    icon_512x512@2x.png) WANT=1024 ;;
  esac
  FILE="$OUT/AppIcon.iconset/$NAME"
  if [ -s "$FILE" ] && [ "$(px "$FILE")" = "${WANT}x${WANT}" ]; then
    ok "$NAME ${WANT}×${WANT}"
  else
    bad "$NAME 应为 ${WANT}×${WANT}（实际：$([ -s "$FILE" ] && px "$FILE" || echo 缺失)）"
  fi
done

echo "▶ T3 1024 母版条目（icon_512x512@2x.png）与母版字节一致"
if cmp -s "$OUT/AppIcon.iconset/icon_512x512@2x.png" "$TMP/master.png"; then
  ok "icon_512x512@2x.png 与母版逐字节相同"
else
  bad "icon_512x512@2x.png 与母版不一致——生成器没有原样使用用户图稿"
fi

echo "▶ T4 重复生成刷新陈旧产物"
printf 'STALE-GARBAGE' > "$OUT/AppIcon.iconset/icon_16x16.png"
touch "$OUT/AppIcon.iconset/stale-junk.png"
if gen "$OUT" "$TMP/master.png"; then
  ok "重复生成成功退出"
else
  bad "重复生成失败（stderr：$(tail -n 1 "$TMP/gen.err" 2>/dev/null || true)）"
fi
if [ ! -e "$OUT/AppIcon.iconset/stale-junk.png" ]; then
  ok "iconset 内陈旧杂散文件被整体清除"
else
  bad "iconset 内陈旧杂散文件残留——未整体重建"
fi
if cmp -s "$OUT/AppIcon.iconset/icon_512x512@2x.png" "$TMP/master.png"; then
  ok "1024 条目重新生成后仍与母版一致"
else
  bad "1024 条目重新生成后与母版不一致"
fi
if [ "$(px "$OUT/AppIcon.iconset/icon_16x16.png" 2>/dev/null || echo 坏图)" = "16x16" ]; then
  ok "被写坏的小尺寸条目被刷新为合法 PNG"
else
  bad "被写坏的小尺寸条目未被刷新"
fi

echo "▶ T5 坏源路径明确失败（nonzero 退出 + 报错点名路径）"
if gen "$OUT" "$TMP/definitely-missing.png"; then
  bad "坏源路径竟然成功退出——生成器没有真正依赖母版"
else
  ok "坏源路径以非零码退出"
fi
if grep -qF "definitely-missing.png" "$TMP/gen.err" 2>/dev/null; then
  ok "错误信息点名缺失的源路径"
else
  bad "错误信息未点名缺失的源路径"
fi

echo "▶ T6 非 1024×1024 母版明确失败"
sips -z 512 512 "$TMP/master.png" --out "$TMP/master-512.png" >/dev/null 2>&1
if gen "$TMP/out512" "$TMP/master-512.png"; then
  bad "512×512 源竟然成功——错误尺寸母版必须被拒绝"
else
  ok "非 1024×1024 母版以非零码退出"
fi

echo "▶ T7 损坏源（非图片内容）明确失败"
printf 'CORRUPTED NOT AN IMAGE %s\n' "$(date +%s)" > "$TMP/corrupt.png"
if gen "$OUT" "$TMP/corrupt.png"; then
  bad "损坏源竟然成功退出"
else
  ok "损坏源（非图片内容）以非零码退出"
fi
if [ -s "$TMP/gen.err" ]; then
  ok "损坏源失败时 stderr 有明确报错"
else
  bad "损坏源失败但 stderr 为空——失败原因不可见"
fi

echo "▶ T8 异 cwd 调用：相对脚本路径也必须解析到仓库母版"
REPO_MASTER="$ROOT/Sources/MatchSticksDriverStation/Resources/AppIcons/app-icon-day.png"
# 变体一：从工作区根（仓库外层）用不带 ../ 的相对脚本路径调用
WS_ROOT="$(cd "$ROOT/../.." && pwd)"
ROOT_REL_A="worktrees/$(basename "$ROOT")/scripts/make-icon.swift"
OUT_WS="$TMP/out-ws"; CODE_WS=0
( cd "$WS_ROOT" && swift "$ROOT_REL_A" "$OUT_WS" ) >"$TMP/t8a.out" 2>"$TMP/t8a.err" || CODE_WS=$?
if [ "$CODE_WS" -eq 0 ] && cmp -s "$OUT_WS/AppIcon.iconset/icon_512x512@2x.png" "$REPO_MASTER"; then
  ok "外层 cwd + 相对脚本路径：母版解析正确且 1024 逐字节一致"
else
  bad "外层 cwd + 相对脚本路径解析失败（exit=${CODE_WS}：$(tail -1 "$TMP/t8a.err" 2>/dev/null || true)）"
fi
# 变体二：从仓库内深层目录用带 ../../../ 的相对脚本路径调用
PROBE="$ROOT/.build/icon-test/cwd-probe"
mkdir -p "$PROBE"
OUT_DD="$TMP/out-dd"; CODE_DD=0
( cd "$PROBE" && swift ../../../scripts/make-icon.swift "$OUT_DD" ) >"$TMP/t8b.out" 2>"$TMP/t8b.err" || CODE_DD=$?
if [ "$CODE_DD" -eq 0 ] && cmp -s "$OUT_DD/AppIcon.iconset/icon_512x512@2x.png" "$REPO_MASTER"; then
  ok "../../../ 相对脚本路径：母版解析正确且 1024 逐字节一致"
else
  bad "../../../ 相对脚本路径解析失败（exit=${CODE_DD}：$(tail -1 "$TMP/t8b.err" 2>/dev/null || true)）"
fi

echo
echo "结果：$PASS 通过 / $FAIL 失败"
if [ "$FAIL" -gt 0 ]; then
  printf '失败项：%s\n' "${FAILED[*]}"
  exit 1
fi
echo "✅ 图标生成器行为全部符合契约"
