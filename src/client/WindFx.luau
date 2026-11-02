--[[
	WindFx — всё, что клиент рисует сам (ветер детерминирован, ничего не реплицируется):
	  • ленты ветра: в каждом слое летят цветные полосы его цвета вокруг камеры;
	    свой слой ярче — видно, куда несёт сейчас и что выше/ниже;
	  • ленты на корзинах всех шаров (косметика): смотрят по ветру своей высоты БЕЗ задержки —
	    при смене слоя разворачиваются раньше шара, это первый сигнал «поворот пошёл»;
	  • пламя горелки (своё — в тот же кадр, чужие — по атрибуту Ctl), радужные оболочки;
	  • гонка: следующий чекпоинт ярко, остальные тускло;
	  • доставка: маяк над крышей-целью и метка «куда упадёт посылка» с траекторией.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Catalog = require(Shared.Catalog)
local Config = require(Shared.Config)
local Make = require(Shared.Make)
local Parcel = require(Shared.Parcel)
local Winds = require(Shared.Winds)

local Sky = require(script.Parent.Sky)
local Controls = require(script.Parent.Controls)

local WindFx = {}

local player = Players.LocalPlayer
local RH = Config.Flight.RootH
local W = Config.Wind

local folder: Folder? = nil
local streaks: { { part: BasePart, layer: number, x: number, y: number, z: number } } = {}
local ribbons: { [Model]: { BasePart } } = {}
local t = 0
local orders: { any } = {}
local beacons: { BasePart } = {}
local marker: BasePart? = nil
local dots: { BasePart } = {}
local predictAcc = 0
local cpAcc = 0
local lastLanding = nil

WindFx.landing = nil :: any -- последняя метка падения (для HUD)

local AREA = 170 -- радиус облака лент вокруг камеры
local PER_LAYER = 18
local PER_SURFACE = 8

local function rgb(c: { number }): Color3
	return Color3.fromRGB(c[1], c[2], c[3])
end

local function rand(a: number, b: number): number
	return a + math.random() * (b - a)
end

local function fxPart(props): Part
	local p = {
		Anchored = true,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		CastShadow = false,
		Material = Enum.Material.Neon,
	}
	for k, v in props do
		p[k] = v
	end
	return Make("Part", p)
end

local function focus(): Vector3
	local st = Controls.state()
	if st then
		return Vector3.new(st.x, st.y, st.z)
	end
	local cam = Workspace.CurrentCamera
	return if cam then cam.Focus.Position else Vector3.zero
end

-------------------------------------------------------------------------------
-- Ленты ветра
-------------------------------------------------------------------------------
local function layerRange(k: number): (number, number)
	if k == 0 then
		return 8, W.Bottom - 3
	end
	local lo = W.Bottom + (k - 1) * W.Thick
	return lo + 3, lo + W.Thick - 3
end

local function placeStreak(s, center: Vector3, upwind: boolean)
	local winds = Sky.winds()
	local l = if winds then Winds.layer(winds, s.layer) else nil
	local lo, hi = layerRange(s.layer)
	s.y = rand(lo, hi)
	if upwind and l and l.speed > 0 then
		-- с наветренной стороны: полосы «прилетают» в кадр
		local a = l.angle + math.pi + rand(-1.1, 1.1)
		local r = rand(AREA * 0.6, AREA)
		s.x, s.z = center.X + math.cos(a) * r, center.Z + math.sin(a) * r
	else
		local a = rand(0, math.pi * 2)
		local r = math.sqrt(math.random()) * AREA
		s.x, s.z = center.X + math.cos(a) * r, center.Z + math.sin(a) * r
	end
end

local function recolor()
	local winds = Sky.winds()
	if not winds then
		return
	end
	for _, s in streaks do
		local l = Winds.layer(winds, s.layer)
		s.part.Color = rgb(l.color)
		s.part.Size = Vector3.new(0.35, 0.35, 5 + l.speed * 0.45)
	end
end

local function buildStreaks()
	for k = 0, W.Layers do
		local n = if k == 0 then PER_SURFACE else PER_LAYER
		for _ = 1, n do
			local p = fxPart({ Name = "Streak", Size = Vector3.new(0.35, 0.35, 10), Transparency = 0.5 })
			p.Parent = folder
			local s = { part = p, layer = k, x = 0, y = 0, z = 0 }
			placeStreak(s, Vector3.zero, false)
			table.insert(streaks, s)
		end
	end
	recolor()
end

local function updateStreaks(dt: number)
	local winds = Sky.winds()
	if not winds then
		return
	end
	local c = focus()
	local myLayer = Controls.layer() or Winds.layerAt(winds, c.Y)
	local parts, cfs = {}, {}
	for _, s in streaks do
		local l = Winds.layer(winds, s.layer)
		s.x += l.wx * dt
		s.z += l.wz * dt
		local dx, dz = s.x - c.X, s.z - c.Z
		if dx * dx + dz * dz > AREA * AREA then
			placeStreak(s, c, true)
		end
		local pos = Vector3.new(s.x, s.y, s.z)
		local dir = Vector3.new(l.wx, 0, l.wz)
		if dir.Magnitude < 1e-3 then
			dir = Vector3.xAxis
		end
		table.insert(parts, s.part)
		table.insert(cfs, CFrame.lookAt(pos, pos + dir))
		local near = math.abs(s.layer - myLayer)
		s.part.Transparency = if near == 0 then 0.25 elseif near == 1 then 0.5 else 0.72
	end
	Workspace:BulkMoveTo(parts, cfs, Enum.BulkMoveMode.FireCFrameChanged)
end

-------------------------------------------------------------------------------
-- Шары: ленты на корзине, пламя, радуга
-------------------------------------------------------------------------------
local CORNERS = { { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }

local function ribbonsFor(model: Model): { BasePart }
	local list = ribbons[model]
	local id = model:GetAttribute("Ribbon")
	if list and list[1] and list[1]:GetAttribute("Item") == id then
		return list
	end
	if list then
		for _, p in list do
			p:Destroy()
		end
	end
	local item = Catalog.get(id) or Catalog.get(Catalog.Default.ribbon)
	local it = item :: Catalog.Item
	list = {}
	for i = 1, #CORNERS * 2 do
		local corner = math.floor((i - 1) / 2) + 1
		local p = fxPart({
			Name = "Ribbon",
			Size = Vector3.new(0.12, 0.7, 2.6),
			Color = rgb(it.colors[(corner - 1) % #it.colors + 1]),
			Material = if it.material == "neon" then Enum.Material.Neon else Enum.Material.SmoothPlastic,
			Attributes = { Item = it.id },
		})
		p.Parent = folder
		table.insert(list, p)
	end
	ribbons[model] = list
	return list
end

local function updateBalloons()
	local winds = Sky.winds()
	local bf = Workspace:FindFirstChild("Balloons")
	if not winds or not bf then
		return
	end
	local mine = Controls.balloon()
	local seen = {}
	local parts, cfs = {}, {}
	for _, model in bf:GetChildren() do
		local root = model:IsA("Model") and model.PrimaryPart
		if not root then
			continue
		end
		seen[model] = true
		local cf = root.CFrame
		local p = cf.Position
		-- пламя: своё — сразу по нажатию, чужое — по атрибуту
		local ctl = if model == mine then Controls.ctl() else (model:GetAttribute("Ctl") or 0)
		local burner = model:FindFirstChild("Burner")
		if burner then
			local fire = burner:FindFirstChild("Flame")
			local glow = burner:FindFirstChild("Glow")
			if fire then
				(fire :: Fire).Enabled = ctl > 0
			end
			if glow then
				(glow :: PointLight).Enabled = ctl > 0
			end
		end
		-- радужная оболочка
		local env = model:FindFirstChild("Envelope")
		if env and env:GetAttribute("Rainbow") then
			for _, d in env:GetChildren() do
				local i = d:GetAttribute("Disc")
				if i and d:IsA("BasePart") then
					d.Color = Color3.fromHSV((t * 0.12 + i * 0.11) % 1, 0.75, 1)
				end
			end
		end
		-- ленты: по ветру своей высоты, без задержки
		local wx, wz = Winds.at(winds, p.X, p.Y - RH, p.Z)
		local wind = Vector3.new(wx, 0, wz)
		local speed = wind.Magnitude
		local dir = if speed > 0.1 then wind / speed else Vector3.xAxis
		local droop = math.clamp(1 - speed / 30, 0.15, 0.9)
		local list = ribbonsFor(model :: Model)
		for i, part in list do
			local corner = CORNERS[math.floor((i - 1) / 2) + 1]
			local seg = (i - 1) % 2
			local base = (cf * CFrame.new(corner[1] * 2.5, RH, corner[2] * 2.5)).Position
			local side = Vector3.new(-dir.Z, 0, dir.X)
			local wave = math.sin(t * 9 + i * 1.7) * 0.35
			local d = (dir + Vector3.new(0, -droop, 0) + side * wave).Unit
			local center = base + d * (1.3 + seg * 2.6)
			table.insert(parts, part)
			table.insert(cfs, CFrame.lookAt(center, center + d))
		end
	end
	for model, list in ribbons do
		if not seen[model] then
			for _, p in list do
				p:Destroy()
			end
			ribbons[model] = nil
		end
	end
	if #parts > 0 then
		Workspace:BulkMoveTo(parts, cfs, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

-------------------------------------------------------------------------------
-- Гонка: следующий чекпоинт ярко
-------------------------------------------------------------------------------
local function updateCourse()
	local course = Workspace:FindFirstChild("Course")
	if not course then
		return
	end
	local racing = player:GetAttribute("Racing") == true
	local nextI = (player:GetAttribute("Cp") or 0) + 1
	for _, m in course:GetChildren() do
		local i = m:GetAttribute("Index")
		local active = not racing or i == nextI
		for _, d in m:GetDescendants() do
			if d:IsA("BasePart") then
				if d.Name == "Column" then
					d.Transparency = if active then 0.2 else 0.85
				elseif d.Name == "Bar" then
					d.LocalTransparencyModifier = if active then 0 else 1
				end
			end
		end
	end
end

-------------------------------------------------------------------------------
-- Доставка
-------------------------------------------------------------------------------
function WindFx.setOrders(list: { any })
	orders = list or {}
	for _, b in beacons do
		b:Destroy()
	end
	beacons = {}
	for _, o in orders do
		local beam = fxPart({
			Name = "Beacon",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(220, 3, 3),
			CFrame = CFrame.new(o.x, o.roof + 110, o.z) * CFrame.Angles(0, 0, math.pi / 2),
			Color = Color3.fromRGB(255, 205, 60),
			Transparency = 0.35,
		})
		beam.Parent = folder
		local ring = fxPart({
			Name = "RoofRing",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.3, 24, 24),
			CFrame = CFrame.new(o.x, o.roof + 0.3, o.z) * CFrame.Angles(0, 0, math.pi / 2),
			Color = Color3.fromRGB(255, 205, 60),
			Transparency = 0.45,
		})
		ring.Parent = folder
		table.insert(beacons, beam)
		table.insert(beacons, ring)
	end
end

local function updateMarker(dt: number)
	predictAcc += dt
	if predictAcc < 0.1 then
		return
	end
	predictAcc = 0
	local st = Controls.state()
	local world, winds = Sky.world(), Sky.winds()
	local show = st ~= nil
		and world ~= nil
		and winds ~= nil
		and #orders > 0
		and player:GetAttribute("Racing") ~= true
	if marker then
		marker.Transparency = if show then 0.2 else 1
	end
	for _, d in dots do
		d.Transparency = if show then 0.35 else 1
	end
	if not show then
		WindFx.landing = nil
		return
	end
	local s = st :: any
	local target = orders[1]
	local landing = Parcel.predict(winds, world, s.x, s.y, s.z, true, target and target.house)
	local hit = false
	for _, o in orders do
		local l = if o.house == (target and target.house)
			then landing
			else Parcel.predict(winds, world, s.x, s.y, s.z, false, o.house)
		if Parcel.hits(l, o.house) then
			hit = true
		end
	end
	WindFx.landing = { x = landing.x, y = landing.y, z = landing.z, hit = hit }
	lastLanding = landing
	local m = marker :: BasePart
	m.CFrame = CFrame.new(landing.x, landing.y + 0.4, landing.z) * CFrame.Angles(0, 0, math.pi / 2)
	m.Color = if hit then Color3.fromRGB(90, 255, 120) else Color3.fromRGB(255, 255, 255)
	local path = landing.path or {}
	for i, d in dots do
		local p = path[math.floor(i * #path / (#dots + 1)) + 1]
		if p then
			d.CFrame = CFrame.new(p.x, p.y, p.z)
		else
			d.Transparency = 1
		end
	end
end

-------------------------------------------------------------------------------
function WindFx.build()
	folder = Make("Folder", { Name = "WindFx", Parent = Workspace })
	buildStreaks()
	Sky.onWinds(recolor)
	marker = fxPart({
		Name = "DropMarker",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.3, 9, 9),
		Color = Color3.new(1, 1, 1),
		Transparency = 1,
	});
	(marker :: Part).Parent = folder
	for i = 1, 8 do
		local d = fxPart({
			Name = "Dot" .. i,
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(1.1, 1.1, 1.1),
			Color = Color3.fromRGB(255, 240, 200),
			Transparency = 1,
		})
		d.Parent = folder
		table.insert(dots, d)
	end
end

function WindFx.update(dt: number)
	t += dt
	updateStreaks(dt)
	updateBalloons()
	updateMarker(dt)
	cpAcc += dt
	if cpAcc >= 0.2 then
		cpAcc = 0
		updateCourse()
	end
	_ = lastLanding
end

return WindFx
