#!/bin/sh
# 在一台新的 Apple Silicon Mac 上安装会议助手。项目需放在 ~/Projects/meeting-copilot。
# 前置：macOS 14.2+、Xcode 命令行工具（swift）、uv、Google Chrome、Ollama。
set -e
cd "$HOME/Projects/meeting-copilot"

# 1) 语音引擎 livecaption（固定到已验证的版本；它没有开源许可证，只在本机使用，不随本仓库分发）
if [ ! -d engine/livecaption/.git ]; then
  mkdir -p engine
  git clone https://github.com/six-ddc/livecaption.git engine/livecaption
fi
git -C engine/livecaption checkout --quiet da182e0ae496743d975d4de556d3b6e450698a5c
(cd engine/livecaption && uv sync && bash scripts/build_audiotee.sh)

# 2) 悬浮字幕窗
swiftc -O -o overlay/SubtitleOverlay overlay/SubtitleOverlay.swift

# 3) 回答参考 / 提问参考 / 纪要用的本地模型
/Applications/Ollama.app/Contents/Resources/ollama pull gemma3:12b

# 4) 启动器（常驻应用；重建后需要重新授予麦克风和系统录音权限）
APP="/Applications/会议助手.app"
rm -rf "$APP"
osacompile -s -o "$APP" launcher/launcher.applescript
PB=/usr/libexec/PlistBuddy; PLIST="$APP/Contents/Info.plist"
$PB -c "Set :NSMicrophoneUsageDescription 会议助手需要麦克风来识别你在会议中说的话。" "$PLIST"
$PB -c "Add :NSAudioCaptureUsageDescription string 会议助手需要录制系统声音来生成字幕和会议文稿。" "$PLIST"
$PB -c "Set :CFBundleIdentifier local.meeting-assistant" "$PLIST" 2>/dev/null || $PB -c "Add :CFBundleIdentifier string local.meeting-assistant" "$PLIST"
codesign --force --deep -s - "$APP"
echo "完成。打开 /Applications/会议助手.app；首次点开始会下载识别和翻译模型（约 3.5 GB）。"
