#!/usr/bin/env python3
"""给已有的同步配置档补上「类型清单」。

背景
----
同步服务端是 Node（JS），而 JS 只有一种 number，没有 int/double 之分。
客户端传 `textScale: 1.0`，过一遍 `JSON.parse → JSON.stringify` 就变成 `1`；
Dart 那边是有 int/double 之分的，`double get defaultTextScale` 读到 int 直接抛
`type 'int' is not a subtype of type 'double'`，MaterialApp 构建失败 → 整屏变灰。

服务端已经改成把数据当**字符串**原样存取（不再解析），新上传的配置档会自带
`types` 清单，不会再出问题。但**在此之前**创建的配置档里，double 已经被降级成
int，而且没有类型清单，客户端只能保守跳过。

这个脚本就是一次性迁移：从 `lib/utils/storage_pref.dart` 里把「哪些键声明为
double」自动提取出来，写进老配置档的 `types` 清单，并 bump 一次 rev 让各设备重新拉取。

用法
----
    python3 mod/tools/fix_profile_types.py --dry-run     # 先看要改什么
    python3 mod/tools/fix_profile_types.py               # 真改
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DATA_DIR = Path(os.environ.get("DATA_DIR", Path.home() / ".piliplus-settings"))


def actual_keys() -> dict[str, str]:
    """SettingBoxKey.<名字> = '<真实键名>'"""
    src = (REPO / "lib/utils/storage_key.dart").read_text(encoding="utf-8")
    out = {}
    for m in re.finditer(r"(\w+)\s*=\s*'([^']+)'", src):
        out[m.group(1)] = m.group(2)
    return out


def double_keys() -> set[str]:
    """storage_pref.dart 里所有 `static double get X` 读的那个键（真实键名）。

    这是「app 期望这个设置是 double」的唯一权威来源 —— 所以从代码里抠，
    不要手写清单（手写的会随着官方升级漂移）。
    """
    src = (REPO / "lib/utils/storage_pref.dart").read_text(encoding="utf-8")
    keys = actual_keys()
    found: set[str] = set()
    # 每个 `static double get ...` 到下一个 `static ` 之间，找 SettingBoxKey.X
    for m in re.finditer(r"static double get (\w+)(.*?)(?=\n  static |\n  @|\Z)",
                         src, re.S):
        body = m.group(2)
        for ref in re.finditer(r"SettingBoxKey\.(\w+)", body):
            name = ref.group(1)
            if name in keys:
                found.add(keys[name])
            else:
                print(f"  ! 无法解析 SettingBoxKey.{name}", file=sys.stderr)
    return found


def migrate(dry: bool) -> int:
    doubles = double_keys()
    print(f"从 storage_pref.dart 提取到 {len(doubles)} 个 double 类型的键：")
    print("   " + ", ".join(sorted(doubles)))
    print()

    if not DATA_DIR.is_dir():
        print(f"数据目录不存在：{DATA_DIR}")
        return 1

    changed = 0
    for path in sorted(DATA_DIR.glob("*.json")):
        try:
            prof = json.loads(path.read_text(encoding="utf-8"))
        except Exception as exc:
            print(f"跳过 {path.name}：{exc}")
            continue

        # 数据本体：优先 dataRaw（字符串，类型无损），否则退回 data 对象
        raw = prof.get("dataRaw")
        if not isinstance(raw, str):
            raw = json.dumps(prof.get("data") or {}, ensure_ascii=False)
        try:
            data = json.loads(raw)
        except Exception as exc:
            print(f"跳过 {path.name}：dataRaw 不是合法 JSON（{exc}）")
            continue

        boxes = data.get("boxes") or {}
        types = data.setdefault("types", {})
        added = []
        for box_name, items in boxes.items():
            if not isinstance(items, dict):
                continue
            box_types = types.setdefault(box_name, {})
            for key in items:
                # 只补 double —— int/bool/String 在 JSON 里本来就不会走样，
                # 出问题的只有「double 被降级成 int」这一种。
                if key in doubles and box_types.get(key) != "double":
                    box_types[key] = "double"
                    added.append(f"{box_name}.{key}")
            if not box_types:
                types.pop(box_name, None)

        if not added:
            print(f"{path.name}: 无需改动")
            continue

        print(f"{path.name}: 补 {len(added)} 项 → {', '.join(added)}")
        if dry:
            changed += 1
            continue

        shutil.copy2(path, path.with_suffix(".json.bak"))
        prof["dataRaw"] = json.dumps(data, ensure_ascii=False)
        prof["data"] = data
        # bump rev，让各设备知道"远端变了"从而重新拉取
        prof["rev"] = int(prof.get("rev") or 0) + 1
        prof["updatedAt"] = int(prof.get("updatedAt") or 0)
        prof["migratedTypesAt"] = True
        path.write_text(json.dumps(prof, ensure_ascii=False, indent=2), encoding="utf-8")
        changed += 1

    print()
    print(("会修改" if dry else "已修改") + f" {changed} 个配置档"
          + ("（--dry-run，未落盘）" if dry else "（原文件已备份为 .json.bak）"))
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="给旧同步配置档补类型清单")
    ap.add_argument("--dry-run", action="store_true", help="只显示将要做的改动")
    args = ap.parse_args()
    return migrate(args.dry_run)


if __name__ == "__main__":
    raise SystemExit(main())
