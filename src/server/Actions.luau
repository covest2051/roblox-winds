--[[
	Actions — запросы клиента (ClientAction). Всё проверяется на сервере:
	типы аргументов, владение, цены, частота запросов.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Catalog = require(Shared.Catalog)
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local Parcel = require(Shared.Parcel)
local Profile = require(Shared.Profile)
local Winds = require(Shared.Winds)
local World = require(Shared.World)

local Data = require(script.Parent.DataService)
local Monetization = require(script.Parent.Monetization)
local Cosmetics = require(script.Parent.Cosmetics)
local FlightService = require(script.Parent.FlightService)
local RaceService = require(script.Parent.RaceService)
local DeliveryService = require(script.Parent.DeliveryService)

local Actions = {}

Actions.selfTest = nil :: (() -> { string })?

local budget: { [Player]: { n: number, t: number } } = {}
local function allowed(player: Player): boolean
	local b = budget[player]
	local t = os.clock()
	if not b or t - b.t > 1 then
		budget[player] = { n = 1, t = t }
		return true
	end
	b.n += 1
	return b.n <= 30
end

local function toast(player: Player, key: string, vars: { [string]: any }?)
	Net.ServerEvent:FireClient(player, { t = "toast", key = key, vars = vars })
end

local handlers = {}

handlers.profile = function(player: Player)
	Monetization.sendProfile(player)
end

handlers.ctl = function(player: Player, payload)
	local v = payload.v
	if type(v) == "number" then
		FlightService.setCtl(player, v)
	end
end

handlers.optIn = function(player: Player, payload)
	RaceService.setOptIn(player, payload.on == true)
end

handlers.skipOrder = function(player: Player, payload)
	DeliveryService.skip(player, if type(payload.i) == "number" then payload.i else 1)
end

handlers.orders = function(player: Player)
	DeliveryService.assign(player)
	Net.ServerEvent:FireClient(player, { t = "orders", list = DeliveryService.ordersOf(player) })
end

handlers.buyCoins = function(player: Player, payload)
	local id = payload.id
	if type(id) ~= "string" then
		return
	end
	local d = Data.get(player)
	if not d then
		return
	end
	local ok, err = Profile.buyWithCoins(d, id)
	if ok then
		Data.changed(player)
		Profile.equip(d, id, Monetization.hasPass(player, "Vip"))
		Cosmetics.refresh(player)
		toast(player, "shop.bought", { item = "item." .. id })
	else
		toast(player, err or "shop.error")
	end
	Monetization.sendProfile(player)
end

handlers.equip = function(player: Player, payload)
	local id = payload.id
	if type(id) ~= "string" or not Catalog.get(id) then
		return
	end
	local d = Data.get(player)
	if d and Profile.equip(d, id, Monetization.hasPass(player, "Vip")) then
		Data.changed(player)
		Cosmetics.refresh(player)
	end
	Monetization.sendProfile(player)
end

handlers.pass = function(player: Player, payload)
	if type(payload.key) == "string" and Config.Passes[payload.key] then
		Monetization.promptPass(player, payload.key)
	end
end

handlers.product = function(player: Player, payload)
	local key = payload.key
	if type(key) ~= "string" or not Config.Products[key] then
		return
	end
	local item = if type(payload.item) == "string" then payload.item else nil
	Monetization.promptProduct(player, key, item)
end

-- Отладка (только Studio)
local function debugCmd(player: Player, cmd: string, arg: any): string?
	if cmd == "coins" then
		local d = Data.get(player)
		if d then
			Profile.addCoins(d, tonumber(arg) or 1000)
			Data.changed(player)
			Monetization.sendProfile(player)
			return "coins " .. d.coins
		end
	elseif cmd == "reset" then
		local d = Data.get(player)
		if d then
			local fresh = Profile.new()
			for k, v in fresh do
				(d :: any)[k] = v
			end
			Data.changed(player)
			Cosmetics.refresh(player)
			Monetization.sendProfile(player)
			return "profile reset"
		end
	elseif cmd == "race" then
		if RaceService.phase() == "race" then
			return "race already running"
		end
		RaceService.setOptIn(player, true)
		return if RaceService.start() then "race started" else "no racers"
	elseif cmd == "stop" then
		RaceService.stop()
		return "race stopped"
	elseif cmd == "cp" then
		return RaceService.debugNext(player)
	elseif cmd == "finish" then
		local st = RaceService.state()
		if not st then
			return "no race"
		end
		local cps = st.course.checkpoints
		local c = cps[#cps]
		local e = st.entrants[player.UserId]
		if e then
			e.cp = #cps - 1
		end
		FlightService.teleport(player, c.x, Winds.mid(FlightService.winds, 2), c.z, nil)
		return "→ finish"
	elseif cmd == "splash" then
		local x, _, z = FlightService.position(player)
		if not x then
			return nil
		end
		-- ближайшее море по спирали
		for i = 1, 60 do
			local a = i * 0.9
			local r = 60 + i * 12
			local sx, sz = x + math.cos(a) * r, (z :: number) + math.sin(a) * r
			local _, kind = World.groundAt(FlightService.world, sx, sz)
			if kind == "water" then
				FlightService.teleport(player, sx, 0.5, sz, nil)
				return "splash"
			end
		end
		return "no sea nearby"
	elseif cmd == "order" then
		local list = DeliveryService.ordersOf(player)
		local o = list[1]
		if not o then
			DeliveryService.assign(player)
			return "order assigned"
		end
		local y = o.roof + 60
		local dx, dz = Parcel.drift(FlightService.winds, y, o.roof)
		FlightService.teleport(player, o.x - dx, y, o.z - dz, nil)
		return "→ above the order"
	elseif cmd == "winds" then
		RaceService.setWinds(math.random(1, 2 ^ 30))
		return "new winds"
	elseif cmd == "high" then
		local x, _, z = FlightService.position(player)
		if x then
			FlightService.teleport(player, x, Config.Wind.Ceiling - 10, z :: number, nil)
		end
		return "→ ceiling"
	elseif cmd == "harbor" then
		FlightService.teleport(player, 0, Config.World.HarborTop, 0, nil)
		return "→ harbor"
	elseif cmd == "selftest" then
		local fn = Actions.selfTest
		if fn then
			task.spawn(function()
				Net.ServerEvent:FireClient(player, { t = "selftest", lines = fn() })
			end)
		end
		return nil
	end
	return "unknown " .. tostring(cmd)
end

handlers.debug = function(player: Player, payload)
	if not RunService:IsStudio() then
		return
	end
	local msg = debugCmd(player, tostring(payload.cmd), payload.arg)
	if msg then
		toast(player, "debug.msg", { text = msg })
	end
end

function Actions.start()
	Net.ClientAction.OnServerEvent:Connect(function(player: Player, payload)
		if type(payload) ~= "table" or type(payload.t) ~= "string" then
			return
		end
		local h = handlers[payload.t]
		if not h or not allowed(player) then
			return
		end
		local ok, err = pcall(h, player, payload)
		if not ok then
			warn("[Actions]", payload.t, err)
		end
	end)
	Players.PlayerRemoving:Connect(function(p)
		budget[p] = nil
	end)
	-- Studio: команды из Command Bar / Studio MCP (execute_luau) без require:
	--   workspace:SetAttribute("DebugCommand", "race")  -- race | stop | cp | finish | splash | order |
	--                                                   -- winds | high | harbor | coins | reset | selftest
	if RunService:IsStudio() then
		Workspace:GetAttributeChangedSignal("DebugCommand"):Connect(function()
			local cmd = Workspace:GetAttribute("DebugCommand")
			local player = Players:GetPlayers()[1]
			if type(cmd) ~= "string" or cmd == "" or not player then
				return
			end
			Workspace:SetAttribute("DebugCommand", "")
			print("[Debug]", cmd)
			local msg = debugCmd(player, cmd, nil)
			if msg then
				print("[Debug]", msg)
				toast(player, "debug.msg", { text = msg })
			end
		end)
	end
end

return Actions
