--[[
	Прогон сервера на заглушке движка: архипелаг строится, игроки появляются в шарах
	(сиденье, LinearVelocity, сетевой владелец), боты ЛЕТАЮТ шарами (сервер берёт позицию
	из CFrame корзины): доставка на крышу, «намок», проверка скорости, гонка с ИИ-соперниками
	до итогов и монет, покупки, PolicyService, идемпотентность чеков, сбой DataStore.
	Запуск (после rojo build): lune run tests/engine/server_sim.luau build/game.rbxl
]]

local process = require("@lune/process")
local roblox = require("@lune/roblox")
local task = require("@lune/task")
local Sim = require("./Sim")

local CFrame, Vector3 = roblox.CFrame, roblox.Vector3

local failures = {}
local function check(cond, msg)
	print((if cond then "  ✓ " else "  ✗ ") .. msg)
	if not cond then
		table.insert(failures, msg)
	end
end

local game = Sim.loadPlace(process.args[1] or "build/game.rbxl")
local RS = game:GetService("ReplicatedStorage")
local ws = game:GetService("Workspace")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Shared = RS.Shared
local function shared(name)
	return Sim.require(Shared[name])
end
local Config = shared("Config")
local Catalog = shared("Catalog")
local Flight = shared("Flight")
local World = shared("World")
local Winds = shared("Winds")
local Bots = require("../lib/Bots").make(shared)

local RH = Config.Flight.RootH
Sim.virtualTime = 1000
ws:SetAttribute("WorldSeed", 7)
local alice = Sim.addPlayer("Alice")
local bob = Sim.addPlayer("Bob")

local function tick(dt)
	Sim.virtualTime += dt
	Sim.signalOf(RunService, "Heartbeat"):Fire(dt)
	task.wait()
end
local function ticks(seconds)
	for _ = 1, math.floor(seconds / Config.Timing.Step + 0.5) do
		tick(Config.Timing.Step)
	end
end
local function waitUntil(fn, timeout)
	local t0 = os.clock()
	while not fn() do
		if os.clock() - t0 > timeout then
			return false
		end
		task.wait(0.02)
	end
	return true
end
local function sentTo(player, kind)
	local out = {}
	for _, s in Sim.sent do
		if (s.player == player or s.player == "all") and s.payload and s.payload.t == kind then
			table.insert(out, s.payload)
		end
	end
	return out
end
local function last(player, kind)
	local l = sentTo(player, kind)
	return l[#l]
end
local function action(player, payload)
	Sim.signalOf(RS.Remotes.ClientAction, "OnServerEvent"):Fire(player, payload)
	task.wait(0.03)
end
local function balloon(p)
	return ws.Balloons:FindFirstChild("Balloon_" .. p.UserId)
end
local function rootOf(p)
	local b = balloon(p)
	return b and b.PrimaryPart
end
local function posOf(p)
	local c = rootOf(p).CFrame.Position
	return c.X, c.Y - RH, c.Z
end
local function place(p, x, y, z)
	rootOf(p).CFrame = CFrame.new(x, y + RH, z)
end

print("== boot")
local server = game:GetService("ServerScriptService").Server
Sim.runScript(server)
check(
	waitUntil(function()
		return ws:GetAttribute("WorldReady") == true
	end, 30),
	"world builds"
)
if not ws:GetAttribute("WorldReady") then
	process.exit(1)
end
local world = World.generate(7)
local arch = ws:FindFirstChild("Archipelago")
check(arch ~= nil and arch:FindFirstChild("Sea") ~= nil, "sea and islands")
local islands, houses = 0, 0
for _, c in arch:GetChildren() do
	if string.sub(c.Name, 1, 7) == "Island_" then
		islands += 1
		for _, h in c:GetChildren() do
			if string.sub(h.Name, 1, 6) == "House_" then
				houses += 1
			end
		end
	end
end
check(
	islands == #world.islands and houses == #world.houses,
	string.format("%d islands, %d houses", islands, houses)
)
local roofErr = 0
for _, h in world.houses do
	local m = arch:FindFirstChild("House_" .. h.id, true)
	local roof = m.Roof
	roofErr = math.max(roofErr, math.abs(roof.CFrame.Position.Y + roof.Size.Y / 2 - h.roof))
end
check(roofErr < 1e-3, "roof heights = flight model")
check(
	type(ws:GetAttribute("WindSeed")) == "number" and ws:FindFirstChild("WindMast") ~= nil,
	"winds and wind mast"
)
check(
	ws:GetAttribute("Phase") == "free" and ws:GetAttribute("NextRace") > Sim.virtualTime,
	"free flight, race scheduled"
)
check(
	waitUntil(function()
		return alice.Character ~= nil
			and bob.Character ~= nil
			and balloon(alice) ~= nil
			and balloon(bob) ~= nil
	end, 8),
	"characters spawn in balloons"
)
local ba = balloon(alice)
local root = ba.PrimaryPart
check(root.Name == "Basket" and not root.Anchored, "basket is the unanchored root")
check(root:FindFirstChild("Lift") and root.Lift.ClassName == "LinearVelocity", "LinearVelocity Lift")
check(root:FindFirstChild("Upright") ~= nil, "AlignOrientation keeps it upright")
check(Sim.seated[ba.Seat] == alice.Character.Humanoid, "character seated in the basket")
check(root:GetNetworkOwner() == alice, "network owner = player")
check(ba:FindFirstChild("Envelope") and #ba.Envelope:GetChildren() == 8, "envelope: 7 discs + top")
check(root:FindFirstChild("Trail") ~= nil, "trail")
check(ba:GetAttribute("Ribbon") == Catalog.Default.ribbon, "ribbon attribute for clients")
check(root.CollisionGroup == "Balloons", "balloons don't collide with each other")
check(Sim.collidable["Balloons|Balloons"] == false, "collision group set")
local gx, gy, gz = posOf(alice)
check(math.abs(gy - World.groundAt(world, gx, gz)) < 0.01, "stands on the harbor field")
check(
	waitUntil(function()
		return alice:FindFirstChild("leaderstats") ~= nil and #sentTo(alice, "profile") > 0
	end, 5),
	"profile loaded, leaderstats"
)
check(
	waitUntil(function()
		return alice:GetAttribute("Parcels") == 1 and last(alice, "orders") ~= nil
	end, 5),
	"a delivery order is given"
)

local ES = Sim.require(server.FlightService)
local Data = Sim.require(server.DataService)
local DS = Sim.require(server.DeliveryService)
local RaceService = Sim.require(server.RaceService)
-- гонку запускаем сами, когда дойдём до неё
RaceService.schedule(1e6)

print("== controls are relayed for everyone's flame")
action(alice, { t = "ctl", v = 1 })
check(ba:GetAttribute("Ctl") == 1, "Ctl attribute")
action(alice, { t = "ctl", v = 7 })
check(ba:GetAttribute("Ctl") == 1, "clamped")
action(alice, { t = "ctl", v = 0 })

-- бот-пилот летит шаром игрока: позиция берётся из корзины, CFrame пишет тест (как клиент через Lift)
local function fly(p, mem, policy, goalFn, untilFn, maxT)
	local winds = ES.winds
	local x, y, z = posOf(p)
	local fl = Flight.new(x, y, z)
	local t = 0
	while t < maxT do
		local r = rootOf(p)
		if not r then
			break
		end
		if untilFn() then
			return true, t
		end
		local c = r.CFrame.Position
		fl.x, fl.y, fl.z = c.X, c.Y - RH, c.Z
		if not r.Anchored then
			local goal = goalFn()
			local ctl = if goal
				then Bots.drive(mem, policy, fl, goal, world, winds, Config.Timing.Step)
				else 0
			Flight.step(fl, ctl, Config.Timing.Step, winds, world)
			r.CFrame = CFrame.new(fl.x, fl.y + RH, fl.z)
		else
			fl.vx, fl.vy, fl.vz = 0, 0, 0
		end
		tick(Config.Timing.Step)
		t += Config.Timing.Step
	end
	return untilFn(), t
end

print("== a delivery: the bot steers the drop marker onto the roof")
local order = DS.ordersOf(alice)[1]
local coins0 = Data.get(alice).coins
local ok, took = fly(alice, Bots.newMem("novice", 1), "novice", function()
	local o = DS.ordersOf(alice)[1]
	return o and { x = o.x, z = o.z, r = 8, house = o.house }
end, function()
	return #sentTo(alice, "dropped") > 0
end, 300)
check(ok, string.format("parcel dropped after %.0f s", took))
check(ws:FindFirstChild("Parcel") ~= nil, "parcel falls with a parachute")
check(alice:GetAttribute("Parcels") == 0 or DS.ordersOf(alice)[1] ~= order, "order taken off")
-- приземление — task.delay (в заглушке реальное время): ждём через waitUntil
local fall = (last(alice, "dropped") or { time = 5 }).time
check(
	waitUntil(function()
		tick(0.05)
		return last(alice, "delivered") ~= nil
	end, fall + 3),
	string.format("parcel lands (%.1f s fall)", fall)
)
local dl = last(alice, "delivered")
check(
	dl ~= nil and dl.coins > 0 and dl.house == order.house,
	"delivered on the roof: +" .. tostring(dl and dl.coins)
)
check(Data.get(alice).coins == coins0 + (dl and dl.coins or 0), "coins credited")
check(Data.get(alice).deliveries == 1, "delivery counted")
check(
	waitUntil(function()
		return alice:GetAttribute("Parcels") == 1 and DS.ordersOf(alice)[1].house ~= order.house
	end, 3),
	"next order"
)
check(
	waitUntil(function()
		tick(0.1)
		return ws:FindFirstChild("Parcel") == nil
	end, 5),
	"parcel cleaned up"
)

print("== skip order")
local before = DS.ordersOf(alice)[1].house
action(alice, { t = "skipOrder" })
check(DS.ordersOf(alice)[1].house ~= before, "another order")
local h2 = DS.ordersOf(alice)[1].house
action(alice, { t = "skipOrder" })
check(DS.ordersOf(alice)[1].house == h2 and last(alice, "toast").key == "order.skipWait", "skip cooldown")

print("== speed check")
local vx, vy, vz = posOf(alice)
ticks(0.5)
place(alice, vx + 500, vy, vz)
ticks(0.5)
local nx = posOf(alice)
check(math.abs(nx - vx) < 50, "teleport hack is reset (" .. math.floor(nx - vx) .. ")")
local warned = false
for _, w in Sim.warnings or {} do
	if string.find(w, "moved too fast", 1, true) then
		warned = true
	end
end
check(warned, "warning in the log")

ticks(1.2) -- после телепорта сервер секунду не проверяет шар
print("== splash in free flight")
local sx, _, sz = 0, 0, 0
for _ = 1, 50 do
	sx, sz = math.random(-1500, 1500), math.random(-1500, 1500)
	if World.groundAt(world, sx, sz) == Config.World.Water then
		break
	end
end
place(alice, sx, 0.5, sz)
ticks(0.3)
check(last(alice, "splash") ~= nil, "splash event")
check(root.Anchored and ba:GetAttribute("Frozen") ~= nil, "frozen")
-- разморозка — task.delay (реальное время)
waitUntil(function()
	tick(0.05)
	return not root.Anchored and math.abs(select(2, posOf(alice)) - Winds.mid(ES.winds, 1)) < 0.1
end, Config.Flight.SplashTime + 2)
local _, ay = posOf(alice)
check(not root.Anchored and root:GetNetworkOwner() == alice, "unfrozen, ownership back")
check(math.abs(ay - Winds.mid(ES.winds, 1)) < 0.1, "back in the air over the same spot")

print("== race")
RaceService.schedule(1)
local wins0 = Data.get(alice).wins
local coinsR = Data.get(alice).coins
ticks(1.3)
check(ws:GetAttribute("Phase") == "race", "race starts on schedule")
local rs = last(alice, "raceStart")
check(rs ~= nil and #rs.checkpoints == Config.Race.Checkpoints + 1, "raceStart with the course")
check(
	ws:FindFirstChild("Course") and #ws.Course:GetChildren() == Config.Race.Checkpoints + 1,
	"checkpoint columns"
)
local ais = 0
for _, m in ws.Balloons:GetChildren() do
	if m:GetAttribute("Ai") then
		ais += 1
	end
end
check(ais == Config.Race.FillTo - 2, "AI rivals fill the race: " .. ais)
check(alice:GetAttribute("Racing") == true and bob:GetAttribute("Racing") == true, "both racing")
check(alice:GetAttribute("Parcels") == 0, "orders paused during the race")
check(root.Anchored, "countdown: frozen on the grid")
local st = RaceService.state()
local mems = { [alice] = Bots.newMem("pro", 1), [bob] = Bots.newMem("pro", 2) }
local fls = {}
for _, p in { alice, bob } do
	local x, y, z = posOf(p)
	fls[p] = Flight.new(x, y, z)
end
local splashedBob = false
local steps = 0
while ws:GetAttribute("Phase") == "race" and steps < 4000 do
	for _, p in { alice, bob } do
		local r = rootOf(p)
		local fl = fls[p]
		local c = r.CFrame.Position
		fl.x, fl.y, fl.z = c.X, c.Y - RH, c.Z
		local e = st.entrants[p.UserId]
		local cp = st.course.checkpoints[e.cp + 1]
		if not r.Anchored and cp then
			local ctl = Bots.drive(
				mems[p],
				"pro",
				fl,
				{ x = cp.x, z = cp.z, r = cp.r },
				world,
				ES.winds,
				Config.Timing.Step
			)
			Flight.step(fl, ctl, Config.Timing.Step, ES.winds, world)
			r.CFrame = CFrame.new(fl.x, fl.y + RH, fl.z)
		end
	end
	-- Боб один раз падает в море после первого чекпоинта
	if not splashedBob and st.entrants[bob.UserId].cp == 1 then
		splashedBob = true
		local x, _, z = posOf(bob)
		for _ = 1, 40 do
			if World.groundAt(world, x, z) == Config.World.Water then
				break
			end
			x += 30
		end
		place(bob, x, 0.5, z)
	end
	tick(Config.Timing.Step)
	steps += 1
end
check(ws:GetAttribute("Phase") == "results", string.format("race finished (%d steps)", steps))
check(#sentTo(alice, "go") == 1, "go signal")
check(#sentTo(alice, "cp") >= 1, "checkpoint events: " .. #sentTo(alice, "cp"))
check(#sentTo(alice, "standings") > 5, "live standings")
check(#sentTo(alice, "finish") >= 1, "finish announcements")
check(splashedBob and last(bob, "splash") ~= nil, "Bob splashed and came back")
local res = last(alice, "results")
check(res ~= nil and res.list and #res.list == Config.Race.FillTo, "results with all racers")
print(
	string.format(
		"    Alice: place %s, coins %s; Bob: place %s",
		tostring(res and res.place),
		tostring(res and res.coins),
		tostring(last(bob, "results") and last(bob, "results").place)
	)
)
local aiFinished = 0
for _, r in res and res.list or {} do
	if r.ai and r.finished then
		aiFinished += 1
	end
end
check(aiFinished >= 2, "AI rivals finish too (" .. aiFinished .. ")")
check(res and res.coins > 0 and Data.get(alice).coins - coinsR >= res.coins, "race coins credited")
check(Data.get(alice).races == 1 and Data.get(alice).wins >= wins0, "race recorded")
local aisLeft = 0
for _, m in ws.Balloons:GetChildren() do
	if m:GetAttribute("Ai") then
		aisLeft += 1
	end
end
check(aisLeft == 0 and ws:FindFirstChild("Course") == nil, "AI balloons and course removed")
check(alice:GetAttribute("Racing") == nil, "free flight again")
ticks(Config.Race.Results + 0.5)
check(ws:GetAttribute("Phase") == "free", "results → free")
check(
	waitUntil(function()
		return alice:GetAttribute("Parcels") == 1
	end, Config.Race.Results),
	"orders resume after the race"
)

print("== opt out")
action(bob, { t = "optIn", on = false })
action(alice, { t = "debug", cmd = "race" })
check(ws:GetAttribute("Phase") == "race" and bob:GetAttribute("Racing") == nil, "Bob opted out, Alice races")
action(alice, { t = "debug", cmd = "stop" })
check(ws:GetAttribute("Phase") == "results", "stopped")
ticks(Config.Race.Results + 0.5)
action(bob, { t = "optIn", on = true })

print("== shop and cosmetics")
local d = Data.get(alice)
d.coins = 0
action(alice, { t = "buyCoins", id = "balloon_sky" })
check(last(alice, "toast").key == "shop.noCoins" and not d.owned.balloon_sky, "can't buy without coins")
d.coins = 1000
action(alice, { t = "buyCoins", id = "balloon_sky" })
check(d.owned.balloon_sky and d.coins == 1000 - Config.Rarity.Common.price, "bought for coins")
check(
	waitUntil(function()
		return balloon(alice).Envelope:GetAttribute("Item") == "balloon_sky"
	end, 2),
	"balloon repainted for everyone"
)
d.coins = 2000
action(alice, { t = "buyCoins", id = "trail_fire" })
check(rootOf(alice).Trail:GetAttribute("Item") == "trail_fire", "new trail")
action(alice, { t = "buyCoins", id = "balloon_gold" })
check(not d.owned.balloon_gold, "VIP item not for sale")

print("== passes")
action(alice, { t = "pass", key = "Vip" })
check(alice:GetAttribute("Pass_Vip") == true, "VIP emulated in Studio")
action(alice, { t = "equip", id = "balloon_gold" })
check(
	waitUntil(function()
		return balloon(alice).Envelope:GetAttribute("Item") == "balloon_gold"
	end, 2),
	"VIP wears the golden balloon"
)
check(string.find(rootOf(alice).Tag.NameLabel.Text, "★", 1, true) ~= nil, "VIP star on the name tag")
action(alice, { t = "pass", key = "Cargo" })
check(
	waitUntil(function()
		return alice:GetAttribute("Parcels") == 2
	end, 2),
	"Cargo basket → two orders"
)

print("== chest and PolicyService")
action(alice, { t = "product", key = "Chest" })
local cr = last(alice, "chestResult")
check(cr ~= nil and Catalog.get(cr.id) ~= nil, "chest gives an item: " .. tostring(cr and cr.id))
Sim.policyRestricted = true
local carol = Sim.addPlayer("Carol")
Sim.signalOf(Players, "PlayerAdded"):Fire(carol)
check(
	waitUntil(function()
		return Data.get(carol) ~= nil and #sentTo(carol, "profile") > 0 and balloon(carol) ~= nil
	end, 6),
	"late joiner gets a profile and a balloon"
)
task.wait(0.2)
action(carol, { t = "profile" })
check(last(carol, "profile").chestAllowed == false, "restricted region: chest hidden")
action(carol, { t = "product", key = "Chest" })
check(
	last(carol, "toast").key == "shop.chestRestricted" and last(carol, "chestResult") == nil,
	"restricted region: chest refused by the server"
)
action(carol, { t = "product", key = "DirectEpic", item = "balloon_neon" })
check(Data.get(carol).owned.balloon_neon == true, "restricted region: direct purchase works")
action(carol, { t = "product", key = "DirectEpic", item = "balloon_sky" })
check(not Data.get(carol).owned.balloon_sky, "direct purchase checks rarity")
Sim.policyRestricted = false
Sim.policyFail = true
local dave = Sim.addPlayer("Dave")
Sim.signalOf(Players, "PlayerAdded"):Fire(dave)
waitUntil(function()
	return Data.get(dave) ~= nil
end, 5)
task.wait(0.2)
action(dave, { t = "product", key = "Chest" })
check(last(dave, "chestResult") == nil, "policy request fails → chest treated as restricted")
Sim.policyFail = false

print("== receipts are idempotent")
local Monetization = Sim.require(server.Monetization)
local c1 = d.coins
check(Monetization.grant(alice, "Coins500", "PID-1"), "grant ok")
check(Monetization.grant(alice, "Coins500", "PID-1"), "repeat ok")
check(d.coins == c1 + 500, "coins added once (" .. (d.coins - c1) .. ")")
check(Sim.processReceipt ~= nil, "ProcessReceipt is set")

print("== data saving")
check(Data.save(alice), "save works")
local stored = Sim.dataStores[Config.DataStore.Name]["u_" .. alice.UserId]
check(stored and stored.coins == d.coins and stored.owned.balloon_sky, "profile stored")
Sim.dataFail = true
local erin = Sim.addPlayer("Erin")
Sim.signalOf(Players, "PlayerAdded"):Fire(erin)
check(
	waitUntil(function()
		return Data.get(erin) ~= nil
	end, 15),
	"data outage: player still gets a temp profile"
)
check(erin:GetAttribute("DataSaved") == false, "temp profile is marked unsaved")
Sim.dataFail = false

print("== player leaves")
Sim.signalOf(Players, "PlayerRemoving"):Fire(dave)
task.wait(0.1)
dave.Parent = nil
check(ws.Balloons:FindFirstChild("Balloon_" .. dave.UserId) == nil, "balloon removed")

print("== selftest")
action(alice, { t = "debug", cmd = "selftest" })
check(
	waitUntil(function()
		return #sentTo(alice, "selftest") > 0
	end, 20),
	"selftest finished"
)
local stl = last(alice, "selftest")
local fails = 0
for _, line in stl and stl.lines or {} do
	print("    " .. line)
	if string.find(line, "FAIL", 1, true) then
		fails += 1
	end
end
check(fails == 0, "selftest has no FAIL")

print("== warnings")
local errs = 0
for _, w in Sim.warnings or {} do
	if string.find(w, "error", 1, true) or string.find(w, "[Actions]", 1, true) then
		errs += 1
		print("    " .. w)
	end
end
check(errs == 0, "no runtime errors")
print(string.format("\n%d failures", #failures))
process.exit(if #failures > 0 then 1 else 0)
