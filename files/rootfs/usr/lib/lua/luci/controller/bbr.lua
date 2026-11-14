-- BBR 加速 —— LuCI 控制器
-- 菜单位置：网络 → BBR 加速
module("luci.controller.bbr", package.seeall)

function index()
	if not nixio.fs.access("/etc/config/bbr") then
		return
	end

	local page = entry({ "admin", "network", "bbr" },
		alias("admin", "network", "bbr"), translate("BBR 加速"), 60)
	page.dependent = true
end
