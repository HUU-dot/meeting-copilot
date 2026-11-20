#!/bin/sh
# 启动会议助手：本地模型服务 + 面板服务 + 面板窗口。可重复运行（窗口已开着就调到最前面，不开第二个）。
cd "$HOME/Projects/meeting-copilot" || exit 1
PANEL="$HOME/Projects/meeting-copilot/panel/MeetingPanel"
# Ollama 原本没开的话由会议助手打开，并记下来：会议助手退出时会把它一起关掉（原本就开着的不动）
if ! pgrep -x Ollama >/dev/null 2>&1 && ! curl -s -m 1 http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
  touch ollama_started_by_copilot
fi
open -g -a /Applications/Ollama.app
if ! curl -s -m 1 http://127.0.0.1:8766/state >/dev/null 2>&1; then
  nohup "$HOME/.local/bin/python3" copilot.py >> copilot.log 2>&1 </dev/null &
  echo $! > copilot.pid
fi
PID=$(pgrep -f "^$PANEL" | head -1)
if [ -n "$PID" ]; then
  kill -USR1 "$PID"
else
  nohup "$PANEL" 8766 >/dev/null 2>&1 </dev/null &
fi
