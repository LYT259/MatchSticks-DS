#!/bin/bash
# scripts/test-icon-gate.sh — 打包图标链两道门的独立行为测试（不跑完整 build-app.sh、不触 dist）
# G1 资源门：build-app.sh 的图标原稿检查循环必须覆盖四张白名单 PNG
#    （day/night/mono-day/mono-night）；任一缺失或损坏（含非图片内容）都必须非零失败。
# G2 assetutil 硬门：编译出的 Assets.car 浅色 Aqua 可见层必须是 AppIcon_Assets/icon-day、
#    深色 DarkAqua 可见层必须是 AppIcon_Assets/icon-night——日夜倒置必须拒绝（仅比较
#    digest 差异的旧门会假绿），同时保留 digest 不同与双 1024 像素载荷断言。
# 两道门都从 scripts/build-app.sh 现场抽取对应段落执行，防止实现与测试漂移。
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BUILD_SH="$ROOT/scripts/build-app.sh"
ICON_SRC="$ROOT/Sources/MatchSticksDriverStaion/Resources/AppIcons"
MASTERS=(app-icon-day.png app-icon-night.png app-icon-mono-day.png app-icon-mono-night.png)

for M in "${MASTERS[@]}"; do
  [ -f "$ICON_SRC/$M" ] || { echo "test-icon-gate.sh: 母版缺失：$ICON_SRC/$M" >&2; exit 1; }
done

if [ -z "${DEVELOPER_DIR:-}" ]; then
  for CAND in /Applications/Xcode-beta.app /Applications/Xcode.app; do
    [ -d "$CAND" ] && DEVELOPER_DIR="$CAND/Contents/Developer" && break
  done
fi
export DEVELOPER_DIR
ACTOOL="$(xcrun --find actool 2>/dev/null)" || ACTOOL=""
[ -n "$ACTOOL" ] || { echo "test-icon-gate.sh: 找不到 actool（需要完整 Xcode）" >&2; exit 1; }

TMP="$ROOT/.build/icon-test/gate-scratch.$$"
rm -rf "$TMP"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0; FAILED=()
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); FAILED+=("$1"); }

# ── 从 build-app.sh 抽取被测段落 ──
RS=$(grep -n '^for ICON_SRC in' "$BUILD_SH" | head -1 | cut -d: -f1)
RE=$(awk -v s="$RS" 'NR>s && /^done$/ {print NR; exit}' "$BUILD_SH")
GS=$(grep -n '硬检查：深色变体必须' "$BUILD_SH" | head -1 | cut -d: -f1)
GE=$(grep -n '^cp "\$ICON_WORK/actool-out/Assets.car"' "$BUILD_SH" | head -1 | cut -d: -f1)
FS=$( { grep -n 'FULLBLEED-SEGMENT-START' "$BUILD_SH" || true; } | head -1 | cut -d: -f1)
FE=$( { grep -n '^cat "\$ICON_WORK/fullbleed/icon-night.png"' "$BUILD_SH" || true; } | head -1 | cut -d: -f1)
if [ -z "${RS:-}" ] || [ -z "${RE:-}" ] || [ -z "${GS:-}" ] || [ -z "${GE:-}" ] || \
   [ "$RS" -ge "$RE" ] || [ "$GS" -ge "$GE" ]; then
  echo "test-icon-gate.sh: 无法在 $BUILD_SH 定位资源循环（${RS}-${RE}）或硬门段落（${GS}-${GE}）" >&2
  exit 1
fi
sed -n "${RS},${RE}p" "$BUILD_SH" > "$TMP/resource-loop.sh"
sed -n "${GS},${GE}p" "$BUILD_SH" > "$TMP/gate-snippet.sh"
awk "/<<'ICONJSON'/{flag=1;next} /^ICONJSON\$/{flag=0} flag" "$BUILD_SH" > "$TMP/icon-pos.json"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$TMP/icon-pos.json" \
  || { echo "test-icon-gate.sh: 抽取的 icon.json 不是合法 JSON" >&2; exit 1; }
ok "从 build-app.sh 抽取资源循环（行 ${RS}-${RE}）、硬门（行 ${GS}-${GE}）与 icon.json"

# 守卫：build-app.sh 的 ICON_WORK 必须是基于 $PWD 的绝对路径——actool 经 XPC 守护进程执行，
# 相对 --compile 路径按守护进程自身 cwd（可能是别的 worktree）解析，会把产物写进别处、
# 本地零 Assets.car；回归成相对路径时在此拦截
if grep -q '^ICON_WORK="\$PWD/' "$BUILD_SH"; then
  ok "ICON_WORK 为 \$PWD 绝对路径（actool 守护进程 cwd 免疫）"
else
  bad "ICON_WORK 不是 \$PWD 绝对路径——actool 会把 Assets.car 写进别的 worktree"
fi

# ── 通用：编译 .icon 包为 Assets.car ──
# PNG 用 cat 重定向新写（不用 cp）：用户原稿带下载隔离属性，cp 的 clonefile 拷贝
# 会让本机 actool 的 IconStudio 导出间歇性报「image does not exist」（实测 3/3 复现；
# cat 新写 3/3 成功）——测试与生产（build-app.sh）必须同用新写方式
compile_car() { # <name> <icon.json>
  local name="$1" d="$TMP/$1"
  mkdir -p "$d/pkg/AppIcon.icon/Assets" "$d/actool-out"
  cp "$2" "$d/pkg/AppIcon.icon/icon.json"
  cat "$ICON_SRC/app-icon-day.png"   > "$d/pkg/AppIcon.icon/Assets/icon-day.png"
  cat "$ICON_SRC/app-icon-night.png" > "$d/pkg/AppIcon.icon/Assets/icon-night.png"
  if ! "$ACTOOL" "$d/pkg/AppIcon.icon" --app-icon AppIcon \
      --compile "$d/actool-out" --output-partial-info-plist "$d/actool-out/partial.plist" \
      --minimum-deployment-target 14.0 --platform macosx --target-device mac \
      >"$d/actool.log" 2>&1 || [ ! -s "$d/actool-out/Assets.car" ]; then
    echo "test-icon-gate.sh: actool 编译 $name 失败（$d/actool.log）" >&2
    tail -20 "$d/actool.log" >&2
    return 1
  fi
}

# 独立读 car 组成（与被测门实现无关，用于校验夹具本身）
cat > "$TMP/inspect.py" <<'PY'
import json, os, subprocess, sys
if not os.path.exists(sys.argv[1]):
    print(f"MISSING\tMISSING\t0"); sys.exit(0)
d = json.loads(subprocess.run(["/usr/bin/assetutil", "--info", sys.argv[1]],
                              capture_output=True, text=True).stdout)
images = set(); aqua = dark = None
for e in d:
    if e.get("AssetType") == "Image" and e.get("PixelWidth") == 1024:
        images.add(e.get("SHA1Digest"))
    if e.get("AssetType") == "IconGroup":
        vis = [l for l in (e.get("Layers") or [])
               if l.get("AssetType") in (None, "Image") and l.get("LayerOpacity", 1) >= 1]
        if vis:
            if e.get("Appearance") == "NSAppearanceNameAqua": aqua = vis[0].get("Name")
            if e.get("Appearance") == "NSAppearanceNameDarkAqua": dark = vis[0].get("Name")
print(f"{aqua}\t{dark}\t{len(images)}")
PY

run_gate() { # <car-dir> <app-dir>：执行抽取的硬门段落，返回其退出码
  ( set -euo pipefail
    ICON_WORK="$1" APP="$2" source "$TMP/gate-snippet.sh" ) >/dev/null 2>"$TMP/gate.err"
}

run_loop() { # <icons-dir>：执行抽取的资源检查循环，返回其退出码
  ( set -euo pipefail
    ICON_SRC_DIR="$1" source "$TMP/resource-loop.sh" ) >/dev/null 2>"$TMP/loop.err"
}

# ════ G1 资源门 ════
echo "▶ G1 资源门：四稿齐全放行；任一缺失/损坏必须拦截"
SC="$TMP/icons"
mk_icons() { rm -rf "$SC"; mkdir -p "$SC"; for M in "${MASTERS[@]}"; do cp "$ICON_SRC/$M" "$SC/"; done; }

mk_icons
if run_loop "$SC"; then ok "四稿齐全：放行"; else bad "四稿齐全竟被拒（$(tail -1 "$TMP/loop.err")）"; fi

mk_icons; rm "$SC/app-icon-mono-night.png"
if run_loop "$SC"; then bad "缺 mono-night 竟放行——白名单未覆盖全部四稿"; else ok "缺 mono-night：拦截"; fi

mk_icons; printf 'DEFINITELY NOT A PNG\n' > "$SC/app-icon-mono-day.png"
if run_loop "$SC"; then bad "mono-day 损坏（非图片内容）竟放行"; else ok "mono-day 损坏（非图片内容）：拦截"; fi

mk_icons; rm "$SC/app-icon-day.png"
if run_loop "$SC"; then bad "缺 day 竟放行（回归）"; else ok "缺 day：拦截"; fi

mk_icons; printf 'NOT A PNG EITHER\n' > "$SC/app-icon-night.png"
if run_loop "$SC"; then bad "night 损坏竟放行"; else ok "night 损坏：拦截"; fi

mk_icons; sips -z 512 512 "$ICON_SRC/app-icon-mono-night.png" --out "$SC/app-icon-mono-night.png" >/dev/null 2>&1
if run_loop "$SC"; then bad "mono-night 非 1024×1024 竟放行"; else ok "mono-night 非 1024×1024：拦截"; fi

# ════ G2 assetutil 硬门 ════
echo "▶ G2 assetutil 硬门：浅=day / 深=night 定向断言（倒置必须拒绝）"
# 倒置夹具：交换两层 hidden-specializations 的 appearance（Aqua 显示 night、DarkAqua 显示 day）
python3 - "$TMP/icon-pos.json" "$TMP/icon-invert.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for layer in d["groups"][0]["layers"]:
    for s in layer.get("hidden-specializations", []):
        s["appearance"] = "light" if s["appearance"] == "dark" else "dark"
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY
# 纯日间夹具：只留 day 层且去掉 specializations（对应 image-name-specializations 被丢弃的坏 car）
python3 - "$TMP/icon-pos.json" "$TMP/icon-broken.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
g = d["groups"][0]
g["layers"] = [l for l in g["layers"] if l["image-name"] == "icon-day.png"]
g["layers"][0].pop("hidden-specializations", None)
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY

for NAME in pos invert broken; do
  if ! compile_car "$NAME" "$TMP/icon-$NAME.json"; then
    bad "夹具编译失败：$NAME"
  fi
done

IFS=$'\t' read -r A D P < <(python3 "$TMP/inspect.py" "$TMP/pos/actool-out/Assets.car")
if [ "$A" = "AppIcon_Assets/icon-day" ] && [ "$D" = "AppIcon_Assets/icon-night" ] && [ "$P" -ge 2 ]; then
  ok "正例夹具就位（Aqua=${A} Dark=${D} 载荷=${P}）"
else
  bad "正例夹具异常（Aqua=${A} Dark=${D} 载荷=${P}）"
fi
IFS=$'\t' read -r A D P < <(python3 "$TMP/inspect.py" "$TMP/invert/actool-out/Assets.car")
if [ "$A" = "AppIcon_Assets/icon-night" ] && [ "$D" = "AppIcon_Assets/icon-day" ] && [ "$P" -ge 2 ]; then
  ok "倒置夹具就位（Aqua=${A} Dark=${D} 载荷=${P}）"
else
  bad "倒置夹具异常（Aqua=${A} Dark=${D} 载荷=${P}）"
fi
IFS=$'\t' read -r A D P < <(python3 "$TMP/inspect.py" "$TMP/broken/actool-out/Assets.car")
if [ "$P" -eq 1 ] && [ "$A" = "$D" ]; then
  ok "纯日间夹具就位（Aqua=Dark=${A} 载荷=${P}）"
else
  bad "纯日间夹具异常（Aqua=${A} Dark=${D} 载荷=${P}）"
fi

for NAME in pos invert broken; do
  mkdir -p "$TMP/app-$NAME/Contents/Resources"
  CODE=0
  run_gate "$TMP/$NAME" "$TMP/app-$NAME" || CODE=$?
  case "$NAME" in
    pos)     [ "$CODE" -eq 0 ] && ok "正例：门放行（exit=0）" || bad "正例竟被拒（exit=${CODE}：$(tail -1 "$TMP/gate.err" 2>/dev/null || true)）" ;;
    invert)  [ "$CODE" -ne 0 ] && ok "倒置：门拒绝（exit=${CODE}）" || bad "倒置竟放行（exit=0）——门未做 day/night 定向断言，日夜颠倒会假绿" ;;
    broken)  [ "$CODE" -ne 0 ] && ok "纯日间：门拒绝（exit=${CODE}）" || bad "纯日间竟放行（exit=0）" ;;
  esac
done

# ════ G3 Icon Composer 全幅输入门 ════
echo "▶ G3 全幅输入门：actool 图稿必须由全幅派生段生成（全幅不透明、无透明边距）"
# build-app.sh 的 FULLBLEED 段负责把仓库圆角图稿派生成全幅日/夜间输入并喂给 actool——
# 带透明边距/圆角的图稿直接编译，系统底板会从透明区透出，即 Stage Manager/侧边白圈
if [ -z "${FS:-}" ] || [ -z "${FE:-}" ] || [ "$FS" -ge "$FE" ]; then
  bad "build-app.sh 缺少全幅输入段（FULLBLEED-START..cat fullbleed/icon-night.png）——圆角图稿被直接喂给 Icon Composer（白边输入）"
else
  ok "定位全幅输入段（行 ${FS}-${FE}）"
  sed -n "${FS},${FE}p" "$BUILD_SH" > "$TMP/fullbleed-snippet.sh"
  FB="$TMP/fb-run"
  mkdir -p "$FB/pkg/Assets" "$FB/fullbleed"
  CODE=0
  ( set -euo pipefail
    ICON_WORK="$FB" ICON_PKG="$FB/pkg" ICON_SRC_DIR="$ICON_SRC" source "$TMP/fullbleed-snippet.sh" ) \
    >"$TMP/fb.out" 2>"$TMP/fb.err" || CODE=$?
  if [ "$CODE" -eq 0 ]; then
    ok "全幅输入段独立运行成功"
  else
    bad "全幅输入段运行失败（exit=${CODE}：$(tail -1 "$TMP/fb.err" 2>/dev/null || true)）"
  fi
  GEO_SH="$ROOT/scripts/icon-geometry.swift"
  for FBPNG in icon-day.png icon-night.png; do
    TARGET="$FB/pkg/Assets/$FBPNG"
    if [ ! -s "$TARGET" ]; then bad "actool 输入未由全幅段产出：缺 $TARGET"; continue; fi
    if swift "$GEO_SH" measure "$TARGET" >"$TMP/fbm.json" 2>/dev/null; then
      OP="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["opaqueFraction"])' "$TMP/fbm.json")"
      BW="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["bbox"]["w"])' "$TMP/fbm.json")"
      OPOK="$(python3 -c "print(1 if ${OP} >= 0.999999 else 0)")"
      if [ "$OPOK" = "1" ] && [ "$BW" = "1024" ]; then
        ok "$FBPNG 为全幅输入（opaque=1.0，宽 1024）"
      else
        bad "$FBPNG 非全幅（opaque=${OP} bbox 宽=${BW}）——带透明边距的 actool 输入就是白边"
      fi
    else
      bad "$FBPNG 无法测量"
    fi
    REF_FB="$TMP/fb-direct"
    mkdir -p "$REF_FB"
    swift "$ROOT/scripts/calibrate-icon.swift" full-bleed --out "$REF_FB" >/dev/null 2>&1
    if cmp -s "$TARGET" "$REF_FB/$FBPNG"; then
      ok "$FBPNG 与 full-bleed 脚本直出逐字节一致（actool 真正消费全幅派生结果）"
    else
      bad "$FBPNG 与 full-bleed 脚本直出不一致——actool 输入绕过了全幅派生"
    fi
  done
fi

echo
echo "结果：$PASS 通过 / $FAIL 失败"
if [ "$FAIL" -gt 0 ]; then
  printf '失败项：%s\n' "${FAILED[*]}"
  exit 1
fi
echo "✅ 图标链两道门全部符合契约"
