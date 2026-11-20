#!/usr/bin/env python3
"""会议助手（全本地）：同传字幕 + 会议文稿 + 回答参考/提问参考 + 自动会议纪要，一个前端。

- 语音识别与翻译：engine_driver.py（livecaption 引擎，MLX，本机运行），以子进程启动。
- 回答参考、提问参考、纪要：本机 Ollama。只在用户点按钮或会议结束时才调用，
  不会在会议进行中自动运行（大模型和识别共用 GPU，自动运行会让字幕变慢）。
- 本文件只用 Python 标准库；只监听 127.0.0.1；不访问外网。
"""
import json
import os
import signal
import subprocess
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
ENGINE_PY = os.path.join(HERE, "engine", "livecaption", ".venv", "bin", "python")
DRIVER = os.path.join(HERE, "engine_driver.py")
OVERLAY_BIN = os.path.join(HERE, "overlay", "SubtitleOverlay")
OLLAMA = os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434")
MODEL = os.environ.get("COPILOT_MODEL", "gemma3:12b")
# 回答模型的内存：会议助手开着就一直留在内存里（按按钮不用等加载），退出时卸载。
# 设成 3 小时而不是永久，是为了万一会议助手异常退出没来得及卸载，最多 3 小时后 Ollama 也会自己释放。
KEEP_ALIVE = "3h"
OLLAMA_FLAG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ollama_started_by_copilot")
PORT = int(os.environ.get("COPILOT_PORT", "8766"))
CONTEXT_FILE = os.path.join(HERE, "my_context.txt")
CONFIG_FILE = os.environ.get("COPILOT_CONFIG", os.path.join(HERE, "config.json"))
DEFAULT_SAVE_DIR = os.path.expanduser("~/Documents/会议记录")

ANSWER_FOCUS = 3        # "现在给回答"只针对最近这么多句里的问题
ANSWER_BACKGROUND = 10  # 另外附带这么多句更早的内容作背景
ASK_LINES = 80          # "现在给提问"参考最近这么多句
MIN_LINES_FOR_SUMMARY = 10
NUM_CTX = 16384         # 所有请求用同一个上下文长度：Ollama 每换一次长度就要重新加载模型，会慢十几秒
SUMMARY_CHUNK = 30000   # 文稿超过这么多字符就分段摘要再合并（约 20 多分钟的连续讲话）

ANSWER_PROMPT = """你是会议中的实时助手。用户是中文母语者，正在参加英文线上会议，需要回答对方刚提的问题。
语音识别的文稿可能有错字。"对方"是会议里的其他人，"我"是用户自己。

只看【最近几句】里对方提出的问题：有几个就逐个回答，每个问题单独一组；如果没有标准问句，就把最后一句当作需要用户回应的话，给一组。
【更早的内容】只用来理解背景，不要去回答里面的问题。

严格按下面格式输出（多个问题就重复这三行，组与组之间空一行），不要输出其他内容：
问题：<把该问题译成简洁中文>
回答参考：<2到3句自然、口语化的英文，可以直接说出口>
中文要点：<一句中文概括这个回答>

回答要针对这个问题本身，尽量利用"用户背景"里的信息；背景里没有的事实不要编造，用稳妥的通用说法或用 [ ] 标出需要用户自己填的内容。"""

ASK_PROMPT = """你是会议中的实时助手。用户是中文母语者，刚听完对方的英文发言或报告，现在需要向对方提一个问题。
下面是对方发言的文稿（语音识别结果，可能有错字）。"对方"是发言人，"我"是用户自己。

请根据发言的具体内容，提出两个角度不同的备选问题，供用户二选一：
- 提问1 偏向澄清或追问细节（数据、定义、某个具体结果）。
- 提问2 偏向方法、局限或含义的延伸讨论。
每个问题 1 到 2 句自然、礼貌、口语化的英文，可以直接说出口；必须紧扣文稿里实际讲到的内容，不要问文稿里已经回答过的事。

严格按下面格式输出，不要输出其他内容：
提问1：<英文问题>
中文：<这个问题的中文意思>
提问2：<英文问题>
中文：<这个问题的中文意思>"""

SUMMARY_PROMPT = """You are a meeting-minutes assistant. Below is the full transcript of an English meeting (or video), \
produced by speech recognition, so it may contain recognition errors. "Other party" is everyone else; "Me" is the user.
Write concise minutes ENTIRELY IN ENGLISH. Do not use any Chinese. Use exactly these headings:
## Summary
## Key Points
## Questions Raised and My Responses
## Action Items
Under "Questions Raised and My Responses", list every question anyone asked, each followed by my response; \
if the transcript records no response to a question, still list the question and write "No response recorded".
Include only what the transcript supports; if a section truly has nothing, write "None"."""

SUMMARY_CHUNK_PROMPT = """Below is one part of an English meeting transcript (speech recognition, may contain errors). \
"Other party" is everyone else; "Me" is the user. In English only, list this part's key points, the questions raised, \
the user's responses, and any action items. Keep specific numbers and conclusions."""

lock = threading.Lock()
state = {
    "engine": "off",          # off / loading / listening / stopping
    "source": "system",
    "status_msg": "",
    "warn": "",
    "lines": [],              # 定稿句：{key,label,t,en,zh}
    "partials": {},           # label -> {text,zh,t}
    "cards": [],              # 回答参考 / 提问参考卡片
    "busy": False,
    "summary_status": "",     # 自动纪要的进度或结果，一行字
    "model_ok": None,
    "lag": 0,
    "session_dir": "",
}
_proc = None
_overlay = None
_reader_thread = None     # 读引擎事件的线程；引擎退出后它负责保存文稿并启动纪要
_sum_thread = None        # 正在生成纪要的线程
_shutting_down = False
_card_id = 0


# ---------------------------------------------------------------- 设置
def load_config():
    try:
        with open(CONFIG_FILE, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_dir():
    d = load_config().get("save_dir") or DEFAULT_SAVE_DIR
    return os.path.expanduser(d)


def set_save_dir(path):
    cfg = load_config()
    cfg["save_dir"] = path
    with open(CONFIG_FILE, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=1)


def choose_folder():
    """弹出系统的选择文件夹对话框；返回所选路径，取消则返回空串。"""
    script = ['-e', 'activate',
              '-e', 'POSIX path of (choose folder with prompt "选择保存会议文稿和纪要的文件夹")']
    try:
        r = subprocess.run(["osascript", *script], capture_output=True, text=True, timeout=180)
    except subprocess.TimeoutExpired:
        return ""
    path = r.stdout.strip()
    if r.returncode != 0 or not os.path.isdir(path):
        return ""
    return path.rstrip("/") or "/"


def read_context():
    try:
        with open(CONTEXT_FILE, encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return ""


# ---------------------------------------------------------------- 文稿
def who(label):
    return "我" if label == "me" else "对方"


def transcript_text(lines, with_zh=False, english_labels=False):
    out = []
    for ln in lines:
        speaker = ("Me" if ln["label"] == "me" else "Other party") if english_labels else who(ln["label"])
        out.append(f"[{ln['t']}] {speaker}: {ln['en']}")
        if with_zh and ln.get("zh"):
            out.append(f"    {ln['zh']}")
    return "\n".join(out)


def save_transcript():
    with lock:
        d, lines = state["session_dir"], list(state["lines"])
    if not d or not lines:
        return
    os.makedirs(d, exist_ok=True)
    body = "# 会议文稿 " + os.path.basename(d) + "\n\n" + transcript_text(lines, with_zh=True) + "\n"
    tmp = os.path.join(d, "transcript.md.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(body)
    os.replace(tmp, os.path.join(d, "transcript.md"))


def ollama_stream(messages, num_predict=260):
    opts = {"temperature": 0.3, "num_predict": num_predict, "num_ctx": NUM_CTX}
    body = json.dumps({"model": MODEL, "messages": messages, "stream": True,
                       "keep_alive": KEEP_ALIVE, "options": opts}).encode()
    req = urllib.request.Request(OLLAMA + "/api/chat", data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=300) as r:
        for raw in r:
            if not raw.strip():
                continue
            d = json.loads(raw)
            piece = d.get("message", {}).get("content", "")
            if piece:
                yield piece
            if d.get("done"):
                break


# ---------------------------------------------------------------- 回答参考 / 提问参考
def others_only(lines, source):
    """开会模式（麦克风+系统声音）下只取对方说的话；其他模式全部都算对方。"""
    return [ln for ln in lines if ln["label"] != "me"] if source == "both" else lines


def make_card(kind):
    """kind = "answer"（现在给回答）或 "ask"（现在给提问）。只在用户点按钮时调用。"""
    global _card_id
    with lock:
        lines, source = list(state["lines"]), state["source"]
        if not lines or state["busy"]:
            return
        _card_id += 1
        card = {"id": _card_id, "kind": kind, "time": time.strftime("%H:%M:%S"), "text": "", "done": False}
        state["cards"].insert(0, card)
        state["busy"] = True
    if kind == "answer":
        theirs = others_only(lines, source) or lines
        focus = theirs[-ANSWER_FOCUS:]
        first_key = focus[0]["key"]
        idx = next(i for i, ln in enumerate(lines) if ln["key"] == first_key)
        earlier = lines[max(0, idx - ANSWER_BACKGROUND):idx]
        system = ANSWER_PROMPT
        user = (f"【用户背景】\n{read_context() or '（未填写）'}\n\n"
                f"【更早的内容】\n{transcript_text(earlier) or '（无）'}\n\n"
                f"【最近几句】\n{transcript_text(focus)}")
        predict = 420
    else:
        system = ASK_PROMPT
        user = (f"【用户背景】\n{read_context() or '（未填写）'}\n\n"
                f"【对方发言文稿】\n{transcript_text(lines[-ASK_LINES:])[-12000:]}")
        predict = 320
    t0 = time.time()
    try:
        buf = ""
        for piece in ollama_stream([{"role": "system", "content": system}, {"role": "user", "content": user}],
                                   num_predict=predict):
            buf += piece
            with lock:
                card["text"] = buf
        with lock:
            state["model_ok"] = True
            card["done"] = True
            card["secs"] = round(time.time() - t0, 1)
    except Exception as e:
        with lock:
            state["model_ok"] = False
            card["text"] = f"⚠️ 调用本地模型失败：{e}\n请确认 Ollama 已启动且已下载 {MODEL}。"
            card["done"] = True
    finally:
        with lock:
            state["busy"] = False
            del state["cards"][30:]


# ---------------------------------------------------------------- 自动纪要
def summarize(lines, d):
    """会议结束后自动调用：生成纯英文纪要并写入该次会议的文件夹。"""
    name = os.path.basename(d)
    with lock:
        state["summary_status"] = f"正在生成纪要（{name}）…"
    try:
        text = transcript_text(lines, english_labels=True)
        if len(text) > SUMMARY_CHUNK:
            # 长会议：先逐段提炼要点，再把各段要点合并成一份纪要
            parts, notes = [text[i:i + SUMMARY_CHUNK] for i in range(0, len(text), SUMMARY_CHUNK)], []
            for i, part in enumerate(parts):
                with lock:
                    state["summary_status"] = f"正在生成纪要（{name}）：整理第 {i + 1}/{len(parts)} 段…"
                notes.append("".join(ollama_stream(
                    [{"role": "system", "content": SUMMARY_CHUNK_PROMPT},
                     {"role": "user", "content": part}], num_predict=700)))
            text = ("Notes from each part of the meeting, in chronological order:\n\n"
                    + "\n\n".join(f"[Part {i + 1}]\n{n}" for i, n in enumerate(notes)))
            with lock:
                state["summary_status"] = f"正在生成纪要（{name}）：合并…"
        buf = "".join(ollama_stream([{"role": "system", "content": SUMMARY_PROMPT},
                                     {"role": "user", "content": text}], num_predict=1200))
        os.makedirs(d, exist_ok=True)
        path = os.path.join(d, "summary.md")
        with open(path, "w", encoding="utf-8") as f:
            f.write("# Meeting Minutes " + name + "\n\n" + buf.strip() + "\n")
        with lock:
            state["summary_status"] = f"纪要已保存：{path}"
    except Exception as e:
        with lock:
            state["summary_status"] = f"⚠️ 纪要生成失败（{name}）：{e}。文稿已保存。"


# ---------------------------------------------------------------- 引擎
def translate_warn(msg):
    low = msg.lower()
    if "all silence" in low or "system audio recording" in low:
        return ("系统声音抓到的全是静音。如果此刻确实有声音在播放，说明缺少录音权限：打开 系统设置 → 隐私与安全性 → "
                "屏幕与系统录音，滚动到下方的「仅系统音频录制」，把「会议助手」加进去并打开，然后退出会议助手重新打开。")
    if "restarting audiotee" in low:
        return "系统声音采集中断，已自动重连（切换了输出设备时会出现）。"
    if "translation" in low and ("disabled" in low or "failed" in low):
        return "翻译模型加载失败，目前只出英文。"
    return ""


def handle_event(ev):
    kind = ev.get("ev")
    with lock:
        if kind == "status":
            state["status_msg"] = ev.get("msg", "")
        elif kind == "ready":
            state["engine"] = "listening"
            state["status_msg"] = ""
        elif kind == "partial":
            p = state["partials"].get(ev["label"])
            zh = p["zh"] if p and p.get("key") == ev.get("key") else ""
            state["partials"][ev["label"]] = {"text": ev["text"], "t": ev["t"], "key": ev.get("key"), "zh": zh}
        elif kind == "final":
            p = state["partials"].pop(ev["label"], None)
            zh = p["zh"] if p and p.get("key") == ev["key"] else ""
            state["lines"].append({"key": ev["key"], "label": ev["label"], "t": ev["t"],
                                   "en": ev["text"], "zh": zh, "zh_final": False})
        elif kind == "lag":
            state["lag"] = ev.get("sec", 0)
            hist = state.setdefault("lag_hist", [])
            hist.append(ev.get("sec", 0))
            del hist[:-1200]
        elif kind == "tune":
            state["tune"] = {k: v for k, v in ev.items() if k != "ev"}
        elif kind == "zh":
            if ev.get("ms") is not None:
                perf = state.setdefault("perf", {"preview_ms": [], "final_ms": []})
                arr = perf["preview_ms" if ev.get("preview") else "final_ms"]
                arr.append(ev["ms"])
                del arr[:-300]
            if ev.get("preview"):
                p = state["partials"].get(ev["label"])
                if p and p.get("key") == ev["key"]:
                    p["zh"] = ev["text"]
            else:
                for ln in reversed(state["lines"]):
                    if ln["key"] == ev["key"]:
                        ln["zh"], ln["zh_final"] = ev["text"], True
                        break
        elif kind == "warn":
            with open(os.path.join(HERE, "engine.log"), "a", encoding="utf-8") as f:
                f.write(time.strftime("%H:%M:%S ") + ev.get("msg", "") + "\n")
            zh = translate_warn(ev.get("msg", ""))
            if zh:
                state["warn"] = zh
        elif kind == "stopped":
            state["status_msg"] = ""
    if kind in ("final", "zh") and not ev.get("preview"):
        save_transcript()


def reader(proc):
    global _sum_thread
    for raw in proc.stdout:
        try:
            handle_event(json.loads(raw))
        except (ValueError, KeyError):
            continue
    proc.wait()
    with lock:
        crashed = state["engine"] in ("loading", "listening") and proc.returncode not in (0, None)
        state["engine"] = "off"
        state["partials"] = {}
        state["lag"] = 0
        if crashed:
            state["warn"] = f"语音引擎意外退出（代码 {proc.returncode}）。详情见 {os.path.join(HERE, 'engine.log')}"
        lines, d = list(state["lines"]), state["session_dir"]
    save_transcript()
    # 会议结束：自动生成纪要（内容太少就不生成）
    if d and len(lines) >= MIN_LINES_FOR_SUMMARY:
        _sum_thread = threading.Thread(target=summarize, args=(lines, d), daemon=True)
        _sum_thread.start()
    elif d:
        with lock:
            state["summary_status"] = "本次内容太少，没有生成纪要。"
        if not lines:
            try:
                os.rmdir(d)          # 空会议不留空文件夹
            except OSError:
                pass


def start_engine(source, file=None):
    global _proc, _reader_thread
    with lock:
        if state["engine"] != "off":
            return False
        d = os.path.join(save_dir(), time.strftime("%Y-%m-%d_%H%M%S"))
        state.pop("perf", None)
        state.pop("lag_hist", None)
        state.update(engine="loading", source=source, status_msg="正在启动语音引擎…", warn="", lag=0,
                     lines=[], partials={}, cards=[], session_dir=d)
    try:
        os.makedirs(d, exist_ok=True)
    except OSError as e:
        with lock:
            state.update(engine="off", status_msg="", session_dir="",
                         warn=f"无法在所选文件夹里创建会议目录：{e}。请重新选择保存位置。")
        return False
    cmd = [ENGINE_PY, DRIVER, "--source", source]
    if file:
        cmd += ["--file", file]
    log = open(os.path.join(HERE, "engine.log"), "a")
    _proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=log, text=True, bufsize=1, cwd=HERE)
    _reader_thread = threading.Thread(target=reader, args=(_proc,), daemon=True)
    _reader_thread.start()
    return True


def stop_engine():
    with lock:
        if state["engine"] == "off" or _proc is None:
            return
        state["engine"] = "stopping"
        state["status_msg"] = "正在收尾…"
    try:
        _proc.send_signal(signal.SIGTERM)
    except OSError:
        pass

    def reap(p):
        try:
            p.wait(timeout=30)
        except subprocess.TimeoutExpired:
            p.kill()
    threading.Thread(target=reap, args=(_proc,), daemon=True).start()


def overlay_running():
    return _overlay is not None and _overlay.poll() is None


_overlay_lock = threading.Lock()


def toggle_overlay(want=None):
    """开/关原生悬浮字幕窗。want=True/False 表示要开/要关（重复请求无副作用）；None 表示切换。返回操作后是否开着。"""
    global _overlay
    with _overlay_lock:
        running = overlay_running()
        if want is None:
            want = not running
        if want and not running:
            _overlay = subprocess.Popen([OVERLAY_BIN, str(PORT)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        elif not want and running:
            _overlay.terminate()
            _overlay = None
        return bool(want)


def warmup():
    """打开会议助手时把回答模型预先装进内存。Ollama 可能刚被打开、还没就绪，最多重试 60 秒。"""
    for attempt in range(30):
        if _shutting_down:
            return
        try:
            for _ in ollama_stream([{"role": "user", "content": "hi"}], num_predict=2):
                break
            with lock:
                state["model_ok"] = True
            return
        except Exception:
            time.sleep(2)
    with lock:
        state["model_ok"] = False


# ---------------------------------------------------------------- HTTP
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        data = body if isinstance(body, bytes) else body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _local_only(self):
        return (self.headers.get("Host") or "").split(":")[0] in ("127.0.0.1", "localhost")

    def do_GET(self):
        if not self._local_only():
            return self._send(403, "{}")
        if self.path == "/":
            with open(os.path.join(HERE, "panel.html"), "rb") as f:
                return self._send(200, f.read(), "text/html; charset=utf-8")
        if self.path == "/state":
            with lock:
                if "Mozilla" in (self.headers.get("User-Agent") or ""):
                    state["browser_seen"] = time.time()
                out = dict(state)
                out["lines"] = state["lines"][-120:]
                out["n_lines"] = len(state["lines"])
            out["model"] = MODEL
            out["context"] = read_context()
            out["overlay"] = overlay_running()
            out["save_dir"] = save_dir()
            return self._send(200, json.dumps(out, ensure_ascii=False))
        self._send(404, "{}")

    def do_POST(self):
        if not self._local_only() or self.headers.get("X-Copilot") != "1":
            return self._send(403, "{}")
        n = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            body = {}
        ok = True
        if self.path == "/start":
            src = body.get("source", "system")
            ok = src in ("system", "mic", "both") and start_engine(src)
        elif self.path == "/start_file":          # 测试用：转写一个本地音频文件
            f = str(body.get("file", ""))
            ok = os.path.isfile(f) and start_engine("file", f)
        elif self.path == "/stop":
            stop_engine()
        elif self.path == "/overlay":
            on = body.get("on")
            toggle_overlay(None if on is None else bool(on))
        elif self.path == "/answer":
            threading.Thread(target=make_card, args=("answer",), daemon=True).start()
        elif self.path == "/ask":
            threading.Thread(target=make_card, args=("ask",), daemon=True).start()
        elif self.path == "/context":
            with open(CONTEXT_FILE, "w", encoding="utf-8") as f:
                f.write(str(body.get("text", ""))[:8000])
        elif self.path == "/clear":
            with lock:
                state["cards"].clear()
        elif self.path == "/dismiss_warn":
            with lock:
                state["warn"] = ""
        elif self.path == "/choose_folder":
            path = choose_folder()
            ok = bool(path)
            if ok:
                set_save_dir(path)
        elif self.path == "/open_folder":
            with lock:
                d = state["session_dir"]
            d = d if d and os.path.isdir(d) else save_dir()
            os.makedirs(d, exist_ok=True)
            subprocess.Popen(["open", d])
        else:
            return self._send(404, "{}")
        self._send(200, json.dumps({"ok": bool(ok)}))


def release_model():
    """退出时把回答模型从内存里卸载；Ollama 若是会议助手打开的，也一并退出。"""
    try:
        body = json.dumps({"model": MODEL, "keep_alive": 0}).encode()
        urllib.request.urlopen(urllib.request.Request(OLLAMA + "/api/generate", data=body,
                               headers={"Content-Type": "application/json"}), timeout=20).read()
    except Exception:
        pass
    if os.path.exists(OLLAMA_FLAG):
        try:
            os.remove(OLLAMA_FLAG)
        except OSError:
            pass
        subprocess.run(["pkill", "-x", "Ollama"], check=False)
        subprocess.run(["pkill", "-f", "Ollama.app/Contents/Resources/ollama serve"], check=False)


def shutdown(*_):
    """退出：关悬浮字幕、停引擎；会议还在进行时先把文稿存好、纪要写完再退出。
    收尾在后台线程里做，期间面板服务照常响应（此时重新打开会议助手能看到纪要进度）。"""
    global _shutting_down
    if _shutting_down:
        return
    _shutting_down = True

    def finish():
        if overlay_running():
            _overlay.terminate()
        if _proc is not None and _proc.poll() is None:
            _proc.terminate()
            try:
                _proc.wait(timeout=20)
            except subprocess.TimeoutExpired:
                _proc.kill()
        if _reader_thread is not None:
            _reader_thread.join(timeout=30)
        if _sum_thread is not None:
            _sum_thread.join(timeout=900)
        release_model()
        os._exit(0)

    threading.Thread(target=finish, daemon=True).start()


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    threading.Thread(target=warmup, daemon=True).start()
    print(f"会议助手: http://127.0.0.1:{PORT}  模型: {MODEL}  保存位置: {save_dir()}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
