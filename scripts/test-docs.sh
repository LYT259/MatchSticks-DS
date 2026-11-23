#!/bin/bash
# scripts/test-docs.sh — 对外文档、隐私与本地协作规则的一致性断言（不启动 App、不访问网络）
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
from pathlib import Path
import re
import subprocess
import sys

failures = []
checks = 0


def require(condition, message):
    global checks
    checks += 1
    if not condition:
        failures.append(message)


def contains(path, text):
    require(text in Path(path).read_text(encoding="utf-8"), f"{path}: 缺少 {text!r}")


def absent(path, text):
    require(text not in Path(path).read_text(encoding="utf-8"), f"{path}: 不应包含 {text!r}")


def without_fences(text):
    lines = []
    fenced = False
    for line in text.splitlines():
        if line.startswith("```"):
            fenced = not fenced
            continue
        if not fenced:
            lines.append(line)
    return "\n".join(lines)


def heading_slugs(text):
    slugs = set()
    for line in text.splitlines():
        match = re.match(r"^#{1,6}\s+(.+?)\s*$", line)
        if match:
            heading = re.sub(r"[^\w\s-]", "", match.group(1).lower(), flags=re.UNICODE)
            slugs.add(re.sub(r"\s+", "-", heading))
    return slugs


readme = "README.md"
release_kit = "docs/release-kit.md"
adr = "docs/decisions/0003-three-platform-validation.md"
public_docs = [readme, release_kit, adr]

for doc in public_docs:
    text = Path(doc).read_text(encoding="utf-8")
    prose = without_fences(text)
    for match in re.finditer(r"\[[^\]]+\]\(([^)\s]+)(?:\s+[^)]*)?\)", prose):
        target = match.group(1)
        if target.startswith(("http://", "https://", "mailto:")):
            continue
        file_part, _, fragment = target.partition("#")
        if file_part:
            resolved = (Path(doc).parent / file_part).resolve()
            require(resolved.exists(), f"{doc}: 本地链接不存在：{target}")
        if fragment:
            anchor_doc = Path(doc) if not file_part else Path(doc).parent / file_part
            if anchor_doc.exists():
                require(fragment in heading_slugs(anchor_doc.read_text(encoding="utf-8")),
                        f"{doc}: 链接锚点不存在：{target}")

contains(readme, "发布线当前 v0.1.0-alpha.7")
absent(readme, "发布线当前 v0.1.0-alpha.6")
contains(readme, "DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer")
absent(readme, "Xcode-beta.app")

for doc in public_docs:
    contains(doc, "自动发现")
    contains(doc, "scripts/test-*.sh")
    contains(doc, "同一 SHA")
    contains(doc, "完整 `DSCoreTests`")
    contains(doc, "所有合入 `beta` 的改动")
    contains(doc, "当前 Latest Release")
    contains(doc, "<sparkle:channel>beta</sparkle:channel>")
    contains(doc, "明确授权")
    contains(doc, "匿名")
    contains(doc, "404")
    contains(doc, "镜像尚未部署")
    contains(doc, "生产自动更新可用性前提")
    contains(doc, "不得宣称现网应用内更新可用")
    contains(doc, "ADR-0004")

contains(readme, "不提供 Windows / Linux 版 App")
contains(release_kit, "不运行 Windows / Linux App")
contains(adr, "不意味着 Windows / Linux 上有可用的 App")
contains(readme, "可移植性 ADR")
contains(adr, "可移植性 ADR")
contains(readme, "[ADR-0004](docs/decisions/0004-update-channels-and-connectivity.md)")
contains(release_kit, "[ADR-0004](decisions/0004-update-channels-and-connectivity.md)")
contains(adr, "[ADR-0004](0004-update-channels-and-connectivity.md)")
contains(readme, "[ADR-0005](docs/decisions/0005-portable-dscore-validation.md)")
contains(adr, "[ADR-0005](0005-portable-dscore-validation.md)")
for doc in public_docs:
    absent(doc, "文件随对应功能分支合入")
    absent(doc, "本页暂不预设链接")
    absent(doc, "编号与文件路径以并行任务最终报告为准")
absent(adr, "暂不设链接")
absent(adr, "由并行任务交付")
contains(adr, "`git archive HEAD`")
contains(adr, "`mktemp -d`")
contains(adr, "读取 `headSha`")
contains(adr, "至多 dispatch 一次")
absent(adr, "`rsync` 同一 SHA")
absent(adr, "`gh workflow run")
contains(adr, "不声称三平台验证已经通过")

for doc in public_docs:
    text = Path(doc).read_text(encoding="utf-8")
    for label, pattern in [
        ("个人绝对路径", r"/Users/|/home/"),
        ("SSH 主机别名", r"dkc-home"),
        ("个人邮箱", r"[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}"),
    ]:
        require(not re.search(pattern, text), f"{doc}: 公开文档包含{label}")

rule_files = [name for name in ["AGENTS.md", "CLAUDE.md"] if Path(name).exists()]
if rule_files:
    require(len(rule_files) == 2, "AGENTS.md 与 CLAUDE.md 必须同时存在或同时缺失")
    for rule_file in rule_files:
        contains(rule_file, "自动发现")
        contains(rule_file, "scripts/test-*.sh")
        contains(rule_file, "同一 SHA")
        contains(rule_file, "完整 `DSCoreTests`")
        contains(rule_file, "匿名")
        contains(rule_file, "404")
        contains(rule_file, "镜像尚未部署")
        contains(rule_file, "生产自动更新可用性前提")
        tracked = subprocess.run(
            ["git", "ls-files", "--", rule_file], check=False, capture_output=True, text=True
        )
        require(not tracked.stdout.strip(), f"{rule_file}: 私有协作规则不得进入提交")
        ignored = subprocess.run(
            ["git", "check-ignore", "-q", rule_file], check=False
        )
        require(ignored.returncode == 0, f"{rule_file}: 必须被 .gitignore 忽略")

    identical = subprocess.run(["cmp", "-s", "AGENTS.md", "CLAUDE.md"], check=False)
    require(identical.returncode == 0, "AGENTS.md 与 CLAUDE.md 必须字节一致")
else:
    print("提示：干净 clone 无私有 AGENTS.md / CLAUDE.md，跳过本地规则一致性断言")

if failures:
    for failure in failures:
        print(f"  ✗ {failure}", file=sys.stderr)
    print(f"文档一致性：{len(failures)} 项失败（共 {checks} 项断言）", file=sys.stderr)
    sys.exit(1)
print(f"文档一致性：{checks} 项断言通过")
PY
