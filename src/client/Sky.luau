--[[
	Sky — мир и ветра на клиенте. Сервер публикует только seed (атрибуты Workspace
	WorldSeed и WindSeed); клиент сам строит ту же модель (shared/World, shared/Winds).
	Если атрибут ещё не пришёл — nil, и интерфейс просто ждёт.
]]

local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local World = require(Shared.World)
local Winds = require(Shared.Winds)

local Sky = {}

local worldSeed, worldCache = nil, nil
local windSeed, windCache = nil, nil
local listeners: { () -> () } = {}

function Sky.world()
	local s = Workspace:GetAttribute("WorldSeed")
	if type(s) ~= "number" then
		return nil
	end
	if s ~= worldSeed then
		worldSeed = s
		worldCache = World.generate(s)
	end
	return worldCache
end

function Sky.winds()
	local s = Workspace:GetAttribute("WindSeed")
	if type(s) ~= "number" then
		return nil
	end
	if s ~= windSeed then
		windSeed = s
		windCache = Winds.generate(s)
		for _, fn in listeners do
			task.spawn(fn)
		end
	end
	return windCache
end

-- Ветер сменился (новая гонка)
function Sky.onWinds(fn: () -> ())
	table.insert(listeners, fn)
end

function Sky.start()
	Workspace:GetAttributeChangedSignal("WindSeed"):Connect(function()
		Sky.winds()
	end)
end

return Sky
