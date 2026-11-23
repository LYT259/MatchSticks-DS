#!/bin/bash
# MatchSticks DS 终端一行安装（报告 §5.5 方案 A 并行渠道：curl 下载无隔离属性 → 零 Gatekeeper 弹窗）
#
# 用法（发版后）：
#   curl -fsSL https://raw.githubusercontent.com/LYT259/MatchSticks-DS/<ref>/scripts/install.sh | bash
#     无参数：安装 /releases/latest 指向的稳定版，不读取 /releases 列表。
#   或显式指定版本/tag（含 beta / pre-release）： ... | bash -s -- v0.1.0-alpha.7
#     beta / pre-release 仅可通过显式 tag 选择；latest 请求失败不会回退。
#
# 校验：SHA256 与 Releases 的 SHA256SUMS 逐字节核对后才安装。
set -euo pipefail

REPO="LYT259/MatchSticks-DS"
VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    VERSION="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
fi
[ -n "$VERSION" ] || { echo "✗ 无法确定最新稳定版本（可手动指定：install.sh v0.1.0-xxx）" >&2; exit 1; }
BASE="https://github.com/${REPO}/releases/download/${VERSION}"
DMG="MatchSticks-DS-${VERSION#v}.dmg"

echo "▶ 下载 ${DMG}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fL --retry 2 -o "$TMP/$DMG" "$BASE/$DMG"

echo "▶ SHA256 校验"
EXPECT="$(curl -fL --retry 2 "$BASE/SHA256SUMS" | awk -v f="$DMG" '$2 == f {print $1}')"
[ -n "$EXPECT" ] || { echo "✗ SHA256SUMS 中找不到 ${DMG}" >&2; exit 1; }
GOT="$(shasum -a 256 "$TMP/$DMG" | awk '{print $1}')"
[ "$GOT" = "$EXPECT" ] || { echo "✗ 校验失败（期望 $EXPECT，得到 $GOT）" >&2; exit 1; }

echo "▶ 安装到 /Applications"
hdiutil attach -quiet -nobrowse -readonly "$TMP/$DMG" -mountpoint "$TMP/mnt"
rsync -a "$TMP/mnt/MatchSticks DS.app" /Applications/ 2>/dev/null \
    || cp -R "$TMP/mnt/MatchSticks DS.app" /Applications/
hdiutil detach -quiet "$TMP/mnt"

echo "✅ 安装完成：/Applications/MatchSticks DS.app（${VERSION#v}）"
echo "   首次连接机器人时，macOS 会弹一次「本地网络」应用内授权——点「允许」即可。"
