--[[
	Cosmetics — что игрок носит: оболочка шара, ленты, след (видят все).
	По умолчанию — сразу, не дожидаясь профиля (DataStore может грузиться 10 с);
	когда профиль загрузился или что-то купили/надели — refresh перекрашивает шар.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Catalog = require(Shared.Catalog)
local Profile = require(Shared.Profile)

local Data = require(script.Parent.DataService)
local Monetization = require(script.Parent.Monetization)

local Cosmetics = {}

local listeners: { (Player) -> () } = {}

function Cosmetics.effective(player: Player, kind: string): string
	local d = Data.get(player)
	if not d then
		return Catalog.Default[kind]
	end
	return Profile.effective(d, kind, Monetization.hasPass(player, "Vip"))
end

function Cosmetics.styleOf(player: Player): { balloon: string, ribbon: string, trail: string }
	return {
		balloon = Cosmetics.effective(player, "balloon"),
		ribbon = Cosmetics.effective(player, "ribbon"),
		trail = Cosmetics.effective(player, "trail"),
	}
end

function Cosmetics.onChange(fn: (Player) -> ())
	table.insert(listeners, fn)
end

function Cosmetics.refresh(player: Player)
	local style = Cosmetics.styleOf(player)
	player:SetAttribute("Balloon", style.balloon)
	for _, fn in listeners do
		task.spawn(fn, player)
	end
end

function Cosmetics.start()
	Data.onLoaded(function(player)
		Cosmetics.refresh(player)
	end)
	Monetization.onPass(function(player, key)
		if key == "Vip" then
			Cosmetics.refresh(player)
		end
	end)
	Players.PlayerAdded:Connect(function(player)
		player:SetAttribute("Balloon", Catalog.Default.balloon)
	end)
end

return Cosmetics
