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

-- 取某个网卡的 root 队列调度算法
local function qdisc_of(dev)
	local f = io.popen("tc qdisc show dev " .. dev .. " 2>/dev/null")
	if not f then
		return nil
	end
	local line = f:read("*l")
	f:close()
	if line then
		return line:match("^qdisc%s+(%S+)")
	end
	return nil
end

-- 列出所有网卡的 root 队列调度
local function qdisc_list()
	local devs = {}
	local d = io.popen("ls /sys/class/net 2>/dev/null")
	if not d then
		return "-"
	end
	for name in d:lines() do
		devs[#devs + 1] = name
	end
	d:close()

	local out = {}
	for _, dev in ipairs(devs) do
		if dev ~= "lo" then
			out[#out + 1] = dev .. "=" .. (qdisc_of(dev) or "?")
		end
	end
	if #out == 0 then
		return "-"
	end
	return table.concat(out, "  ")
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

o = s:option(ListValue, "qdisc", translate("内核默认队列调度"))
o:value("fq", "fq")
o:value("codel", "codel")
o:value("fq_codel", "fq_codel")
o:value("pfifo_fast", "pfifo_fast")
o.default = "fq"
o.description = translate("内核创建新队列时使用的默认调度算法。")

o = s:option(Flag, "apply_qdisc", translate("同时应用到现有网卡"))
o.rmempty = false
o.default = "0"
o.description = translate("把各网卡的 root 队列强制改成上面的调度算法（需要固件里装了 tc 命令）。内核默认队列调度只对「新建」的队列生效，已经在跑的网卡不受影响——BBR 在 fq_codel 下也能正常工作（内核 4.13+ 有 pacing 兜底），所以默认不强制改。")

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

o = s:option(DummyValue, "default_qdisc", translate("内核默认队列调度"))
o.value = function()
	return readfile("/proc/sys/net/core/default_qdisc") or "-"
end
o.description = translate("内核创建新队列时的默认调度算法。")

o = s:option(DummyValue, "nic_qdisc", translate("各网卡实际调度"))
o.value = qdisc_list
o.description = translate("每个网卡当前 root 队列使用的调度算法。")

o = s:option(DummyValue, "module_state", translate("tcp_bbr 模块"))
o.value = function()
	return module_loaded("tcp_bbr") and translate("已加载") or translate("未加载")
end
o.description = translate("未加载时无法切换到 BBR。")

-- 保存后立即应用（先提交配置文件，再执行 init 脚本）
-- 注意：reload 是 rc.common 的标准 action，“apply” 不是
function m.on_commit(self)
	self.uci:commit("bbr")
	sh("/etc/init.d/bbr reload >/dev/null 2>&1")
end

return m
