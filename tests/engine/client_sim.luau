--[[
	Сервер + клиент в одном DataModel на заглушке движка. Кадры идут вручную (детерминированно),
	заглушка интегрирует LinearVelocity корзины — проверяется весь путь управления:
	  нажал ВЫШЕ (клавиша или кнопка на экране) → в том же кадре скорость вверх, пламя;
	  отпустил → шар держит высоту; сменил слой → ленты на корзине повернулись сразу,
	  шар повернул за ~1.5 с; лестница ветров (стрелки относительно камеры, маркер высоты,
	  подсветка слоёв к цели); ленты ветра в слоях; метка падения посылки; гонка (отсчёт,
	  чекпоинты, таблица мест, итоги); магазин с точными шансами и PolicyService.
	Запуск (после rojo build): lune run tests/engine/client_sim.luau build/game.rbxl
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
local function waitUntil(fn, timeout)
	local t0 = os.clock()
	while not fn() do
		if os.clock() - t0 > timeout then
			return false
		end
		task.wait(0.05)
	end
	return true
end

roblox.implementMethod("SocialService", "CanSendGameInviteAsync", function()
	return true
end)

local game = Sim.loadPlace(process.args[1] or "build/game.rbxl")
local ws = game:GetService("Workspace")
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local function shared(name)
	return Sim.require(RS.Shared[name])
end
local Config = shared("Config")
local Catalog = shared("Catalog")
local Winds = shared("Winds")
local World = shared("World")
local Flight = shared("Flight")

local RH = Config.Flight.RootH
Sim.virtualTime = 5000
ws:SetAttribute("WorldSeed", 11)
local player = Sim.addPlayer("Tester")
Players.LocalPlayer = player
Sim.localPlayer = player
Sim.clientMode = true
roblox.Instance.new("PlayerGui").Parent = player
local cam = roblox.Instance.new("Camera")
cam.Parent = ws
ws.CurrentCamera = cam

local server = game:GetService("ServerScriptService").Server
Sim.runScript(server)
check(
	waitUntil(function()
		return ws:GetAttribute("WorldReady") == true and player.Character ~= nil
	end, 30),
	"server ready, character spawned"
)
local RaceService = Sim.require(server.RaceService)
RaceService.schedule(1e6)

local client = game:GetService("StarterPlayer").StarterPlayerScripts.Client
local ok, err = pcall(function()
	Sim.runScript(client)
end)
check(ok, "client script starts" .. (if ok then "" else ": " .. tostring(err)))

-- кадр: сервер и клиент, физика корзины по LinearVelocity
local frameErrors = {}
local function frame(dt)
	Sim.virtualTime += dt
	local okF, errF = pcall(function()
		Sim.signalOf(RunService, "Heartbeat"):Fire(dt)
		task.wait()
		Sim.stepPhysics(dt)
		Sim.signalOf(RunService, "RenderStepped"):Fire(dt)
	end)
	if not okF then
		table.insert(frameErrors, tostring(errF))
	end
	task.wait()
end
local DT = 1 / 30
local function frames(seconds)
	for _ = 1, math.floor(seconds / DT + 0.5) do
		frame(DT)
	end
end
local function action(name, state)
	local fn = Sim.actions and Sim.actions[name]
	if fn then
		fn(name, state, {})
	end
	task.wait()
end
local function act(payload)
	Sim.signalOf(RS.Remotes.ClientAction, "OnServerEvent"):Fire(player, payload)
	task.wait(0.03)
end

local gui = player.PlayerGui
check(
	waitUntil(function()
		frame(DT)
		return gui:FindFirstChild("WindsUI") ~= nil and gui.WindsUI:FindFirstChild("Hud") ~= nil
	end, 10),
	"HUD built"
)
local ui = gui.WindsUI
local hud = ui.Hud
check(
	hud.Right:FindFirstChild("Ladder") and hud.Right:FindFirstChild("Controls") and ui:FindFirstChild("Shop"),
	"panels built"
)
check(Sim.actions and Sim.actions.WindsUp and Sim.actions.WindsDown, "UP / DOWN actions bound")
check(Sim.humanoidStates and Sim.humanoidStates.Jumping == false, "jumping disabled (Space = UP)")
check(game:GetService("GuiService").TouchControlsEnabled == false, "touch stick and jump hidden")
local balloon
check(
	waitUntil(function()
		frame(DT)
		balloon = ws.Balloons:FindFirstChild("Balloon_" .. player.UserId)
		return balloon ~= nil
	end, 5),
	"my balloon"
)
local root = balloon.PrimaryPart
local lift = root.Lift
local function alt()
	return root.CFrame.Position.Y - RH
end
check(cam.CameraSubject == root, "camera follows the basket")
check(
	waitUntil(function()
		frame(DT)
		return hud.TopLeft.Coins.Amount.Text == "0"
	end, 5),
	"coins shown from profile"
)
check(
	waitUntil(function()
		frame(DT)
		return hud.Order.Visible
	end, 5),
	"order panel: " .. hud.Order.Text.Text
)

print("== instant response")
local winds = Winds.generate(ws:GetAttribute("WindSeed"))
local world = World.generate(11)
local y0 = alt()
action("WindsUp", roblox.Enum.UserInputState.Begin)
frame(DT)
check(lift.VectorVelocity.Y > 0, string.format("first frame: climbing at %.1f", lift.VectorVelocity.Y))
check(balloon:GetAttribute("Ctl") == 1, "server knows (flame for others)")
check(balloon.Burner.Flame.Enabled == true, "own flame on in the same frame")
frames(0.2)
check(lift.VectorVelocity.Y >= Config.Flight.Climb * 0.5, "half climb speed within 0.2 s")
check(alt() > y0 + 1, string.format("basket rose %.1f studs", alt() - y0))
check(hud.Right.Controls.UpButton.BackgroundTransparency == 0, "UP button lit")
-- до середины первого слоя
while alt() < Winds.mid(winds, 1) do
	frame(DT)
end
action("WindsUp", roblox.Enum.UserInputState.End)
frame(DT)
check(balloon.Burner.Flame.Enabled == false, "flame off on release")
frames(1)
local hold = alt()
frames(3)
check(math.abs(alt() - hold) < 0.3, string.format("holds altitude (%.2f)", alt() - hold))

print("== layer change: ribbons turn at once, the balloon within ~1.5 s")
frames(2)
local l2 = winds.layers[2]
local function ribbonDir()
	-- первый сегмент первой ленты своего шара: ближайшая к углу корзины лента
	local best, bd = nil, math.huge
	local corner = (root.CFrame * CFrame.new(2.5, RH, 2.5)).Position
	for _, p in ws.WindFx:GetChildren() do
		if p.Name == "Ribbon" then
			local d = (p.CFrame.Position - corner).Magnitude
			if d < bd then
				best, bd = p, d
			end
		end
	end
	local v = best.CFrame.LookVector
	return math.atan2(v.Z, v.X)
end
action("WindsUp", roblox.Enum.UserInputState.Begin)
local t = 0
local ribbonT, turnT = nil, nil
while t < 5 do
	frame(DT)
	t += DT
	local st = { vx = lift.VectorVelocity.X, vz = lift.VectorVelocity.Z }
	if
		not ribbonT
		and alt() > l2.bottom + Config.Wind.Blend
		and Winds.angleDiff(ribbonDir(), l2.angle) < 45
	then
		ribbonT = t
	end
	if not turnT and Winds.angleDiff(math.atan2(st.vz, st.vx), l2.angle) <= 30 then
		turnT = t
	end
	if alt() > Winds.mid(winds, 2) then
		action("WindsUp", roblox.Enum.UserInputState.End)
	end
	if turnT and ribbonT then
		break
	end
end
action("WindsUp", roblox.Enum.UserInputState.End)
check(turnT ~= nil and turnT <= 2.2, string.format("course turned to layer 2 in %.2f s", turnT or -1))
check(
	ribbonT ~= nil and ribbonT <= turnT,
	string.format("ribbons pointed there first (%.2f s)", ribbonT or -1)
)
frames(1.5)

print("== on-screen buttons (phone)")
local up = hud.Right.Controls.UpButton
local down = hud.Right.Controls.DownButton
local yb = alt()
Sim.signalOf(down, "InputBegan"):Fire({ UserInputType = roblox.Enum.UserInputType.Touch })
frame(DT)
check(lift.VectorVelocity.Y < 0 and balloon:GetAttribute("Ctl") == -1, "touch DOWN → valve")
frames(0.5)
Sim.signalOf(down, "InputEnded"):Fire({ UserInputType = roblox.Enum.UserInputType.Touch })
frames(0.5)
check(alt() < yb - 3, "went down")
Sim.signalOf(up, "InputBegan"):Fire({ UserInputType = roblox.Enum.UserInputType.Touch })
Sim.signalOf(down, "InputBegan"):Fire({ UserInputType = roblox.Enum.UserInputType.Touch })
frame(DT)
check(balloon:GetAttribute("Ctl") == 0, "both pressed → hold")
Sim.signalOf(up, "InputEnded"):Fire({ UserInputType = roblox.Enum.UserInputType.Touch })
Sim.signalOf(down, "InputEnded"):Fire({ UserInputType = roblox.Enum.UserInputType.Touch })
frames(0.5)

print("== wind ladder")
local ladder = hud.Right.Ladder
local camPos = root.CFrame.Position + Vector3.new(0, 20, 40)
cam.CFrame = CFrame.lookAt(camPos, root.CFrame.Position) -- камера смотрит на север (-Z)
frame(DT)
local worst = 0
for k = 1, Config.Wind.Layers do
	local l = winds.layers[k]
	local look = cam.CFrame.LookVector
	local right = cam.CFrame.RightVector
	local f = Vector3.new(look.X, 0, look.Z).Unit
	local r = Vector3.new(right.X, 0, right.Z).Unit
	local v = Vector3.new(l.wx, 0, l.wz)
	local expected = math.deg(math.atan2(v:Dot(r), v:Dot(f)))
	local got = ladder["Row" .. k].Arrow.Rotation
	local d = math.abs((got - expected + 180) % 360 - 180)
	worst = math.max(worst, d)
end
check(worst < 1, string.format("arrows rotated relative to the camera (err %.2f°)", worst))
cam.CFrame = CFrame.lookAt(camPos, camPos + Vector3.new(1, 0, 0))
frame(DT)
local r1 = ladder.Row1.Arrow.Rotation
-- камера смотрит на восток (+X): стрелка = угол ветра от оси X по часовой
check(
	math.abs(((r1 - math.deg(winds.layers[1].angle)) + 180) % 360 - 180) < 1,
	"turning the camera turns the arrows"
)
local myK = Winds.layerAt(winds, alt())
check(
	ladder["Row" .. myK]:FindFirstChildOfClass("UIStroke") ~= nil,
	"my layer outlined (layer " .. myK .. ")"
)
local youY = ladder.You.Position.Y.Offset
action("WindsUp", roblox.Enum.UserInputState.Begin)
frames(1)
action("WindsUp", roblox.Enum.UserInputState.End)
frame(DT)
check(ladder.You.Position.Y.Offset < youY - 5, "'you' marker climbs with the balloon")
local marks = 0
for k = 0, Config.Wind.Layers do
	if ladder["Row" .. k].Mark.Text ~= "" then
		marks += 1
	end
end
check(marks >= 1, "layers toward the goal are marked (" .. marks .. ")")
check(ladder.TargetArrow.Visible, "goal arrow on the ladder")

print("== wind ribbons in every layer")
local streaks, perLayer = 0, {}
for _, p in ws.WindFx:GetChildren() do
	if p.Name == "Streak" then
		streaks += 1
		local k = Winds.layerAt(winds, p.CFrame.Position.Y)
		perLayer[k] = (perLayer[k] or 0) + 1
	end
end
check(streaks >= 100, "wind streaks: " .. streaks)
local allLayers = true
for k = 0, Config.Wind.Layers do
	allLayers = allLayers and (perLayer[k] or 0) > 0
end
check(allLayers, "every layer has its streaks")
local s1
for _, p in ws.WindFx:GetChildren() do
	if p.Name == "Streak" and Winds.layerAt(winds, p.CFrame.Position.Y) == 3 then
		s1 = p
		break
	end
end
local l3 = winds.layers[3]
check(s1.Color == roblox.Color3.fromRGB(l3.color[1], l3.color[2], l3.color[3]), "streak colored by its layer")
local p0 = s1.CFrame.Position
frame(DT)
local mv = s1.CFrame.Position - p0
check(
	math.abs(mv.X - l3.wx * DT) < 0.05 and math.abs(mv.Z - l3.wz * DT) < 0.05,
	"streaks fly with the layer's wind"
)
local ribbons = 0
for _, p in ws.WindFx:GetChildren() do
	if p.Name == "Ribbon" then
		ribbons += 1
	end
end
check(ribbons == 8 * #ws.Balloons:GetChildren(), "8 ribbon pieces on every balloon")

print("== delivery marker")
check(
	ws.WindFx:FindFirstChild("Beacon") ~= nil and ws.WindFx:FindFirstChild("RoofRing") ~= nil,
	"beacon over the target roof"
)
frames(0.2)
local mk = ws.WindFx.DropMarker
check(mk.Transparency < 1, "drop marker shown")
local Parcel = shared("Parcel")
local st = Flight.new(root.CFrame.Position.X, alt(), root.CFrame.Position.Z)
local land = Parcel.predict(winds, world, st.x, st.y, st.z)
check(
	(mk.CFrame.Position - Vector3.new(land.x, land.y + 0.4, land.z)).Magnitude < 25,
	"marker where the parcel would land"
)
act({ t = "debug", cmd = "order" })
frames(0.3)
check(
	waitUntil(function()
		frame(DT)
		return ws:FindFirstChild("Parcel") ~= nil
	end, 3),
	"above the order → the parcel drops by itself"
)

print("== race")
act({ t = "debug", cmd = "race" })
frames(0.2)
check(ws:GetAttribute("Phase") == "race" and player:GetAttribute("Racing") == true, "race started")
check(string.match(hud.Count.Text, "^%d$") ~= nil, "countdown: " .. hud.Count.Text)
check(not hud.Order.Visible, "order panel hidden in the race")
local course = ws.Course
frames(0.3)
check(
	course.CP1.Column.Transparency < 0.5 and course.CP2.Column.Transparency > 0.5,
	"next checkpoint bright, others dim"
)
local c0 = alt()
action("WindsUp", roblox.Enum.UserInputState.Begin)
frames(1)
check(math.abs(alt() - c0) < 0.01, "frozen during the countdown")
frames(Config.Race.Countdown)
check(alt() > c0 + 5, "GO → climbing")
action("WindsUp", roblox.Enum.UserInputState.End)
check(string.find(hud.Top.Banner.Text.Text, "1/", 1, true) ~= nil, "banner: " .. hud.Top.Banner.Text.Text)
frames(0.6)
check(
	hud.Board.Visible and hud.Board.R1.Visible and string.find(hud.Board.R1.Text, "1.", 1, true) ~= nil,
	"standings board"
)
act({ t = "debug", cmd = "cp" })
frames(0.5)
check(player:GetAttribute("Cp") == 1, "checkpoint 1")
check(string.find(hud.Top.Banner.Text.Text, "2/", 1, true) ~= nil, "banner → checkpoint 2")
check(
	course.CP2.Column.Transparency < 0.5 and course.CP1.Column.Transparency > 0.5,
	"highlight moved to checkpoint 2"
)
local splashes = 0
for _, x in Sim.sent do
	if x.payload and x.payload.t == "splash" then
		splashes += 1
	end
end
act({ t = "debug", cmd = "splash" })
frames(1.3)
local splashed = 0
for _, x in Sim.sent do
	if x.payload and x.payload.t == "splash" then
		splashed += 1
	end
end
check(splashed > splashes, "splash in the sea")
frames(0.5)
check(
	string.find(hud.Count.Text, "!", 1, true) ~= nil and string.len(hud.Count.Text) > 3,
	"splash message: " .. hud.Count.Text
)
frames(Config.Flight.SplashTime + 0.5)
local rx, _, rz = root.CFrame.Position.X, 0, root.CFrame.Position.Z
local c1 = RaceService.state().course.checkpoints[1]
check(math.sqrt((rx - c1.x) ^ 2 + (rz - c1.z) ^ 2) < 30, "back above the last checkpoint")
act({ t = "debug", cmd = "finish" })
frames(0.5)
check(waitUntil(function()
	frame(DT)
	return ui.Results.Visible
end, 3) or ws:GetAttribute("Phase") == "race", "finished")
act({ t = "debug", cmd = "stop" })
frames(0.3)
check(ui.Results.Visible, "results panel")
check(
	string.find(ui.Results.Body.Text, "%d") ~= nil,
	"results: " .. string.gsub(ui.Results.Body.Text, "\n", " | ")
)
check(string.find(ui.Results.List.Text, "AI", 1, true) ~= nil, "AI rivals in the results list")
frames(Config.Race.Results + 0.5)
check(not hud.Board.Visible, "board hidden after the race")

print("== shop")
Sim.signalOf(hud.TopLeft.ShopButton, "Activated"):Fire()
frames(0.2)
local shop = ui.Shop
check(shop.Visible, "shop opens")
local cards = 0
for _, d in shop.Body:GetDescendants() do
	if d.ClassName == "Frame" and Catalog.get(d.Name) then
		cards += 1
	end
end
check(cards == #Catalog.Items, "all items shown (" .. cards .. ")")
local Data = Sim.require(server.DataService)
Data.get(player).coins = 999
task.wait(1.1)
local buy
for _, d in shop.Body:GetDescendants() do
	if d.Name == "balloon_sky" then
		buy = d:FindFirstChildWhichIsA("TextButton")
	end
end
Sim.signalOf(buy, "Activated"):Fire()
check(
	waitUntil(function()
		frame(DT)
		return Data.get(player).owned.balloon_sky == true
	end, 2),
	"buy for coins through the UI"
)
check(
	waitUntil(function()
		frame(DT)
		local b = ws.Balloons:FindFirstChild("Balloon_" .. player.UserId)
		return b and b.Envelope:GetAttribute("Item") == "balloon_sky"
	end, 2),
	"my balloon repainted"
)
Sim.signalOf(shop.Tab_chest, "Activated"):Fire()
frames(0.2)
local odds = 0
for _, d in shop.Body:GetChildren() do
	if string.sub(d.Name, 1, 5) == "Odds_" then
		odds += 1
	end
end
check(odds == #Catalog.odds(), "every chest item has its exact chance (" .. odds .. ")")
check(shop.Body:FindFirstChild("OpenChest") ~= nil, "chest button where allowed")
Sim.signalOf(shop.Body.OpenChest, "Activated"):Fire()
check(
	waitUntil(function()
		frame(DT)
		return ui.Reward.Visible == true
	end, 3),
	"chest result popup"
)
Sim.signalOf(shop.Tab_passes, "Activated"):Fire()
frames(0.2)
check(
	shop.Body:FindFirstChild("DoubleCoins")
		and shop.Body:FindFirstChild("Cargo")
		and shop.Body:FindFirstChild("Vip")
		and shop.Body:FindFirstChild("Coins3000"),
	"passes and coin packs"
)
Sim.policyRestricted = true
Sim.signalOf(Players, "PlayerRemoving"):Fire(player)
task.wait(0.1)
Sim.signalOf(Players, "PlayerAdded"):Fire(player)
task.wait(0.3)
Data.load(player)
task.wait(0.2)
Sim.signalOf(shop.Tab_chest, "Activated"):Fire()
frames(0.3)
check(shop.Body:FindFirstChild("OpenChest") == nil, "restricted region: no chest button")
Sim.policyRestricted = false
Sim.signalOf(shop.Close, "Activated"):Fire()
check(not shop.Visible, "shop closes")

print("== language")
local Lang = Sim.require(game:GetService("StarterPlayer").StarterPlayerScripts.Client.Lang)
Lang.set("ru")
frames(0.1)
local ru = hud.Right.Controls.UpButton.Text
Lang.set("en")
frames(0.1)
check(
	ru ~= hud.Right.Controls.UpButton.Text
		and string.find(hud.Right.Controls.UpButton.Text, "UP", 1, true) ~= nil,
	"RU / EN labels"
)

print("== invite and debug")
Sim.signalOf(hud.TopLeft.InviteButton, "Activated"):Fire()
task.wait(0.1)
check((Sim.invites or 0) >= 1, "invite prompt")
check(ui:FindFirstChild("DebugToggle") ~= nil, "debug button in Studio")

for _, e in frameErrors do
	print("    " .. e)
end
check(#frameErrors == 0, "no errors in the frame loop")
local clientWarns = 0
for _, w in Sim.warnings or {} do
	if string.find(w, "[Client]", 1, true) or string.find(w, "error", 1, true) then
		clientWarns += 1
		print("    " .. w)
	end
end
check(clientWarns == 0, "no client handler errors")
print(string.format("\n%d failures", #failures))
process.exit(if #failures > 0 then 1 else 0)
