--[[
	Loader — загружает модули из src/shared в Lune так, как их видит Roblox
	после Rojo: `script`, `script.Parent.X`, `require(instance)`,
	`game:GetService("ReplicatedStorage").Shared`.
	Никаких изменений в игровом коде ради тестов не нужно.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

local Loader = {}

local NodeMethods = {}
local NodeMeta = {}

local function newNode(name: string, parent, path: string?)
	local node = setmetatable({ __name = name, __children = {}, __parent = parent, __path = path }, NodeMeta)
	if parent then
		parent.__children[name] = node
	end
	return node
end

NodeMeta.__index = function(self, key)
	if key == "Name" then
		return rawget(self, "__name")
	elseif key == "Parent" then
		return rawget(self, "__parent")
	end
	local m = NodeMethods[key]
	if m then
		return m
	end
	local child = rawget(self, "__children")[key]
	if child then
		return child
	end
	error(string.format("%s is not a valid member of %s", tostring(key), rawget(self, "__name")), 2)
end
NodeMeta.__tostring = function(self)
	return rawget(self, "__name")
end

function NodeMethods.WaitForChild(self, name)
	return rawget(self, "__children")[name] or error("WaitForChild: no child " .. name)
end
function NodeMethods.FindFirstChild(self, name)
	return rawget(self, "__children")[name]
end
function NodeMethods.GetChildren(self)
	local out = {}
	for _, c in rawget(self, "__children") do
		table.insert(out, c)
	end
	return out
end
function NodeMethods.IsA(_self, className)
	return className == "ModuleScript" or className == "Instance"
end

local function stripExt(file: string): string?
	if string.sub(file, -5) == ".luau" then
		local base = string.sub(file, 1, -6)
		if string.find(base, "%.server$") or string.find(base, "%.client$") then
			return nil
		end
		return base
	end
	return nil
end

local function mapDir(dir: string, node)
	for _, entry in fs.readDir(dir) do
		local full = dir .. "/" .. entry
		if fs.isDir(full) then
			local child = newNode(entry, node, nil)
			if fs.isFile(full .. "/init.luau") then
				rawset(child, "__path", full .. "/init.luau")
			end
			mapDir(full, child)
		else
			local base = stripExt(entry)
			if base and base ~= "init" then
				newNode(base, node, full)
			end
		end
	end
end

local cache = {}
local loading = {}

local replicatedStorage = newNode("ReplicatedStorage", nil, nil)
local fakeGame = {}
function fakeGame.GetService(_self, name)
	if name == "ReplicatedStorage" then
		return replicatedStorage
	end
	error("Service " .. tostring(name) .. " is not available in Lune tests (keep shared modules pure)")
end

local function rbxRequire(node)
	if type(node) == "string" then
		return require(node)
	end
	if cache[node] ~= nil then
		return cache[node]
	end
	local path = rawget(node, "__path")
	assert(path, "require: " .. tostring(node) .. " is not a module")
	assert(not loading[node], "require cycle at " .. path)
	loading[node] = true
	local source = fs.readFile(path)
	local env = {
		script = node,
		require = rbxRequire,
		game = fakeGame,
		Vector3 = roblox.Vector3,
		Vector2 = roblox.Vector2,
		CFrame = roblox.CFrame,
		Color3 = roblox.Color3,
		Enum = roblox.Enum,
	}
	local fn = luau.load(source, { debugName = path, environment = env })
	local result = fn()
	loading[node] = nil
	cache[node] = result
	return result
end

local shared = newNode("Shared", replicatedStorage, nil)
mapDir("src/shared", shared)

Loader.Shared = shared
Loader.require = rbxRequire

-- Удобный доступ: Loader.shared("Heat")
function Loader.shared(name: string)
	return rbxRequire(shared[name])
end

return Loader
