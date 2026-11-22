-- BBR 加速 —— LuCI CBI 模型
-- 菜单位置：网络 → BBR 加速
--
-- 交互设计：
--   只给一个决定——选哪个拥塞控制算法。
--   选 BBR = 开启 BBR 加速，选 CUBIC = 恢复系统默认，不另设开关。
--   选项文字自带语义标注（哪个是加速、哪个是系统默认）。
--   下方状态区全部实时读内核，只展示真实状态。
--
-- 能生效的：拥塞控制算法（写 /proc/sys/net/ipv4/tcp_congestion_control）
-- 只读状态：当前生效算法、内核可用算法、内核默认队列调度、各网卡实际调度、模块状态
--
-- 为什么不提供「队列调度」配置项：
--   net.core.default_qdisc 在 OpenWrt 上由 netifd 接管，写不进去；
--   现有网卡的队列（如 mq）在网卡创建时就定死了，改内核默认值也无效。
--   BBR 并不强制需要 fq——内核 4.13+ 有 TCP internal pacing 兜底，
--   OpenWrt 官方标准组合就是 fq_codel + BBR。

local m, s, o
local sys = require "luci.sys"
-- luci.model.uci 模块里的方法都是 function xxx(self, ...) 形式，
-- 必须先拿 cursor 实例再以方法方式调用，不能直接 uci.get(...)
local uci = require "luci.model.uci"
local uci_cursor = uci.cursor()

-- 页面版本号（改动页面时同步递增，方便确认是不是最新版）
local PAGE_VERSION = "2026-11-15.6"

-- 拥塞控制算法的说明标注（key = 内核里的算法名）
local ALGO_DESC = {
	bbr   = "BBR（加速，推荐）",
	cubic = "CUBIC（系统默认）",
	reno  = "Reno",
	hybla = "HYBLA",
	cake  = "CAKE",
	htcp  = "H-TCP",
	vegas = "Vegas",
}

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
	v = v:gsub("%s+$", "")
	if v == "" then
		return nil
	end
	return v
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
-- 让 CBI 在 parse 阶段同步 commit + apply（而不是交给 XHR 异步处理）。
-- 关键：commit 必须发生在 on_commit hook 之前，否则 reload 里的 uci get
-- 读到的还是旧值（暂存区的新值只有 LuCI cursor 能看到，uci 命令看不到）。
-- 另外这样也不会触发 XHR 的 "There are no changes to apply" 误报。
m.apply_on_parse = false
m.title = translate("BBR 加速")
m.description = translate("BBR 是 TCP 拥塞控制算法。路由器单纯做转发时用不到它；但当路由器作为代理客户端（本机主动建立到远端的 TCP 连接）时，BBR 能明显改善高延迟、易丢包线路上的吞吐。修改后点「保存并应用」立即生效，无需重启。")

-- ===== 设置 =====
s = m:section(TypedSection, "bbr")
s.addremove = false
-- anonymous = true：不渲染 UCI section 名（大写会变成 “MAIN”）；
-- 但 self.title 的 <h3> 照常渲染，所以分组标题依然在
s.anonymous = true
s.title = translate("TCP 拥塞控制")

o = s:option(ListValue, "algorithm", translate("算法"))
-- 动态列出内核实际支持的算法，避免出现内核里根本不存在的选项
local avail = readfile("/proc/sys/net/ipv4/tcp_available_congestion_control") or ""
local algos = {}
for a in avail:gmatch("%S+") do
	algos[#algos + 1] = a
end
if #algos == 0 then
	-- 读不到时的兜底
	algos = { "bbr", "cubic", "reno" }
end
-- 当前配置里的算法也纳入列表，避免下拉框显示为空
local saved_algo = uci_cursor:get("bbr", "main", "algorithm")
if saved_algo and saved_algo ~= "" then
	local found = false
	for _, a in ipairs(algos) do
		if a == saved_algo then found = true end
	end
	if not found then
		algos[#algos + 1] = saved_algo
	end
end
for _, a in ipairs(algos) do
	o:value(a, ALGO_DESC[a] or a)
end
-- 默认值必须是列表里存在的
local default_algo = "bbr"
local has_bbr = false
for _, a in ipairs(algos) do
	if a == "bbr" then has_bbr = true end
end
if not has_bbr then
	default_algo = algos[1]
end
o.default = default_algo
o.description = translate("选 BBR 就是开启 BBR 加速，不另设开关；选 CUBIC 就是恢复系统默认。选项来自内核实际支持的算法列表。BBR 适合高延迟、易丢包的线路（例如跨境代理）。")

-- ===== 运行状态（实时读取内核）=====
s2 = m:section(SimpleSection)
s2.title = translate("运行状态")

o = s2:option(DummyValue, "page_version", translate("页面版本"))
o.value = PAGE_VERSION
o.description = translate("用于确认当前显示的是不是最新版本的页面。")

o = s2:option(DummyValue, "current_algorithm", translate("当前生效算法"))
o.value = function()
	return readfile("/proc/sys/net/ipv4/tcp_congestion_control") or "-"
end
o.description = translate("内核此刻实际使用的拥塞控制算法。")

o = s2:option(DummyValue, "available_algorithms", translate("内核可用算法"))
o.value = function()
	return readfile("/proc/sys/net/ipv4/tcp_available_congestion_control") or "-"
end
o.description = translate("当前内核已编译进并可用的算法列表。")

o = s2:option(DummyValue, "default_qdisc", translate("内核默认队列调度"))
o.value = function()
	return readfile("/proc/sys/net/core/default_qdisc") or "-"
end
o.description = translate("OpenWrt 内核只编译了 fq_codel（未编 sch_fq 模块，写 fq 会报 ENOENT），且该参数由 netifd 接管不可修改。注意：fq_codel（FQ-CoDel）与 fq（sch_fq）是两个不同的内核模块，名字相似但完全不是一回事。BBR 不强制需要 fq——内核 4.13+ 有 TCP internal pacing 兜底，OpenWrt 官方标准组合就是 fq_codel + BBR。")

o = s2:option(DummyValue, "nic_qdisc", translate("各网卡实际调度"))
o.value = qdisc_list
o.description = translate("每个网卡当前 root 队列使用的调度算法。")

o = s2:option(DummyValue, "module_state", translate("tcp_bbr 模块"))
o.value = function()
	return module_loaded("tcp_bbr") and translate("已加载") or translate("未加载")
end
o.description = translate("未加载时无法切换到 BBR。")

-- 保存后立即应用（执行 init 脚本 reload）
-- 注意：reload 是 rc.common 的标准 action，“apply” 不是
--
-- 时序说明（见上方 m.apply_on_parse = false）：
-- CBI 在 on_commit 之前已经 commit 完毕，所以这里的 uci get
-- 能读到刚保存的新值，reload 立即生效。
function m.on_commit(self)
	sh("/etc/init.d/bbr reload >/dev/null 2>&1")
end

return m
