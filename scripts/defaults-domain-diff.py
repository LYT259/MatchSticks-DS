#!/usr/bin/env python3
"""比较两份 UserDefaults 域导出（plist），只打印变化键名，绝不打印值。

用法：defaults-domain-diff.py BEFORE.plist AFTER.plist [--allow KEY]...
退出码：0 = 无变化，或变化仅限 --allow 列出的键；1 = 存在 --allow 之外的变化（含新增/删除键）；
       2 = 用法或解析错误。
stdout：每个变化键一行，「allowed: KEY」或「changed: KEY」；无变化时不输出。
"""
import argparse
import plistlib
import sys


def load(path):
    try:
        with open(path, "rb") as stream:
            data = plistlib.load(stream)
    except Exception as error:  # 损坏/非 plist 快照：只报异常类型，不回显内容
        print(f"无法解析快照 {path}：{type(error).__name__}", file=sys.stderr)
        sys.exit(2)
    if not isinstance(data, dict):
        print(f"快照根节点不是字典：{path}", file=sys.stderr)
        sys.exit(2)
    return data


def same(left, right):
    # 类型也必须一致：plist 里 bool 与 int 可比较相等，False→0 仍算变化
    return type(left) is type(right) and left == right


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("before", help="改动前的域导出 plist")
    parser.add_argument("after", help="改动后的域导出 plist")
    parser.add_argument("--allow", action="append", default=[], metavar="KEY",
                        help="允许变化的键（可重复）；其余任何变化都判失败")
    args = parser.parse_args()
    before, after = load(args.before), load(args.after)
    allowed = set(args.allow)
    leaked = 0
    for key in sorted(set(before) | set(after)):
        if same(before.get(key), after.get(key)):
            continue
        if key in allowed:
            print(f"allowed: {key}")
        else:
            print(f"changed: {key}")
            leaked += 1
    if leaked:
        print(f"{leaked} 个非允许键发生变化", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
