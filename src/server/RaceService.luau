--[[
	RaceService — гонки по расписанию:
	  свободный полёт (Intermission) → старт: новые ветра, трасса, все согласные игроки
	  на поле гавани + ИИ-соперники до FillTo → отсчёт (шары заморожены) → чекпоинты →
	  финиш → итоги и монеты → свободный полёт.
	Логика гонки — shared/Race (чистая модель); ИИ ведёт shared/Pilot (та же голова, что
	у ботов в тестах), тело ИИ — shared/Flight, модель шара двигает сервер.

	Атрибуты Workspace для клиентов: Phase (free | race | results), NextRace, RaceGo, WindSeed.
	Атрибуты игрока: RaceOptIn, Racing, Cp.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Flight = require(Shared.Flight)
local Net = require(Shared.Net)
local Pilot = require(Shared.Pilot)
local Profile = require(Shared.Profile)
local Race = require(Shared.Race)
local Rewards = require(Shared.Rewards)
local Winds = require(Shared.Winds)

local BalloonBuilder = require(script.Parent.BalloonBuilder)
local Catalog = require(Shared.Catalog)
local Data = require(script.Parent.DataService)
local FlightService = require(script.Parent.FlightService)
local Monetization = require(script.Parent.Monetization)
local WorldBuilder = require(script.Parent.WorldBuilder)

local RaceService = {}

local R = Config.Race
local RH = Config.Flight.RootH

type Ai = {
	id: string,
	name: string,
	model: Model,
	fl: Flight.State,
	mem: Pilot.Mem,
	prev: Vector3,
	cur: Vector3,
	ctl: number,
}

local phase = "free"
local nextRace = 0
local resultsUntil = 0
local race: Race.State? = nil
local humans: { [number]: Player } = {}
local ais: { [string]: Ai } = {}
local acc = 0
local standAcc = 0
local rng = Random.new()
local world = nil

RaceService.lastResults = nil :: any
-- кто-то закончил гонку (DeliveryService раздаёт заказы снова)
RaceService.onEnded = nil :: (({ Player }) -> ())?
RaceService.onStarted = nil :: (({ Player }) -> ())?

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function send(player: Player, payload)
	if player.Parent then
		Net.ServerEvent:FireClient(player, payload)
	end
end

local function sendRacers(payload)
	for _, p in humans do
		send(p, payload)
	end
end

local function setPhase(p: string)
	phase = p
	Workspace:SetAttribute("Phase", p)
end

function RaceService.phase(): string
	return phase
end

function RaceService.state(): Race.State?
	return race
end

function RaceService.setWinds(seed: number)
	local w = Winds.generate(seed)
	FlightService.winds = w
	Workspace:SetAttribute("WindSeed", seed)
	WorldBuilder.windMast(world, w)
	return w
end

function RaceService.schedule(delay: number)
	nextRace = now() + delay
	Workspace:SetAttribute("NextRace", nextRace)
end

-- Игрок участвует в идущей гонке (и ещё не финишировал)
function RaceService.inRace(player: Player): boolean
	local st = race
	if not st or phase ~= "race" then
		return false
	end
	local e = st.entrants[player.UserId]
	return e ~= nil and not e.left and humans[player.UserId] == player
end

function RaceService.setOptIn(player: Player, on: boolean)
	player:SetAttribute("RaceOptIn", on)
end

local function optedIn(player: Player): boolean
	return player:GetAttribute("RaceOptIn") ~= false
end

-------------------------------------------------------------------------------
-- Старт
-------------------------------------------------------------------------------
local function aiStyle(i: number)
	local balloons, trails = {}, {}
	for _, it in Catalog.Items do
		if it.rarity ~= "Vip" then
			if it.kind == "balloon" then
				table.insert(balloons, it.id)
			elseif it.kind == "trail" then
				table.insert(trails, it.id)
			end
		end
	end
	return {
		balloon = balloons[(i * 3) % #balloons + 1],
		ribbon = Catalog.Default.ribbon,
		trail = trails[(i * 2) % #trails + 1],
	}
end

function RaceService.start(): boolean
	if phase == "race" then
		return false
	end
	local list = {}
	for _, p in Players:GetPlayers() do
		if optedIn(p) and FlightService.balloonOf(p) then
			table.insert(list, p)
		end
	end
	if #list == 0 then
		RaceService.schedule(R.Intermission)
		return false
	end
	table.sort(list, function(a, b)
		return a.UserId < b.UserId
	end)
	local seed = rng:NextInteger(1, 2 ^ 30)
	local winds = RaceService.setWinds(rng:NextInteger(1, 2 ^ 30))
	local entrants = {}
	humans = {}
	for _, p in list do
		if #entrants >= R.Max then
			break
		end
		table.insert(entrants, { id = p.UserId, name = p.DisplayName, ai = false })
		humans[p.UserId] = p
	end
	local names = table.clone(Config.Ai.Names)
	for i = #names, 2, -1 do
		local j = rng:NextInteger(1, i)
		names[i], names[j] = names[j], names[i]
	end
	local aiCount = math.clamp(R.FillTo - #entrants, 0, R.Max - #entrants)
	for i = 1, aiCount do
		table.insert(entrants, { id = "ai" .. i, name = names[(i - 1) % #names + 1], ai = true })
	end
	local st = Race.new(seed, world, winds, entrants)
	race = st
	WorldBuilder.course(st.course, winds)
	local goAt = now() + R.Countdown
	Workspace:SetAttribute("RaceGo", goAt)
	Workspace:SetAttribute("RaceSeed", seed)
	-- игроки
	for _, p in humans do
		local x, y, z = Race.start(st, p.UserId)
		FlightService.teleport(p, x, y, z, R.Countdown)
		p:SetAttribute("Racing", true)
		p:SetAttribute("Cp", 0)
	end
	-- ИИ
	ais = {}
	for i, e in entrants do
		if e.ai then
			local x, y, z = Race.start(st, e.id)
			local model = BalloonBuilder.build(aiStyle(i), {
				name = e.name,
				anchored = true,
				cf = CFrame.new(x, y + RH, z),
				ai = true,
			})
			model.Name = "AI_" .. e.id
			FlightService.setGroup(model)
			model.Parent = FlightService.folder()
			local skill = if i % 2 == 0 then "pro" else "novice"
			local react = rng:NextNumber(Config.Ai.Reaction[1], Config.Ai.Reaction[2])
			local pos = Vector3.new(x, y + RH, z)
			ais[e.id] = {
				id = e.id,
				name = e.name,
				model = model,
				fl = Flight.new(x, y, z),
				mem = Pilot.new({
					skill = skill,
					reaction = react,
					think = if skill == "pro" then 0.5 else 1,
				}),
				prev = pos,
				cur = pos,
				ctl = 0,
			}
		end
	end
	setPhase("race")
	local cps = {}
	for _, c in st.course.checkpoints do
		table.insert(cps, { x = c.x, z = c.z, r = c.r })
	end
	sendRacers({
		t = "raceStart",
		seed = seed,
		windSeed = winds.seed,
		goAt = goAt,
		checkpoints = cps,
		count = #entrants,
	})
	for _, p in Players:GetPlayers() do
		if not humans[p.UserId] then
			send(p, { t = "toast", key = "race.startedOthers" })
		end
	end
	if RaceService.onStarted then
		local started = {}
		for _, p in humans do
			table.insert(started, p)
		end
		RaceService.onStarted(started)
	end
	acc = 0
	return true
end

-------------------------------------------------------------------------------
-- Конец
-------------------------------------------------------------------------------
local function standingsList(st: Race.State)
	local list = {}
	for rank, id in Race.standings(st) do
		local e = st.entrants[id]
		table.insert(list, {
			id = if type(id) == "number" then id else 0,
			name = e.name,
			ai = e.ai,
			rank = rank,
			cp = e.cp,
			finished = e.finished,
			place = e.place,
			time = e.time,
		})
	end
	return list
end

local function updateTags(st: Race.State, clear: boolean)
	for rank, id in Race.standings(st) do
		local model
		if type(id) == "number" then
			local p = humans[id]
			model = p and FlightService.balloonOf(p)
		else
			local a = ais[id]
			model = a and a.model
		end
		local root = model and model.PrimaryPart
		local tag = root and root:FindFirstChild("Tag")
		local info = tag and tag:FindFirstChild("Info")
		if info and info:IsA("TextLabel") then
			info.Text = if clear then "" else "#" .. rank
		end
	end
end

local function finishRace()
	local st = race :: Race.State
	local list = standingsList(st)
	RaceService.lastResults = list
	local ended = {}
	for id, p in humans do
		local e = st.entrants[id]
		if not p.Parent or not e then
			continue
		end
		local mult =
			Rewards.multiplier(Monetization.hasPass(p, "DoubleCoins"), Monetization.hasPass(p, "Vip"))
		local coins = if e.left then 0 else Rewards.apply(Race.reward(st, id), mult)
		local d = Data.get(p)
		if d and not e.left then
			Profile.earn(d, coins)
			Profile.recordRace(d, e.place)
			Data.changed(p)
		end
		p:SetAttribute("Racing", nil)
		p:SetAttribute("Cp", nil)
		send(p, {
			t = "results",
			place = e.place,
			finished = e.finished,
			time = e.time,
			cp = e.cp,
			total = #st.course.checkpoints,
			coins = coins,
			mult = mult,
			list = list,
			wins = if d then d.wins else 0,
		})
		Monetization.sendProfile(p)
		table.insert(ended, p)
	end
	updateTags(st, true)
	for _, a in ais do
		a.model:Destroy()
	end
	ais = {}
	WorldBuilder.clearCourse()
	race = nil
	humans = {}
	setPhase("results")
	resultsUntil = now() + R.Results
	Workspace:SetAttribute("RaceGo", nil)
	RaceService.schedule(R.Results + R.Intermission)
	if RaceService.onEnded then
		RaceService.onEnded(ended)
	end
end

-- Остановить гонку досрочно (отладка): итоги по текущим местам
function RaceService.stop()
	if race then
		finishRace()
	end
end

-------------------------------------------------------------------------------
-- «Намок» и появление во время гонки
-------------------------------------------------------------------------------
local function onSplash(player: Player): boolean
	local st = race
	if not st or not RaceService.inRace(player) then
		return false
	end
	local x, y, z = Race.splash(st, player.UserId)
	local T = Config.Flight.SplashTime
	FlightService.freeze(player, T)
	FlightService.teleportLater(player, T * 0.5, x, y, z, T * 0.5)
	return true
end

local function spawnFor(player: Player): (number?, number?, number?)
	local st = race
	if not st or not RaceService.inRace(player) then
		return nil, nil, nil
	end
	local e = st.entrants[player.UserId]
	if st.t < 0 then
		return Race.start(st, player.UserId)
	end
	local c = if e.cp > 0 then st.course.checkpoints[e.cp] else nil
	if c then
		return c.x, R.RespawnY, c.z
	end
	return Race.start(st, player.UserId)
end

-------------------------------------------------------------------------------
-- Шаг
-------------------------------------------------------------------------------
local function handle(st: Race.State, events)
	for _, ev in events do
		if ev.t == "go" then
			sendRacers({ t = "go" })
		elseif ev.t == "cp" then
			local p = humans[ev.id]
			if p then
				p:SetAttribute("Cp", ev.n)
				send(p, { t = "cp", n = ev.n, total = ev.total })
			end
		elseif ev.t == "finish" then
			local e = st.entrants[ev.id]
			local p = humans[ev.id]
			if p then
				p:SetAttribute("Cp", #st.course.checkpoints)
			end
			sendRacers({
				t = "finish",
				name = e.name,
				place = ev.place,
				time = ev.time,
				userId = if p then p.UserId else 0,
				ai = e.ai,
			})
		elseif ev.t == "end" then
			finishRace()
			return
		end
	end
end

function RaceService.step(dt: number)
	if phase == "free" then
		if now() >= nextRace then
			RaceService.start()
		end
		return
	elseif phase == "results" then
		if now() >= resultsUntil then
			setPhase("free")
		end
		return
	end
	local st = race
	if not st then
		setPhase("free")
		return
	end
	local winds = FlightService.winds
	for id, p in humans do
		if not p.Parent then
			Race.leave(st, id)
			humans[id] = nil
			continue
		end
		local x, y, z = FlightService.position(p)
		if x then
			Race.setPos(st, id, x, y :: number, z :: number)
		end
	end
	for id, a in ais do
		local e = st.entrants[id]
		local frozen = Race.isFrozen(st, id)
		local ctl = 0
		local c = Race.nextCheckpoint(st, id)
		if c and not frozen and not e.finished then
			ctl = Pilot.decide(a.mem, a.fl, { x = c.x, z = c.z, r = c.r }, world, winds, dt)
		elseif e.finished then
			ctl = if a.fl.y < Winds.mid(winds, 2) then 1 else 0
		end
		local ev = Flight.step(a.fl, ctl, dt, winds, world, frozen)
		if ev == "splash" then
			local x, y, z = Race.splash(st, id)
			Flight.place(a.fl, x, y, z)
		end
		Race.setPos(st, id, a.fl.x, a.fl.y, a.fl.z)
		if ctl ~= a.ctl then
			a.ctl = ctl
			a.model:SetAttribute("Ctl", ctl)
		end
		a.prev = a.cur
		a.cur = Vector3.new(a.fl.x, a.fl.y + RH, a.fl.z)
	end
	acc = 0
	handle(st, Race.step(st, dt))
	if race ~= st then
		return
	end
	standAcc += dt
	if standAcc >= 0.5 then
		standAcc = 0
		sendRacers({ t = "standings", list = standingsList(st), t0 = st.t })
		updateTags(st, false)
	end
end

-- Каждый кадр: плавное движение ИИ-шаров между шагами логики
function RaceService.heartbeat(dt: number)
	if phase ~= "race" then
		return
	end
	acc += dt
	local k = math.clamp(acc / Config.Timing.Step, 0, 1)
	for _, a in ais do
		if a.model.Parent then
			a.model:PivotTo(CFrame.new(a.prev:Lerp(a.cur, k)))
		end
	end
end

function RaceService.init(w)
	world = w
	FlightService.onSplash = onSplash
	FlightService.spawnFor = spawnFor
	setPhase("free")
	RaceService.schedule(R.Intermission)
	Players.PlayerAdded:Connect(function(p)
		p:SetAttribute("RaceOptIn", true)
	end)
	for _, p in Players:GetPlayers() do
		if p:GetAttribute("RaceOptIn") == nil then
			p:SetAttribute("RaceOptIn", true)
		end
	end
end

-- Отладка: перенести игрока к следующему чекпоинту
function RaceService.debugNext(player: Player): string?
	local st = race
	if not st then
		return "no race"
	end
	local c = Race.nextCheckpoint(st, player.UserId)
	if not c then
		return "finished"
	end
	local _, y = FlightService.position(player)
	FlightService.teleport(player, c.x, math.max(y or 0, Winds.mid(FlightService.winds, 1)), c.z, nil)
	return "→ checkpoint"
end

return RaceService
