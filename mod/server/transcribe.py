#!/usr/bin/env python
"""给 piliplus-summary-server.mjs 用的转写脚本：音频文件 → 纯文本。

刻意**复用** 语言日程 项目里已经调好的 ASR 管线（src/asr_diar.py：FunASR
Paraformer/SenseVoice + FSMN-VAD + CT-Punc），不重复造轮子 —— 那边的设备选择
（Apple GPU/MPS、失败回退 CPU）、VAD 分段上限、热词、标点模型都是踩过坑调出来的。

默认走 --fast（SenseVoiceSmall，CPU，约 45x 实时）：给视频做总结不需要说话人分离，
要的是快。

用法：
    .venv/bin/python transcribe.py <audio> [--fast|--accurate] [--hotwords 词表]

输出：转写文本到 stdout（日志走 stderr，不污染结果）。
"""
import argparse
import logging
import os
import sys
from pathlib import Path

# 语言日程 项目的 src 目录
LANG_SCHEDULE = Path(os.environ.get(
    "LANG_SCHEDULE_DIR",
    Path.home() / "nana/ai/dsh/语言日程",
))
sys.path.insert(0, str(LANG_SCHEDULE / "src"))
os.chdir(LANG_SCHEDULE)  # asr_diar 里用的是相对路径（config/config.yaml、models/…）


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("audio")
    ap.add_argument("--accurate", action="store_true", help="用 Paraformer 高精度（慢）")
    ap.add_argument("--hotwords", default=str(LANG_SCHEDULE / "hotwords.txt"))
    args = ap.parse_args()

    logging.basicConfig(level=logging.WARNING, stream=sys.stderr)
    import asr_diar

    fast = not args.accurate
    asr_diar.load_pipeline(device_pref="auto", fast=fast)
    hotwords = None
    if args.hotwords and Path(args.hotwords).exists():
        try:
            hotwords = asr_diar.load_hotwords(args.hotwords)
        except Exception as e:  # 热词只是加成，坏了不影响主流程
            print(f"hotwords 载入失败，忽略：{e}", file=sys.stderr)

    segments = asr_diar.transcribe(args.audio, fast=fast, hotwords=hotwords)
    # transcribe 返回 [(spk, start, end, text), ...] 这类结构，尽量兼容
    lines = []
    for seg in segments or []:
        if isinstance(seg, str):
            lines.append(seg)
        elif isinstance(seg, (list, tuple)) and seg:
            text = seg[-1]
            if text and str(text).strip():
                lines.append(str(text).strip())
        elif isinstance(seg, dict):
            t = seg.get("text") or seg.get("content")
            if t:
                lines.append(str(t).strip())
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
