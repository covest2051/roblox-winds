--[[
	FlightService — шары игроков на сервере.
	  • Персонаж появился → строим шар на поле гавани, сажаем персонажа в корзину,
	    сетевой владелец корзины — игрок: летает его клиент (Flight → LinearVelocity), без задержки.
	  • Сервер читает позицию корзины, проверяет скорость (телепорт/спидхак → назад),
	    ловит «намок» (вода) и замораживает шар (Anchored) на время отсчёта или после воды.
	  • Ctl (горелка/клапан) — атрибут модели: пламя видят все.
	Шары не сталкиваются друг с другом (группа столкновений Balloons).
]]

local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Flight = require(Shared.Flight)
local Make = require(Shared.Make)
local Net = require(Shared.Net)
local Winds = require(Shared.Winds)
local World = require(Shared.World)

local BalloonBuilder = require(script.Parent.BalloonBuilder)
local Cosmetics = require(script.Parent.Cosmetics)
local Monetization = require(script.Parent.Monetization)
local WorldBuilder = require(script.Parent.WorldBuilder)

local FlightService = {}

local F = Config.Flight
local GROUP = "Balloons"

type Entry = {
	model: Model,
	root: BasePart,
	seat: Seat?,
	valid: { x: number, y: number, z: number, t: number },
	grace: number,
	frozenUntil: number,
	strikes: number,
	splashing: boolean,
	pending: { at: number, x: number, y: number, z: number, freeze: number }?,
}

local entries: { [Player]: Entry } = {}
local spawnIndex = 0
local folder: Folder? = nil

FlightService.world = nil :: any
FlightService.winds = nil :: any
-- Гонка решает, что делать с «намок» (вернуть к чекпоинту). true — обработано.
FlightService.onSplash = nil :: ((Player) -> boolean)?
-- Куда ставить шар при появлении персонажа (гонка может вернуть свою точку)
FlightService.spawnFor = nil :: ((Player) -> (number?, number?, number?))?
-- Шар построен (доставка выдаёт заказ)
FlightService.onSpawned = nil :: ((Player) -> ())?

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function send(player: Player, payload)
	if player.Parent then
		Net.ServerEvent:FireClient(player, payload)
	end
end

local function setupGroups()
	pcall(function()
		if not PhysicsService:IsCollisionGroupRegistered(GROUP) then
			PhysicsService:RegisterCollisionGroup(GROUP)
		end
		PhysicsService:CollisionGroupSetCollidable(GROUP, GROUP, false)
	end)
end

local function setGroup(inst: Instance)
	for _, d in inst:GetDescendants() do
		if d:IsA("BasePart") then
			d.CollisionGroup = GROUP
		end
	end
	if inst:IsA("BasePart") then
		inst.CollisionGroup = GROUP
	end
end
FlightService.setGroup = setGroup

function FlightService.folder(): Folder
	if not folder or not folder.Parent then
		folder = Workspace:FindFirstChild("Balloons") :: Folder?
			or Make("Folder", { Name = "Balloons", Parent = Workspace })
	end
	return folder :: Folder
end

function FlightService.balloonOf(player: Player): Model?
	local e = entries[player]
	return e and e.model
end

-- Позиция шара (низ корзины)
function FlightService.position(player: Player): (number?, number?, number?)
	local e = entries[player]
	if not e or not e.root.Parent then
		return nil, nil, nil
	end
	local p = e.root.CFrame.Position
	return p.X, p.Y - F.RootH, p.Z
end

function FlightService.isFrozen(player: Player): boolean
	local e = entries[player]
	return e ~= nil and now() < e.frozenUntil
end

local function giveOwnership(player: Player, e: Entry)
	if e.root.Anchored then
		return
	end
	pcall(function()
		e.root:SetNetworkOwner(player)
	end)
end

local function unfreeze(player: Player, e: Entry)
	e.root.Anchored = false
	e.model:SetAttribute("Frozen", nil)
	giveOwnership(player, e)
end

-- Заморозить шар на seconds (отсчёт, «намок»). 0 — разморозить сразу.
function FlightService.freeze(player: Player, seconds: number)
	local e = entries[player]
	if not e then
		return
	end
	local untilT = now() + seconds
	e.frozenUntil = untilT
	if seconds <= 0 then
		unfreeze(player, e)
		return
	end
	-- разморозка — в step() по серверному времени (не task.delay: одно время с логикой)
	e.root.Anchored = true
	e.root.AssemblyLinearVelocity = Vector3.zero
	e.model:SetAttribute("Frozen", untilT)
end

-- Переставить шар через delay секунд (после «намок»)
function FlightService.teleportLater(
	player: Player,
	delay: number,
	x: number,
	y: number,
	z: number,
	freeze: number
)
	local e = entries[player]
	if e then
		e.pending = { at = now() + delay, x = x, y = y, z = z, freeze = freeze }
	end
end

-- Переставить шар (низ корзины в x, y, z). freeze — заморозить на столько секунд.
function FlightService.teleport(player: Player, x: number, y: number, z: number, freeze: number?)
	local e = entries[player]
	if not e then
		return
	end
	local cf = CFrame.new(x, y + F.RootH, z)
	e.model:PivotTo(cf)
	e.root.AssemblyLinearVelocity = Vector3.zero
	e.valid = { x = x, y = y, z = z, t = now() }
	e.grace = now() + 1
	e.splashing = false
	e.pending = nil
	send(player, { t = "teleport", x = x, y = y, z = z })
	if freeze and freeze > 0 then
		FlightService.freeze(player, freeze)
	end
end

function FlightService.setCtl(player: Player, v: number)
	local e = entries[player]
	if e then
		e.model:SetAttribute("Ctl", math.clamp(math.round(v), -1, 1))
	end
end

function FlightService.restyle(player: Player)
	local e = entries[player]
	if e then
		BalloonBuilder.restyle(e.model, Cosmetics.styleOf(player))
		BalloonBuilder.setVip(e.model, Monetization.hasPass(player, "Vip"), player.DisplayName)
		setGroup(e.model)
	end
end

local function seatCharacter(player: Player, e: Entry)
	local character = player.Character
	local hum = character and character:FindFirstChildOfClass("Humanoid")
	local seat = e.seat
	if not character or not hum or not seat then
		return
	end
	character:PivotTo(seat.CFrame * CFrame.new(0, 2.5, 0))
	pcall(function()
		seat:Sit(hum)
	end)
end

local function destroyBalloon(player: Player)
	local e = entries[player]
	if e then
		entries[player] = nil
		e.model:Destroy()
	end
end

function FlightService.spawn(player: Player)
	local character = player.Character
	if not character then
		return
	end
	local hum = character:WaitForChild("Humanoid", 10) :: Humanoid?
	if not hum or player.Character ~= character then
		return
	end
	destroyBalloon(player)
	local x, y, z
	if FlightService.spawnFor then
		x, y, z = FlightService.spawnFor(player)
	end
	if not x then
		spawnIndex += 1
		x, y, z = WorldBuilder.spawnPoint(FlightService.world, spawnIndex)
	end
	local cf = CFrame.new(x :: number, (y :: number) + F.RootH, z :: number)
	local model = BalloonBuilder.build(Cosmetics.styleOf(player), {
		name = player.DisplayName,
		anchored = false,
		cf = cf,
		owner = player.UserId,
		vip = Monetization.hasPass(player, "Vip"),
	})
	model.Name = "Balloon_" .. player.UserId
	setGroup(model)
	model.Parent = FlightService.folder()
	local e: Entry = {
		model = model,
		root = model.PrimaryPart :: BasePart,
		seat = model:FindFirstChild("Seat") :: Seat?,
		valid = { x = x :: number, y = y :: number, z = z :: number, t = now() },
		grace = now() + 2,
		frozenUntil = 0,
		strikes = 0,
		splashing = false,
		pending = nil,
	}
	entries[player] = e
	hum.JumpHeight = 0
	hum.UseJumpPower = false
	setGroup(character)
	seatCharacter(player, e)
	giveOwnership(player, e)
	player:SetAttribute("BalloonReady", true)
	-- если персонажа выбросило из корзины — посадить обратно
	local seat = e.seat
	if seat then
		seat:GetPropertyChangedSignal("Occupant"):Connect(function()
			if seat.Occupant == nil and entries[player] == e then
				task.delay(0.5, function()
					if entries[player] == e and seat.Occupant == nil then
						seatCharacter(player, e)
					end
				end)
			end
		end)
	end
	send(player, { t = "balloon", name = model.Name })
	if FlightService.onSpawned then
		task.spawn(FlightService.onSpawned, player)
	end
end

local function splash(player: Player, e: Entry)
	if e.splashing then
		return
	end
	e.splashing = true
	local x, _, z = FlightService.position(player)
	send(player, { t = "splash", time = F.SplashTime })
	local handled = false
	if FlightService.onSplash then
		handled = FlightService.onSplash(player)
	end
	if not handled then
		-- свободный полёт: там же, в середине нижнего слоя
		FlightService.freeze(player, F.SplashTime)
		local y = Winds.mid(FlightService.winds, 1)
		FlightService.teleportLater(
			player,
			F.SplashTime * 0.6,
			x :: number,
			y,
			z :: number,
			F.SplashTime * 0.4
		)
	end
end

local validateAcc = 0
-- Проверка скорости и воды. Вызывается из общего шага сервера.
function FlightService.step(dt: number)
	validateAcc += dt
	local check = validateAcc >= Config.Timing.Validate
	if check then
		validateAcc = 0
	end
	local t = now()
	local maxH, maxV = Flight.maxSpeed()
	for player, e in entries do
		if not e.root.Parent then
			continue
		end
		-- отложенные перенос и разморозка
		local pend = e.pending
		if pend and t >= pend.at then
			e.pending = nil
			FlightService.teleport(player, pend.x, pend.y, pend.z, nil)
			FlightService.freeze(player, pend.freeze)
		end
		if e.root.Anchored and e.frozenUntil > 0 and t >= e.frozenUntil then
			unfreeze(player, e)
		end
		local x, y, z = FlightService.position(player)
		if not x then
			continue
		end
		-- вода
		local g, kind = World.groundAt(FlightService.world, x :: number, z :: number)
		if kind == "water" and (y :: number) <= g + F.SplashH and t >= e.frozenUntil and t >= e.grace then
			splash(player, e)
			continue
		end
		if not check then
			continue
		end
		local v = e.valid
		local el = math.max(t - v.t, 0.05)
		if t < e.grace or t < e.frozenUntil then
			e.valid = { x = x :: number, y = y :: number, z = z :: number, t = t }
			continue
		end
		local dh = math.sqrt(((x :: number) - v.x) ^ 2 + ((z :: number) - v.z) ^ 2)
		local dv = math.abs((y :: number) - v.y)
		local okH = dh <= (maxH * F.SpeedSlack + F.SpeedPad) * el + 2
		local okV = dv <= (maxV * F.SpeedSlack + F.SpeedPad) * el + 2
		if okH and okV then
			e.valid = { x = x :: number, y = y :: number, z = z :: number, t = t }
		else
			e.strikes += 1
			warn(
				string.format(
					"[Flight] %s moved too fast (%.0f/%.0f studs in %.2fs) — reset",
					player.Name,
					dh,
					dv,
					el
				)
			)
			FlightService.teleport(player, v.x, v.y, v.z, nil)
		end
	end
end

function FlightService.start()
	setupGroups()
	FlightService.folder()
	local function added(player: Player)
		player.CharacterAdded:Connect(function()
			FlightService.spawn(player)
		end)
		if player.Character then
			task.spawn(FlightService.spawn, player)
		end
	end
	Players.PlayerAdded:Connect(added)
	for _, p in Players:GetPlayers() do
		added(p)
	end
	Players.PlayerRemoving:Connect(destroyBalloon)
	Cosmetics.onChange(FlightService.restyle)
end

return FlightService
