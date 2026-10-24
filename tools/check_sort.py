# -*- coding: utf-8 -*-
"""校验 data/firmware.json 的排序是否规范（CI 用）

规则：
    组内 builds  按 ts 倒序
    组顺序       普通组按版本升序，内测/变体组排在其后按版本升序

用法：
    python tools/check_sort.py          # 不合规时返回退出码 1
"""
import io
import json
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FW = os.path.join(ROOT, "data", "firmware.json")
SEED = os.path.join(ROOT, "firmware.json")


def ver_key(v):
    return [int(x) if x.isdigit() else 0 for x in re.split(r"[.\-]", str(v))]


def main():
    path = FW if os.path.exists(FW) else SEED
    if not os.path.exists(path):
        print("找不到数据文件：", FW)
        sys.exit(1)

    with io.open(path, encoding="utf-8") as f:
        data = json.load(f)

    phones = data.get("phones", {})
    bad_builds = []
    bad_groups = []
    total_groups = 0
    total_builds = 0

    for pid, m in phones.items():
        gs = m.get("groups", [])
        total_groups += len(gs)
        for g in gs:
            ts = [str(b.get("ts", "")) for b in g["builds"]]
            total_builds += len(ts)
            if ts != sorted(ts, reverse=True):
                bad_builds.append((pid, m.get("name", ""), g.get("ver", ""), ts))

        normal = [g for g in gs if not g.get("isBeta") and not g.get("isVariant")]
        other = [g for g in gs if g.get("isBeta") or g.get("isVariant")]
        if [ver_key(g.get("ver")) for g in normal] != sorted(ver_key(g.get("ver")) for g in normal):
            bad_groups.append((pid, m.get("name", ""), "normal"))
        if [ver_key(g.get("ver")) for g in other] != sorted(ver_key(g.get("ver")) for g in other):
            bad_groups.append((pid, m.get("name", ""), "beta/variant"))

    print("文件: %s" % path)
    print("机型 %d | 组 %d | 构建 %d" % (len(phones), total_groups, total_builds))
    print("组内 builds 非倒序: %d 组" % len(bad_builds))
    print("组顺序不合规: %d 处" % len(bad_groups))

    for pid, name, ver, ts in bad_builds[:10]:
        print("   [ts] %-5s %-14s ver=%-12s %s" % (pid, name, ver, ts[:4]))
    for pid, name, kind in bad_groups[:10]:
        print("   [组] %-5s %-14s %s" % (pid, name, kind))

    if bad_builds or bad_groups:
        print("\n排序不合规：请运行 python tools/update_data.py 自动修复")
        sys.exit(1)

    print("\n排序规范 ✓")


if __name__ == "__main__":
    main()
