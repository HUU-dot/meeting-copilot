#!/bin/sh
# 停止会议助手：面板窗口、悬浮字幕、面板服务。Ollama 保持运行。
# 面板服务收到信号后会停掉语音引擎；会议还在进行时它先存好文稿、写完纪要再退出。
cd "$HOME/Projects/meeting-copilot" || exit 0
pkill -f "^$HOME/Projects/meeting-copilot/panel/MeetingPanel" 2>/dev/null
pkill -f "^$HOME/Projects/meeting-copilot/overlay/SubtitleOverlay" 2>/dev/null
[ -f copilot.pid ] && kill "$(cat copilot.pid)" 2>/dev/null
rm -f copilot.pid
true
