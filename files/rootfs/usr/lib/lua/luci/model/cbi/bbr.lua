-- BBR 加速 —— LuCI CBI 模型
-- 菜单位置：网络 → BBR 加速

local m, s, o
local sys = require "luci.sys"

-- 读文件（去掉尾部空白），读不到返回 nil
local function readfile(path)
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local v = f:read("*all")
	f:close()
	if not v then
		return nil
	end
	return (v:gsub("%s+$", ""))
end

-- 内核模块是否已加载
local function module_loaded(name)
	local mods = readfile("/proc/modules") or ""
	for line in mods:gmatch("[^\n]+") do
		if line:match("^" .. name .. "%s") then
			return true
		end
	end
	return false
end

-- 执行 shell，忽略错误
local function sh(cmd)
	pcall(sys.call, cmd)
end

m = Map("bbr")
m.title = translate("BBR 加速")
m.description = translate("BBR 是 TCP 拥塞控制算法。路由器单纯做转发时用不到它；但当路由器作为代理客户端（本机主动建立到远端的 TCP 连接）时，BBR 能明显改善高延迟、易丢包线路上的吞吐。")

s = m:section(TypedSection, "bbr")
s.addremove = false
s.anonymous = true

o = s:option(Flag, "enabled", translate("启用 BBR"))
o.rmempty = false
o.default = "1"
o.description = translate("开启后使用 BBR 拥塞控制算法；关闭则恢复为系统默认的 CUBIC。保存后立即生效，无需重启。")

o = s:option(ListValue, "algorithm", translate("拥塞控制算法"))
o:value("bbr", "BBR")
o:value("cubic", "CUBIC")
o:value("reno", "Reno")
o:value("hybla", "HYBLA")
o.default = "bbr"
o.description = translate("BBR 适合高延迟、易丢包的线路（例如跨境代理）。可选算法以内核实际支持为准，见下方状态。")

o = s:option(ListValue, "qdisc", translate("默认队列调度"))
o:value("fq", "fq")
o:value("codel", "codel")
o:value("pfifo_fast", "pfifo_fast")
o.default = "fq"
o.description = translate("BBR 必须搭配 fq 调度才能正常工作。")

-- ===== 运行状态（实时读取内核）=====
o = s:option(DummyValue, "current_algorithm", translate("当前生效算法"))
o.value = function()
	return readfile("/proc/sys/net/ipv4/tcp_congestion_control") or "-"
end
o.description = translate("内核此刻实际使用的拥塞控制算法。")

o = s:option(DummyValue, "available_algorithms", translate("内核可用算法"))
o.value = function()
	return readfile("/proc/sys/net/ipv4/tcp_available_congestion_control") or "-"
end
o.description = translate("当前内核已编译进并可用的算法列表。")

o = s:option(DummyValue, "current_qdisc", translate("当前队列调度"))
o.value = function()
	return readfile("/proc/sys/net/core/default_qdisc") or "-"
end
o.description = translate("内核此刻实际使用的默认队列调度算法。")

o = s:option(DummyValue, "module_state", translate("tcp_bbr 模块"))
o.value = function()
	return module_loaded("tcp_bbr") and translate("已加载") or translate("未加载")
end
o.description = translate("未加载时无法切换到 BBR。")

-- 保存后立即应用（先提交配置文件，再执行 init 脚本）
function m.on_commit(self)
	self.uci:commit("bbr")
	sh("/etc/init.d/bbr apply >/dev/null 2>&1")
end

return m
