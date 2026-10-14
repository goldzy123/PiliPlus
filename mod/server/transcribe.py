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
import subprocess
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

    # 管线里 ASR 吃的是 16k 单声道 wav（它们平时也是先 ffmpeg 转一道）。
    # 直接从 yt-dlp 拿到的 m4a 也别指望 FunASR 自己能读，统一转一次。
    src = Path(args.audio)
    wav = src.with_suffix(".16k.wav")
    if not wav.exists():
        subprocess.run(
            ["ffmpeg", "-y", "-loglevel", "error", "-i", str(src),
             "-ac", "1", "-ar", "16000", str(wav)],
            check=True,
        )

    # transcribe(wav_path, device_pref, fast, spk_num) -> {"text", "segments", "centers"}
    # 热词由 config 里的 use_seaco_hotword 控制，不用在这里传。
    res = asr_diar.transcribe(str(wav), fast=fast)
    if not isinstance(res, dict):
        print(str(res))
        return 0
    segs = res.get("segments") or []
    lines = [str(s.get("text", "")).strip() for s in segs if s.get("text")]
    out = "\n".join(t for t in lines if t)
    print(out if out else str(res.get("text", "")).strip())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
