# 会议助手

全本地运行的英文会议 / 视频助手（macOS，Apple Silicon）：

- **同传字幕**：抓取系统声音或麦克风，英文实时识别并译成中文；带半透明置顶悬浮字幕窗。
- **会议文稿**：中英对照，自动保存。
- **回答参考 / 提问参考**：按按钮时，针对最近 1–3 句里的问题给出英文回答，或根据对方发言给出两个备选提问。
- **会议纪要**：每次停止后自动生成英文纪要（少于 10 句不生成）。

## 组成

| 文件 | 作用 |
|---|---|
| `copilot.py` | 后端服务（Python 标准库，只监听 127.0.0.1:8766） |
| `panel.html` | 前端界面 |
| `engine_driver.py` | 把语音引擎的识别和翻译结果接成事件流 |
| `overlay/SubtitleOverlay.swift` | 原生悬浮字幕窗 |
| `launcher/launcher.applescript`、`start.sh`、`stop.sh` | 启动器 |
| `settings.json` | 响应速度参数 |
| `setup.sh` | 新机器上的安装脚本 |

## 用到的模型（都在本机运行）

- 语音识别：NVIDIA Nemotron 3.5 ASR Streaming 0.6B；端点检测：Silero VAD
- 英译中：腾讯 Hy-MT2 1.8B（8bit）
- 回答、提问、纪要：Gemma 3 12B（经 Ollama）

语音引擎是 [six-ddc/livecaption](https://github.com/six-ddc/livecaption)，未修改其源码，也不包含在本仓库里，由 `setup.sh` 下载。

## 安装

把仓库放到 `~/Projects/meeting-copilot`，运行 `./setup.sh`，然后打开 `/Applications/会议助手.app`。
首次使用需要在系统设置里允许麦克风和「仅系统音频录制」。

## 不在仓库里的东西

个人背景资料（`my_context.txt`）、保存位置设置（`config.json`）、日志、会议文稿与纪要（默认在 `~/Documents/会议记录`）。

## 许可证

本仓库代码以 MIT 许可证发布，见 `LICENSE`。语音引擎 livecaption 不在本仓库内，其使用受原项目条款约束。
