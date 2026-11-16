#!/bin/sh
# 启动会议助手：本地模型服务 + 面板服务 + 面板窗口。可重复运行。
cd "$HOME/Projects/meeting-copilot" || exit 1
open -g -a /Applications/Ollama.app
if ! curl -s -m 1 http://127.0.0.1:8766/state >/dev/null 2>&1; then
  nohup "$HOME/.local/bin/python3" copilot.py >> copilot.log 2>&1 </dev/null &
  echo $! > copilot.pid
  sleep 2
fi
open -na "Google Chrome" --args --app=http://127.0.0.1:8766 --window-size=1000,860
