--[[
	DeliveryService — доставка посылок в свободном полёте.
	  • У игрока 1 заказ (2 с геймпассом «Грузовая корзина»): крыша дома на другом острове.
	  • Каждый шаг сервер считает, куда упадёт посылка, если сбросить её сейчас (shared/Parcel);
	    как только метка на крыше — посылка сброшена (третья кнопка не нужна).
	  • Посылка падает с парашютом по той же траектории; на крыше — монеты и новый заказ.
	Во время гонки заказы участников на паузе.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Delivery = require(Shared.Delivery)
local Make = require(Shared.Make)
local Net = require(Shared.Net)
local Parcel = require(Shared.Parcel)
local Profile = require(Shared.Profile)
local Rewards = require(Shared.Rewards)

local Data = require(script.Parent.DataService)
local FlightService = require(script.Parent.FlightService)
local Monetization = require(script.Parent.Monetization)
local RaceService = require(script.Parent.RaceService)

local DeliveryService = {}

type Falling = {
	part: BasePart,
	chute: BasePart,
	path: { Vector3 },
	landing: Vector3,
	t0: number,
	dur: number,
	done: (() -> ())?,
}

local orders: { [Player]: { Delivery.Order } } = {}
local lastHouse: { [Player]: number } = {}
local skipAt: { [Player]: number } = {}
local falling: { Falling } = {}
local assignAt: { [Player]: number } = {}
local rng = Random.new()
local world = nil

local SKIP_COOLDOWN = 8

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function send(player: Player, payload)
	if player.Parent then
		Net.ServerEvent:FireClient(player, payload)
	end
end

function DeliveryService.capacity(player: Player): number
	return if Monetization.hasPass(player, "Cargo") then 2 else 1
end

function DeliveryService.ordersOf(player: Player): { Delivery.Order }
	return orders[player] or {}
end

local function sendOrders(player: Player)
	local list = {}
	for _, o in orders[player] or {} do
		table.insert(
			list,
			{ house = o.house, x = o.x, z = o.z, roof = o.roof, dist = o.dist, par = o.par, t0 = o.t0 }
		)
	end
	player:SetAttribute("Parcels", #list)
	send(player, { t = "orders", list = list })
end

-- Добрать заказы до вместимости
function DeliveryService.assign(player: Player)
	if RaceService.inRace(player) then
		return
	end
	local x, _, z = FlightService.position(player)
	if not x then
		return
	end
	local list = orders[player] or {}
	orders[player] = list
	local changed = false
	while #list < DeliveryService.capacity(player) do
		local ex = {}
		for _, o in list do
			ex[o.house] = true
		end
		if lastHouse[player] then
			ex[lastHouse[player]] = true
		end
		local id = Delivery.pick(world, function(a, b)
			return rng:NextInteger(a, b)
		end, x, z :: number, ex)
		table.insert(list, Delivery.newOrder(world, id, x, z :: number, now()))
		changed = true
	end
	if changed then
		sendOrders(player)
	end
end

function DeliveryService.clear(player: Player)
	orders[player] = {}
	sendOrders(player)
end

-- Заменить заказ i на другой (кнопка «Другой заказ»)
function DeliveryService.skip(player: Player, i: number?)
	local list = orders[player]
	if not list or #list == 0 then
		return
	end
	if now() - (skipAt[player] or -100) < SKIP_COOLDOWN then
		send(player, { t = "toast", key = "order.skipWait" })
		return
	end
	skipAt[player] = now()
	local idx = math.clamp(i or 1, 1, #list)
	lastHouse[player] = list[idx].house
	table.remove(list, idx)
	DeliveryService.assign(player)
end

local function landed(player: Player, order: Delivery.Order, coins: number, fast: boolean)
	if not player.Parent then
		return
	end
	local d = Data.get(player)
	if d then
		Profile.earn(d, coins)
		Profile.recordDelivery(d)
		Data.changed(player)
	end
	send(player, {
		t = "delivered",
		coins = coins,
		fast = fast,
		house = order.house,
		total = if d then d.deliveries else 0,
	})
	Monetization.sendProfile(player)
end

local function drop(player: Player, idx: number, landing: Parcel.Landing, x: number, y: number, z: number)
	local list = orders[player]
	local order = table.remove(list, idx) :: Delivery.Order
	lastHouse[player] = order.house
	local elapsed = now() - order.t0
	local mult =
		Rewards.multiplier(Monetization.hasPass(player, "DoubleCoins"), Monetization.hasPass(player, "Vip"))
	local coins = Rewards.apply(Delivery.reward(order, elapsed), mult)
	local fast = elapsed <= order.par
	-- посылка с парашютом по предсказанной траектории
	local full = Parcel.predict(FlightService.winds, world, x, y, z, true, order.house)
	local path = {}
	for _, p in full.path or {} do
		table.insert(path, Vector3.new(p.x, p.y, p.z))
	end
	local landPos = Vector3.new(landing.x, landing.y, landing.z)
	local box = Make("Part", {
		Name = "Parcel",
		Size = Vector3.new(1.8, 1.4, 1.8),
		CFrame = CFrame.new(x, y, z),
		Color = Color3.fromRGB(200, 150, 90),
		Material = Enum.Material.Cardboard,
		Anchored = true,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		Parent = Workspace,
	})
	local chute = Make("Part", {
		Name = "Chute",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(5, 5, 5),
		CFrame = CFrame.new(x, y + 4, z),
		Color = Color3.fromRGB(255, 120, 90),
		Anchored = true,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		Parent = box,
	})
	send(player, { t = "dropped", house = order.house, time = landing.t })
	-- приземление — в heartbeat по серверному времени
	table.insert(falling, {
		part = box,
		chute = chute,
		path = path,
		landing = landPos,
		t0 = now(),
		dur = landing.t,
		done = function()
			landed(player, order, coins, fast)
			DeliveryService.assign(player)
		end,
	})
end

function DeliveryService.step(_dt: number)
	local winds = FlightService.winds
	local t = now()
	for player, at in assignAt do
		if t >= at then
			assignAt[player] = nil
			if player.Parent then
				DeliveryService.assign(player)
			end
		end
	end
	for player, list in orders do
		if #list == 0 or not player.Parent then
			continue
		end
		if RaceService.inRace(player) or FlightService.isFrozen(player) then
			continue
		end
		local x, y, z = FlightService.position(player)
		if not x then
			continue
		end
		for i, order in list do
			local ok, landing = Delivery.check(order, winds, world, x, y :: number, z :: number)
			if ok then
				drop(player, i, landing, x, y :: number, z :: number)
				break
			end
		end
	end
end

-- Каждый кадр: падение посылок
function DeliveryService.heartbeat(_dt: number)
	local t = now()
	for i = #falling, 1, -1 do
		local f = falling[i]
		local el = t - f.t0
		if el >= f.dur and f.done then
			local fn = f.done
			f.done = nil
			task.spawn(fn)
		end
		if el >= f.dur + 3 or not f.part.Parent then
			if f.part.Parent then
				f.part:Destroy()
			end
			table.remove(falling, i)
			continue
		end
		local pos
		if el >= f.dur then
			pos = f.landing + Vector3.new(0, 0.7, 0)
			f.chute.Transparency = math.clamp((el - f.dur) / 1.5, 0, 1)
		else
			local k = el / 0.5 + 1
			local a = f.path[math.floor(k)] or f.landing
			local b = f.path[math.floor(k) + 1] or f.landing
			pos = a:Lerp(b, k - math.floor(k)) + Vector3.new(0, 0.7, 0)
		end
		f.part.CFrame = CFrame.new(pos)
		f.chute.CFrame = CFrame.new(pos + Vector3.new(0, 4, 0))
	end
end

function DeliveryService.init(w)
	world = w
	Players.PlayerRemoving:Connect(function(p)
		orders[p] = nil
		assignAt[p] = nil
		lastHouse[p] = nil
		skipAt[p] = nil
	end)
	Monetization.onPass(function(player, key)
		if key == "Cargo" then
			DeliveryService.assign(player)
		end
	end)
	RaceService.onStarted = function(list)
		for _, p in list do
			DeliveryService.clear(p)
		end
	end
	RaceService.onEnded = function(list)
		for _, p in list do
			assignAt[p] = now() + Config.Race.Results * 0.5
		end
	end
end

return DeliveryService
