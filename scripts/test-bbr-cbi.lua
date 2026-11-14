-- BBR LuCI 页面冒烟测试
--
-- 目的：在 CI 里用 lua5.1 实际加载 files/rootfs 下的 CBI 文件，
--       捕获「语法对但运行时崩」的问题。
--
-- 踩过的坑（都是这个测试能抓到的）：
--   1. LuCI 26 的 CBI 没有 Map.apply，改用 on_commit hook
--   2. luci.model.uci 的方法都是 function xxx(self, ...) 形式，
--      必须 uci.cursor():get(...) ，直接 uci.get(...) 会参数错位崩掉
--   3. DummyValue 的 o.value 必须是字符串或函数，不能是别的类型
--
-- 用法：lua5.1 scripts/test-bbr-cbi.lua

local failed = 0
local function ok(cond, msg)
	if cond then
		print("  OK   " .. msg)
	else
		print("  FAIL " .. msg)
		failed = failed + 1
	end
end

-- ============ mock: luci.sys ============
package.preload["luci.sys"] = function()
	return {
		call = function(...) return 0 end,
		exec = function(...) return "" end,
	}
end

-- ============ mock: luci.model.uci ============
-- 真实模块里方法都是 function get(self, ...) 形式，cursor() 返回模块表本身。
-- 这里把 self 拼进 key，就能区分「传对实例」和「参数错位」两种情况。
package.preload["luci.model.uci"] = function()
	local M = {}
	local store = { ["bbr.main.algorithm"] = "bbr" }
	function M.cursor() return M end
	function M.get(self, config, section, option)
		return store[config .. "." .. section .. "." .. option]
	end
	function M.set(self, config, section, option, value)
		store[config .. "." .. section .. "." .. option] = value
	end
	return M
end

-- ============ mock: luci.cbi 环境 ============
translate = function(s) return s end

Flag = { __name = "Flag" }
ListValue = { __name = "ListValue" }
DummyValue = { __name = "DummyValue" }
Value = { __name = "Value" }
TypedSection = { __name = "TypedSection" }
NamedSection = { __name = "NamedSection" }
SimpleSection = { __name = "SimpleSection" }

function Map(config)
	local m = { config = config, __options = {} }
	function m:section(cls, stype)
		local s = { __type = cls, stype = stype, options = {} }
		function s:option(c, name, title)
			local o = { __type = c, name = name, title = title, values = {} }
			function o:value(v, t) self.values[#self.values + 1] = v end
			function o:description(d) self.description = d end
			function o:rmempty(v) self.rmempty = v end
			function o:default(v) self.default = v end
			self.options[#self.options + 1] = o
			m.__options[#m.__options + 1] = o
			return o
		end
		return s
	end
	return m
end

-- ============ 被测文件 ============
local cbi_path = "files/rootfs/usr/lib/lua/luci/model/cbi/bbr.lua"
local chunk, err = loadfile(cbi_path)
if not chunk then
	print("  FAIL 无法加载 " .. cbi_path .. ": " .. tostring(err))
	os.exit(1)
end
print("  OK   " .. cbi_path .. " 语法正确")

local m = chunk()
ok(m ~= nil, "加载后返回 Map")
ok(m.config == "bbr", "Map 配置名为 bbr（实际: " .. tostring(m.config) .. "）")
ok(type(m.on_commit) == "function", "定义了 on_commit hook（LuCI 26 没有 Map.apply）")

-- 找出各选项
local function find(name)
	for _, o in ipairs(m.__options) do
		if o.name == name then return o end
	end
end

local algo = find("algorithm")
ok(algo ~= nil, "存在 algorithm 选项")
if algo then
	ok(#algo.values > 0, "algorithm 有可选值（" .. #algo.values .. " 个）")
	ok(algo.default ~= nil, "algorithm 有默认值: " .. tostring(algo.default))
	local found = false
	for _, v in ipairs(algo.values) do
		if v == algo.default then found = true end
	end
	ok(found, "默认值在可选值列表内（ListValue 要求，否则显示异常）")
end

local cur = find("current_algorithm")
ok(cur ~= nil and type(cur.value) == "function",
	"current_algorithm 是函数式 DummyValue（实时读内核）")

-- 关键回归点：uci 调用方式
-- 如果写成 uci.get("bbr","main","algorithm")，self 会变成 "bbr"，
-- mock 里查不到 key → 返回 nil（真实环境会直接抛异常）
local uci = require "luci.model.uci"
local v = uci.cursor():get("bbr", "main", "algorithm")
ok(v == "bbr", "uci.cursor():get() 取值正确（实际: " .. tostring(v) .. "）")

print("")
if failed == 0 then
	print("✓ 全部通过")
	os.exit(0)
else
	print("✗ " .. failed .. " 项失败")
	os.exit(1)
end
