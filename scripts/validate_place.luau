--[[
	Проверка собранного place-файла (после `rojo build -o build/game.rbxl`):
	  • все скрипты компилируются;
	  • все require(script.X / script.Parent.X / Shared.X) указывают на существующие модули;
	  • есть ключевые инстансы (Remotes, Server, Client).
	Запуск: lune run scripts/validate_place.luau [build/game.rbxl]
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local process = require("@lune/process")

local path = process.args[1] or "build/game.rbxl"
local game = roblox.deserializePlace(fs.readFile(path))

local errors = {}
local function fail(msg)
	table.insert(errors, msg)
end

local RS = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")
local SP = game:GetService("StarterPlayer")

local shared = RS:FindFirstChild("Shared")
local remotes = RS:FindFirstChild("Remotes")
if not shared then
	fail("ReplicatedStorage.Shared missing")
end
if not remotes or not remotes:FindFirstChild("ClientAction") or not remotes:FindFirstChild("ServerEvent") then
	fail("Remotes missing")
end
local server = SSS:FindFirstChild("Server")
if not server or server.ClassName ~= "Script" then
	fail("ServerScriptService.Server must be a Script")
end
local sps = SP:FindFirstChild("StarterPlayerScripts")
local client = sps and sps:FindFirstChild("Client")
if not client or client.ClassName ~= "LocalScript" then
	fail("StarterPlayerScripts.Client must be a LocalScript")
end

local function fullName(inst)
	local parts = {}
	local cur = inst
	while cur and cur ~= game do
		table.insert(parts, 1, cur.Name)
		cur = cur.Parent
	end
	return table.concat(parts, ".")
end

local function resolve(script, expr)
	-- expr: "script.A.B" | "script.Parent.A" | "Shared.A"
	local segs = string.split(expr, ".")
	local cur
	if segs[1] == "script" then
		cur = script
	elseif segs[1] == "Shared" then
		cur = shared
	else
		return true -- не наш шаблон, пропускаем
	end
	for i = 2, #segs do
		local s = segs[i]
		if s == "Parent" then
			cur = cur.Parent
		else
			cur = cur and cur:FindFirstChild(s)
		end
		if not cur then
			return false
		end
	end
	return cur.ClassName == "ModuleScript"
end

local count = 0
for _, inst in game:GetDescendants() do
	if inst.ClassName == "Script" or inst.ClassName == "LocalScript" or inst.ClassName == "ModuleScript" then
		count += 1
		local src = inst.Source
		local ok, err = pcall(luau.compile, src)
		if not ok then
			fail(fullName(inst) .. ": compile error: " .. tostring(err))
		end
		for expr in string.gmatch(src, "require%(([%w_%.]+)%)") do
			if not resolve(inst, expr) then
				fail(string.format("%s: require(%s) does not resolve", fullName(inst), expr))
			end
		end
	end
end

if #errors > 0 then
	for _, e in errors do
		print("✗ " .. e)
	end
	process.exit(1)
end
print(string.format("place OK: %d scripts compiled, requires resolved", count))
