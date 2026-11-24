#!/bin/bash
# scripts/test-icon-geometry.sh — 图标几何契约测试（可见底板轮廓 + Icon Composer 全幅输入）
# 契约（2026-11 图标返修，定量测量定案，不凭目测）：
#   T1 四张仓库图稿（Sources/.../AppIcons/）可见底板必须与参考掩膜轮廓一致：
#      可见边长 824±4、bbox 与掩膜 bbox 对齐 ±2px、中心偏移 ≤2px——与 Apple 原生一致
#      （原生显示瓦片与 bundle icns 图稿均为 824/1024 尺寸锚点）。
#   T2 图稿 alpha 不得超过掩膜（掩膜乘法语义；超透明边 = Stage Manager/侧边白圈的来源）、
#      掩膜实心区必须铺满底板色、二值轮廓 IoU ≥ 0.995（边缘弧度一致）。
#   T0 掩膜角部形状必须与本机原生显示瓦片一致（Apple Music，NSWorkspace 1024 直出；
#      macOS 27.3 实测 squircle r/side 中位 0.26304，Mail/Podcasts/App Store 交叉验证）。
#   T3 calibrate-icon.swift normalize 从原稿可重复再生仓库四稿（逐字节一致）。
#   T4 calibrate-icon.swift full-bleed 产出全幅无透明边距的日/夜间 1024 输入：
#      全画布不透明（opaqueFraction = 1.0、bbox 全幅）、四角为底板色（系统负责原生圆角）。
# 本脚本只测几何与派生行为，不跑完整 build-app.sh、不触碰 dist/。
# 用法：scripts/test-icon-geometry.sh（退出码 0=全绿，1=有失败）
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
GEO="$ROOT/scripts/icon-geometry.swift"
CAL="$ROOT/scripts/calibrate-icon.swift"
ASSETS="$ROOT/scripts/icon-assets"
ICON_SRC="$ROOT/Sources/MatchSticksDriverStation/Resources/AppIcons"
MASK="$ASSETS/baseplate-mask-1024.png"
ORIG="$ASSETS/originals"

for F in "$GEO"; do [ -f "$F" ] || { echo "test-icon-geometry.sh: 缺测量工具：$F" >&2; exit 1; }; done
for M in app-icon-day.png app-icon-night.png app-icon-mono-day.png app-icon-mono-night.png; do
  [ -f "$ICON_SRC/$M" ] || { echo "test-icon-geometry.sh: 图稿缺失：$ICON_SRC/$M" >&2; exit 1; }
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/matchsticks-icon-geo.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0; FAILED=()
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); FAILED+=("$1"); }

# jget <json-file> <py-expr over d>：从测量 JSON 取值
jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }

measure() { swift "$GEO" measure "$1" > "$TMP/m.json" 2>"$TMP/m.err"; }

echo "▶ T0 参考掩膜就位且几何正确（824×824 居中于 1024 画布；角部形状=本机原生瓦片）"
# 形状锚点（2026-11 复核定案，非目测）：macOS 27.3（26C5047e）NSWorkspace 渲染的
# Apple Music 原生瓦片（1024 直出，Mail/Podcasts/App Store 四 app 几何逐字节一致）：
# 可见 824×824 居中，角部连续曲率（squircle），归一化内缩剖面 d=2→0.2524、d=8→0.1990、
# d=32→0.1226，圆角半径中位 r/side=0.26304。审查的 0.2286–0.2311 实为 bundle 内 icns
# 旧式图稿（256，d=2 处 0.23137）——非系统实际显示轮廓，不采用
NATIVE_GATES=(
  "cornerRadiusMedianROverSide:d[\"cornerRadiusMedianROverSide\"]:0.253:0.273"
  "inset@2:[e for e in d[\"normalizedCornerInsetProfile\"] if e[\"d\"]==2][0][\"insetOverSide\"]:0.2424:0.2624"
  "inset@8:[e for e in d[\"normalizedCornerInsetProfile\"] if e[\"d\"]==8][0][\"insetOverSide\"]:0.189:0.209"
  "inset@32:[e for e in d[\"normalizedCornerInsetProfile\"] if e[\"d\"]==32][0][\"insetOverSide\"]:0.1126:0.1326"
)
if [ -f "$MASK" ]; then
  if measure "$MASK"; then
    SIDE="$(jget "$TMP/m.json" 'd["visibleSide"]')"
    BX="$(jget "$TMP/m.json" 'd["bbox"]["x"]')"; BY="$(jget "$TMP/m.json" 'd["bbox"]["y"]')"
    DX="$(jget "$TMP/m.json" 'abs(d["centerOffsetPx"]["dx"])')"; DY="$(jget "$TMP/m.json" 'abs(d["centerOffsetPx"]["dy"])')"
    if [ "$SIDE" -ge 820 ] && [ "$SIDE" -le 828 ] && [ "$BX" -ge 98 ] && [ "$BX" -le 102 ] && \
       [ "$BY" -ge 98 ] && [ "$BY" -le 102 ] && [ "$DX" -le 2 ] && [ "$DY" -le 2 ]; then
      ok "掩膜轮廓 ${SIDE}px @(${BX},${BY}) 居中（824 参考锚点）"
      MASK_OK=1
    else
      bad "掩膜轮廓异常：side=${SIDE} bbox=(${BX},${BY}) center=(${DX},${DY})"
      MASK_OK=0
    fi
    # 角部形状门：掩膜必须与本机原生瓦片（Apple Music 显示轮廓）一致，逐项定量
    for GATE in "${NATIVE_GATES[@]}"; do
      IFS=':' read -r GNAME GEXPR GLO GHI <<< "$GATE"
      GVAL="$(jget "$TMP/m.json" "$GEXPR")"
      GOK="$(python3 -c "print(1 if ${GLO} <= ${GVAL} <= ${GHI} else 0)")"
      if [ "$GOK" = "1" ]; then
        ok "掩膜角部 ${GNAME}=${GVAL} ∈ [${GLO}, ${GHI}]（原生瓦片形状门）"
      else
        bad "掩膜角部 ${GNAME}=${GVAL} ∉ [${GLO}, ${GHI}]——掩膜圆角与本机 Apple Music 原生显示轮廓不一致（原生显示瓦片的 r/side 中位为 0.263 连续曲率）"
      fi
    done
  else
    bad "掩膜无法测量（$(tail -1 "$TMP/m.err" 2>/dev/null || true)）"; MASK_OK=0
  fi
else
  bad "参考掩膜缺失：$MASK"; MASK_OK=0
fi

echo "▶ T1+T2 四张图稿：可见底板 824±4 与掩膜对齐；alpha 不越掩膜、实心区铺满、IoU≥0.995"
for M in app-icon-day.png app-icon-night.png app-icon-mono-day.png app-icon-mono-night.png; do
  if [ "$MASK_OK" != "1" ]; then bad "$M 跳过（掩膜未就位）"; continue; fi
  if ! measure "$ICON_SRC/$M"; then bad "$M 无法测量"; continue; fi
  SIDE="$(jget "$TMP/m.json" 'd["visibleSide"]')"
  DX="$(jget "$TMP/m.json" 'abs(d["centerOffsetPx"]["dx"])')"; DY="$(jget "$TMP/m.json" 'abs(d["centerOffsetPx"]["dy"])')"
  if [ "$SIDE" -ge 820 ] && [ "$SIDE" -le 828 ] && [ "$DX" -le 2 ] && [ "$DY" -le 2 ]; then
    ok "$M 可见底板 ${SIDE}px 居中（偏移 ≤${DX},${DY}）"
  else
    bad "$M 可见底板不合格：side=${SIDE} 中心偏移=(${DX},${DY})（要求 824±4 居中 ≤2px——当前原稿约 910 且偏心，即返修对象）"
  fi
  if swift "$GEO" mask-diff "$ICON_SRC/$M" "$MASK" > "$TMP/md.json" 2>"$TMP/md.err"; then
    EXCESS="$(jget "$TMP/md.json" 'd["maxAlphaExcess"]')"
    UNCOV="$(jget "$TMP/md.json" 'd["uncoveredInMaskFraction"]')"
    UNCOVOK="$(python3 -c "print(1 if ${UNCOV} == 0 else 0)")"
    IOU="$(jget "$TMP/md.json" 'd["contourIoU"]')"
    if [ "$EXCESS" -le 2 ]; then
      ok "$M alpha 未越掩膜（最大超出 ${EXCESS}）"
    else
      bad "$M alpha 超出掩膜 ${EXCESS}——比参考轮廓更大的底板/边缘杂散就是 Stage Manager 白圈来源"
    fi
    if [ "$UNCOVOK" = "1" ]; then
      ok "$M 掩膜实心区底板铺满"
    else
      bad "$M 掩膜实心区未铺满比例 ${UNCOV}——角部/边缘缺底板色会透出系统垫板"
    fi
    IOUOK="$(python3 -c "print(1 if $IOU >= 0.995 else 0)")"
    if [ "$IOUOK" = "1" ]; then
      ok "$M 轮廓 IoU ${IOU}（边缘弧度与参考一致）"
    else
      bad "$M 轮廓 IoU ${IOU} < 0.995——边缘弧度与参考掩膜不一致"
    fi
  else
    bad "$M 掩膜比对失败（$(tail -1 "$TMP/md.err" 2>/dev/null || true)）"
  fi
done

echo "▶ T3 normalize 可重复：从原稿再生四稿逐字节一致"
if [ -f "$CAL" ]; then
  REGEN_OK=1
  for M in app-icon-day.png app-icon-night.png app-icon-mono-day.png app-icon-mono-night.png; do
    if [ ! -f "$ORIG/$M" ]; then bad "原稿缺失：$ORIG/$M"; REGEN_OK=0; continue; fi
  done
  if [ "$REGEN_OK" = "1" ]; then
    if swift "$CAL" normalize --out "$TMP/regen" >"$TMP/cal.log" 2>&1; then
      for M in app-icon-day.png app-icon-night.png app-icon-mono-day.png app-icon-mono-night.png; do
        if cmp -s "$TMP/regen/$M" "$ICON_SRC/$M"; then
          ok "$M 再生逐字节一致"
        else
          bad "$M 再生与仓库图稿不一致——仓库图稿不是由脚本从原稿规范生成（漂移风险）"
        fi
      done
    else
      bad "normalize 运行失败（$(tail -1 "$TMP/cal.log" 2>/dev/null || true)）"
    fi
  fi
else
  bad "calibrate-icon.swift 缺失：${CAL}——图稿规范/全幅派生没有可重复脚本"
fi

echo "▶ T4 full-bleed：日/夜间 Icon Composer 输入全幅不透明、四角为底板色"
if [ -f "$CAL" ]; then
  if swift "$CAL" full-bleed --out "$TMP/fb" >"$TMP/fb.log" 2>&1; then
    for M in icon-day.png icon-night.png; do
      F="$TMP/fb/$M"
      if [ ! -s "$F" ]; then bad "full-bleed 输出缺失：$M"; continue; fi
      if ! measure "$F"; then bad "$M 无法测量"; continue; fi
      OP="$(jget "$TMP/m.json" 'd["opaqueFraction"]')"
      BX="$(jget "$TMP/m.json" 'd["bbox"]["x"]')"; BW="$(jget "$TMP/m.json" 'd["bbox"]["w"]')"
      OPOK="$(python3 -c "print(1 if ${OP} >= 0.999999 else 0)")"
      if [ "$OPOK" = "1" ] && [ "$BX" = "0" ] && [ "$BW" = "1024" ]; then
        ok "$M 全幅不透明（opaque=1.0，bbox 全画布）"
      else
        bad "$M 非全幅：opaque=${OP} bbox=(${BX},w=${BW})——带透明边距/圆角的图稿直接编译就是白边输入"
      fi
    done
    # 四角底板色：与图稿边缘色同源（day≈(128,20,30)、night≈(22,21,21)，容差 ±12）
    python3 - "$TMP/fb/icon-day.png" 128 20 30 "$TMP/fb/icon-night.png" 22 21 21 <<'PY' && ok "全幅四角为底板色（day 红 / night 黑）" || bad "全幅四角颜色不是底板色——角部填充错误"
import struct, sys, zlib
def corners(path):
    with open(path, 'rb') as f: data = f.read()
    w = h = 1024
    pos = 8; idat = b''; ihdr = None
    while pos < len(data):
        ln, typ = struct.unpack('>I4s', data[pos:pos+8]); chunk = data[pos+8:pos+8+ln]
        if typ == b'IHDR': ihdr = struct.unpack('>IIBBBBB', chunk)
        elif typ == b'IDAT': idat += chunk
        pos += 12 + ln
    _, _, depth, ctype, _, _, interlace = ihdr
    assert depth == 8 and ctype == 6 and interlace == 0, f"不支持的表情 {path}: depth={depth} ctype={ctype}"
    raw = zlib.decompress(idat); stride = w * 4 + 1; px = []
    prev = bytearray(w * 4)
    for y in range(h):
        ftype = raw[y * stride]; line = bytearray(raw[y * stride + 1:(y + 1) * stride])
        if ftype == 1:
            for i in range(4, len(line)): line[i] = (line[i] + line[i - 4]) & 0xFF
        elif ftype == 2:
            for i in range(len(line)): line[i] = (line[i] + prev[i]) & 0xFF
        elif ftype == 3:
            for i in range(len(line)):
                a = line[i - 4] if i >= 4 else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif ftype == 4:
            for i in range(len(line)):
                a = line[i - 4] if i >= 4 else 0; b = prev[i]; c = prev[i - 4] if i >= 4 else 0
                p = a + b - c; pa = abs(p - a); pb = abs(p - b); pc = abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        prev = line
        if y in (0, h - 1):
            xs = (0, w - 1) if y == 0 else (0, w - 1)
            for x in xs: px.append((line[x * 4], line[x * 4 + 1], line[x * 4 + 2], line[x * 4 + 3]))
    return px
ok = True
for path, r, g, b in ((sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])),
                      (sys.argv[5], int(sys.argv[6]), int(sys.argv[7]), int(sys.argv[8]))):
    for (pr, pg, pb, pa) in corners(path):
        if abs(pr - r) > 12 or abs(pg - g) > 12 or abs(pb - b) > 12 or pa < 255:
            print(f"角部像素不符 {path}: rgba({pr},{pg},{pb},{pa}) vs ({r},{g},{b},255)")
            ok = False
sys.exit(0 if ok else 1)
PY
  else
    bad "full-bleed 运行失败（$(tail -1 "$TMP/fb.log" 2>/dev/null || true)）"
  fi
else
  bad "calibrate-icon.swift 缺失：${CAL}——全幅输入没有生成脚本"
fi

echo
echo "结果：$PASS 通过 / $FAIL 失败"
if [ "$FAIL" -gt 0 ]; then
  printf '失败项：%s\n' "${FAILED[*]}"
  exit 1
fi
echo "✅ 图标几何契约全部符合"
