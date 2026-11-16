"""把 livecaption 的识别 + 翻译流水线接成事件流（每行一个 JSON，写到 stdout）。

由 copilot.py 以子进程方式启动，用引擎自己的虚拟环境运行：
    engine/livecaption/.venv/bin/python engine_driver.py --source system|mic|both|file [--file x.wav]
只调用 livecaption 的公开模块，不修改其源码。收到 SIGTERM / SIGINT 后收尾退出。

事件：
  {"ev":"status","msg":...}                         加载进度
  {"ev":"ready","labels":[...]}                     开始收听
  {"ev":"partial","label","text","t"}               说话过程中的临时识别
  {"ev":"final","label","text","t","key"}           一句话定稿（英文）
  {"ev":"zh","label","text","key","preview":bool}   该句译文（preview=True 为临时译文）
  {"ev":"warn","msg":...}                           引擎告警（例如系统音频全静音=缺权限）
  {"ev":"stopped"}
"""
from __future__ import annotations

import argparse
import json
import os
import signal
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "engine", "livecaption"))
os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")

_out = sys.stdout
_out_lock = threading.Lock()


def emit(**ev) -> None:
    with _out_lock:
        _out.write(json.dumps(ev, ensure_ascii=False) + "\n")
        _out.flush()


class _WarnStream:
    """引擎把告警 print 到 stderr；转成 warn 事件交给面板显示。"""

    def __init__(self):
        self._buf = ""

    def write(self, s: str) -> int:
        self._buf += s
        while "\n" in self._buf:
            line, self._buf = self._buf.split("\n", 1)
            if line.strip():
                emit(ev="warn", msg=line.strip()[:600])
        return len(s)

    def flush(self) -> None:
        pass


def seg_text(segments) -> str:
    return " ".join((s[1] or "").strip() for s in segments if s[1]).strip()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", choices=["system", "mic", "both", "file"], default="system")
    ap.add_argument("--file")
    ap.add_argument("--mt-model", default=None)
    ap.add_argument("--no-translate", action="store_true")
    args = ap.parse_args()

    sys.stderr = _WarnStream()
    sys.stdout = sys.stderr          # 引擎里任何 print 都不许污染事件流

    emit(ev="status", msg="正在加载语音识别模型…")
    from livecaption import config
    from livecaption.asr import AsrWorker, build_recognizer
    from livecaption.audio import FileSource, MicSource, SystemAudioSource
    from livecaption.languages import normalize_target_language
    from livecaption.models import resolve_audiotee
    from livecaption.translate import Translator

    # 响应速度参数：默认值见下，可被同目录 settings.json 覆盖（只在本进程里覆盖引擎参数，不改引擎源码）。
    tune = {"att_right": 6, "preview_words": 4, "soft_max": 3.5}
    try:
        with open(os.path.join(HERE, "settings.json"), encoding="utf-8") as f:
            tune.update({k: v for k, v in json.load(f).items() if k in tune})
    except (OSError, ValueError):
        pass
    # 流式识别的前瞻帧数：6=560ms、3=320ms、0=80ms（模型训练时支持的档位）；越小英文出得越快、临时结果越容易改口
    config.ASR_ATT_CONTEXT = [56, int(tune["att_right"])]
    config.RULE2_SOFT_MAX_UTTERANCE = float(tune["soft_max"])  # 连续说话满这么多秒后，遇到句末标点就切一句（引擎原值 8）
    config.RULE3_MIN_UTTERANCE_LENGTH = 12.0  # 一直没有句末标点时最长 12 秒强制切（原 20 秒）
    config.RULE2_PUNCT_SILENCE = 0.45         # 句子已说完时，停顿 0.45 秒即定稿（原 0.6）
    config.RULE2_MIN_TRAILING_SILENCE = 0.9   # 句子没说完时，停顿 0.9 秒才定稿（原 1.2）
    PREVIEW_EVERY_WORDS = int(tune["preview_words"])  # 每多识别出这么多词就刷新一次临时译文
    emit(ev="tune", **tune)

    sources = []
    if args.source == "file":
        sources.append(FileSource(args.file, label="them"))
    if args.source in ("mic", "both"):
        sources.append(MicSource(label="me"))
    if args.source in ("system", "both"):
        sources.append(SystemAudioSource(resolve_audiotee(None), label="them"))

    _backend, asr_id = config.ASR_MODELS[config.DEFAULT_ASR_MODEL_ALIAS]
    recognizer = build_recognizer(asr_id, config.ASR_LANGUAGE, False, log=lambda m: emit(ev="status", msg=str(m)))

    stop_event = threading.Event()
    signal.signal(signal.SIGINT, lambda *_: stop_event.set())
    signal.signal(signal.SIGTERM, lambda *_: stop_event.set())

    def key(label, started_at) -> str:
        return f"{label}@{started_at.isoformat()}"

    def backlog_sec() -> float:
        """还有多少秒的音频排在队列里没被识别（=字幕落后于声音的时间）。"""
        worst = 0.0
        for src in sources:
            with src.queue.mutex:
                n = sum(len(c) for c in src.queue.queue if c is not None)
            worst = max(worst, n / config.SAMPLE_RATE)
        return worst

    # 识别优先：识别和翻译共用 GPU，临时译文发得太勤会把识别挤慢，字幕越来越落后。
    # 所以只有"上一条临时译文已返回"且"音频没有积压"时才发起下一条。
    PREVIEW_MAX_BACKLOG = 0.35     # 音频积压超过这么多秒就暂停临时译文，让识别先追上
    preview_started = [0.0]        # 上一条临时译文的提交时刻；0 表示当前没有在翻译中的

    def preview_idle() -> bool:
        return preview_started[0] == 0.0 or time.monotonic() - preview_started[0] > 3.0

    def preview_done(label, zh, t) -> None:
        preview_started[0] = 0.0
        emit(ev="zh", label=label, text=seg_text(zh), key=key(label, t), preview=True, ms=ms_since(("p", label)))

    sent_at: dict = {}      # 提交翻译的时刻，用来算"提交 → 译文返回"的耗时

    def ms_since(k) -> int | None:
        t = sent_at.get(k)
        return int((time.monotonic() - t) * 1000) if t else None

    translator = None
    if not args.no_translate:
        target = normalize_target_language(config.DEFAULT_TARGET_LANG)
        mt_id = config.MT_MODELS[args.mt_model or config.DEFAULT_MT_MODEL_ALIAS]
        emit(ev="status", msg="正在加载翻译模型…")
        translator = Translator(
            mt_id, target.prompt_name,
            on_translation=lambda label, zh, t: emit(ev="zh", label=label, text=seg_text(zh), key=key(label, t), preview=False,
                                                     ms=ms_since(("f", key(label, t)))),
            on_ready=lambda: emit(ev="status", msg="翻译模型就绪"),
            on_failed=lambda: emit(ev="warn", msg="翻译模型加载失败，只出英文"),
            on_preview=preview_done,
            context_size=config.MT_CONTEXT_SENTENCES,
        )
        translator.start()

    preview_words: dict[str, int] = {}

    def on_partial(label, text, started_at, speaker=None):
        emit(ev="partial", label=label, text=text, t=f"{started_at:%H:%M:%S}", key=key(label, started_at))
        if translator:
            n = len(text.split())
            # 新的一句开始时词数会变少，重新计数；不要求出现句末标点
            if n < preview_words.get(label, 0):
                preview_words[label] = 0
            if (n >= 3 and n - preview_words.get(label, 0) >= PREVIEW_EVERY_WORDS
                    and preview_idle() and (args.source == "file" or backlog_sec() < PREVIEW_MAX_BACKLOG)):
                preview_words[label] = n
                preview_started[0] = time.monotonic()
                sent_at[("p", label)] = time.monotonic()
                translator.submit_preview(label, [(speaker, text, None)], started_at)

    def on_final(label, segments, started_at):
        preview_words.pop(label, None)
        text = seg_text(segments)
        if not text:
            return
        emit(ev="final", label=label, text=text, t=f"{started_at:%H:%M:%S}", key=key(label, started_at))
        if translator:
            preview_started[0] = 0.0    # 这句已定稿，排队中的临时译文会被引擎丢弃
            sent_at.pop(("p", label), None)
            if len(sent_at) > 200:
                sent_at.clear()
            sent_at[("f", key(label, started_at))] = time.monotonic()
            translator.submit(label, segments, started_at)

    workers = []
    for src in sources:
        w = AsrWorker(recognizer, src.queue, src.label, on_partial, on_final,
                      on_error=stop_event.set, use_audio_timestamps=args.source == "file")
        workers.append(w)
        w.start()
        src.start()
    emit(ev="ready", labels=[s.label for s in sources])

    def report_lag() -> None:
        """每秒上报：还有多少秒的音频排在队列里没被识别（=字幕落后于声音的时间）。"""
        while not stop_event.wait(1.0):
            emit(ev="lag", sec=round(backlog_sec(), 2))

    threading.Thread(target=report_lag, daemon=True).start()

    try:
        if args.source == "file":
            for w in workers:
                while w.is_alive() and not stop_event.is_set():
                    w.join(timeout=0.2)
        else:
            stop_event.wait()
    finally:
        for src in sources:
            src.stop()
        for w in workers:
            w.join(timeout=15)
        if translator is not None:
            translator.stop()
            translator.join(timeout=20)
        emit(ev="stopped")


if __name__ == "__main__":
    main()
