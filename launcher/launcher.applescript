-- 会议助手：常驻应用。打开=启动服务并弹出面板；再次点击 Dock 图标=重新弹出面板；退出=停止服务。
on run
	do shell script "$HOME/Projects/meeting-copilot/start.sh >/dev/null 2>&1 </dev/null &"
end run
on reopen
	do shell script "$HOME/Projects/meeting-copilot/start.sh >/dev/null 2>&1 </dev/null &"
end reopen
on quit
	do shell script "$HOME/Projects/meeting-copilot/stop.sh >/dev/null 2>&1; true"
	continue quit
end quit
