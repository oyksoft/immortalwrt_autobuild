-- BBR 加速 —— LuCI 控制器
-- 菜单位置：网络 → BBR 加速
--
-- 参照官方 luci-app-nps 的写法：菜单直接用 entry(..., cbi(...)) 注册，
-- 不写 menu.d/*.json（json 里 type:"cbi" 的 action 分发在新版 LuCI 会递归）。
module("luci.controller.bbr", package.seeall)

function index()
	if not nixio.fs.access("/etc/config/bbr") then
		return
	end

	local page = entry({ "admin", "network", "bbr" },
		cbi("bbr"), translate("BBR 加速"), 60)
	page.dependent = true
end
