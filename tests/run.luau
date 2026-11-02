--[[
	Запуск всех тестов: `lune run tests/run.luau` из корня репозитория.
	Тестовый файл: tests/*.spec.luau, возвращает function(t).
]]

local fs = require("@lune/fs")
local process = require("@lune/process")

local Loader = require("./lib/Loader")

local filter = process.args[1]

local passed, failed = 0, 0
local failures = {}

local function fmt(v)
	if type(v) == "string" then
		return string.format("%q", v)
	end
	return tostring(v)
end

local function makeT(fileName)
	local t = {}
	t.shared = Loader.shared
	function t.test(name, fn)
		if filter and not string.find(fileName .. " " .. name, filter, 1, true) then
			return
		end
		local ok, err = pcall(fn)
		if ok then
			passed += 1
		else
			failed += 1
			table.insert(failures, string.format("  ✗ %s › %s\n      %s", fileName, name, tostring(err)))
		end
	end
	function t.ok(cond, msg)
		if not cond then
			error(msg or "expected truthy", 2)
		end
	end
	function t.eq(a, b, msg)
		if a ~= b then
			error(string.format("%sexpected %s, got %s", msg and (msg .. ": ") or "", fmt(b), fmt(a)), 2)
		end
	end
	function t.near(a, b, eps, msg)
		if math.abs(a - b) > (eps or 1e-6) then
			error(string.format("%sexpected ≈%s, got %s", msg and (msg .. ": ") or "", fmt(b), fmt(a)), 2)
		end
	end
	function t.lt(a, b, msg)
		if not (a < b) then
			error(string.format("%sexpected %s < %s", msg and (msg .. ": ") or "", fmt(a), fmt(b)), 2)
		end
	end
	return t
end

local files = {}
for _, f in fs.readDir("tests") do
	if string.find(f, "%.spec%.luau$") then
		table.insert(files, f)
	end
end
table.sort(files)

for _, f in files do
	local spec = require("./" .. string.sub(f, 1, -6))
	spec(makeT(f))
end

for _, line in failures do
	print(line)
end
print(string.format("\n%d passed, %d failed", passed, failed))
process.exit(if failed > 0 then 1 else 0)
