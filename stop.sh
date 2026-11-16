#!/bin/sh
# 停止面板服务（它会顺带停掉语音引擎）。Ollama 保持运行。
cd "$HOME/Projects/meeting-copilot" || exit 0
[ -f copilot.pid ] && kill "$(cat copilot.pid)" 2>/dev/null
rm -f copilot.pid
