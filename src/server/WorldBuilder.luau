--[[
	WorldBuilder — строит мир из примитивов по модели World (те же числа, что в тестах):
	море, острова (пляж, скала, трава), дома с плоскими крышами, деревья, маяки, гавань
	с полем старта и почтой. Для каждой гонки — столбы чекпоинтов со стрелками ветра
	на высоте каждого слоя; в гавани — мачта ветров (флажки слоёв, перестраивается со сменой ветра).
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Make = require(Shared.Make)
local Rng = require(Shared.Rng)
local Winds = require(Shared.Winds)
local World = require(Shared.World)

local WorldBuilder = {}

local E = Config.World

local function rgb(t: { number }): Color3
	return Color3.fromRGB(t[1], t[2], t[3])
end
WorldBuilder.rgb = rgb

local function part(props): Part
	local p = {
		Anchored = true,
		TopSurface = Enum.SurfaceType.Smooth,
		BottomSurface = Enum.SurfaceType.Smooth,
		Material = Enum.Material.SmoothPlastic,
		CastShadow = true,
	}
	for k, v in props do
		p[k] = v
	end
	return Make("Part", p)
end
WorldBuilder.part = part

-- Вертикальный цилиндр: центр основания (x, y0, z), высота h, диаметр d
local function cylinder(props, x: number, y0: number, z: number, h: number, d: number): Part
	props.Shape = Enum.PartType.Cylinder
	props.Size = Vector3.new(h, d, d)
	props.CFrame = CFrame.new(x, y0 + h / 2, z) * CFrame.Angles(0, 0, math.pi / 2)
	return part(props)
end
WorldBuilder.cylinder = cylinder

function WorldBuilder.lighting()
	Lighting.ClockTime = 15.5
	Lighting.Brightness = 2.4
	Lighting.GlobalShadows = true
	Lighting.Ambient = Color3.fromRGB(110, 120, 140)
	Lighting.OutdoorAmbient = Color3.fromRGB(150, 160, 180)
	if not Lighting:FindFirstChildOfClass("Atmosphere") then
		Make("Atmosphere", {
			Density = 0.28,
			Offset = 0.1,
			Color = Color3.fromRGB(200, 220, 240),
			Decay = Color3.fromRGB(120, 150, 190),
			Glare = 0.2,
			Haze = 1.2,
			Parent = Lighting,
		})
	end
	if not Lighting:FindFirstChildOfClass("BloomEffect") then
		Make("BloomEffect", { Intensity = 0.4, Size = 24, Threshold = 1.6, Parent = Lighting })
	end
	pcall(function()
		local terrain = Workspace:FindFirstChildOfClass("Terrain")
		if terrain and not terrain:FindFirstChildOfClass("Clouds") then
			Make(
				"Clouds",
				{ Cover = 0.55, Density = 0.6, Color = Color3.fromRGB(255, 255, 255), Parent = terrain }
			)
		end
	end)
end

-------------------------------------------------------------------------------
-- Острова
-------------------------------------------------------------------------------
local SAND = Color3.fromRGB(232, 214, 160)
local ROCK = Color3.fromRGB(140, 128, 112)
local GRASS = Color3.fromRGB(96, 176, 86)
local WALLS = {
	Color3.fromRGB(250, 240, 220),
	Color3.fromRGB(240, 200, 170),
	Color3.fromRGB(200, 225, 240),
	Color3.fromRGB(245, 225, 140),
	Color3.fromRGB(210, 235, 200),
}
local ROOFS = {
	Color3.fromRGB(190, 80, 60),
	Color3.fromRGB(70, 110, 160),
	Color3.fromRGB(90, 140, 90),
	Color3.fromRGB(120, 90, 70),
}

local function house(w, h, folder: Instance, rng, isPost: boolean): Model
	local m = Make("Model", { Name = "House_" .. h.id, Attributes = { HouseId = h.id }, Parent = folder })
	local hgt = h.roof - h.base
	local wallColor = if isPost then Color3.fromRGB(255, 210, 120) else WALLS[rng:int(1, #WALLS)]
	part({
		Name = "Walls",
		Size = Vector3.new(h.size - 1, hgt - 1, h.size - 1),
		CFrame = CFrame.new(h.x, h.base + (hgt - 1) / 2, h.z),
		Color = wallColor,
		Parent = m,
	})
	local roof = part({
		Name = "Roof",
		Size = Vector3.new(h.size, 1, h.size),
		CFrame = CFrame.new(h.x, h.roof - 0.5, h.z),
		Color = if isPost then Color3.fromRGB(200, 60, 50) else ROOFS[rng:int(1, #ROOFS)],
		Material = Enum.Material.Slate,
		Parent = m,
	})
	m.PrimaryPart = roof
	-- площадка для посылок на крыше
	part({
		Name = "Pad",
		Size = Vector3.new(h.size - 5, 0.2, h.size - 5),
		CFrame = CFrame.new(h.x, h.roof + 0.1, h.z),
		Color = Color3.fromRGB(245, 245, 235),
		CanCollide = false,
		CanQuery = false,
		CastShadow = false,
		Parent = m,
	})
	part({
		Name = "Mark",
		Size = Vector3.new(h.size - 9, 0.25, 1.4),
		CFrame = CFrame.new(h.x, h.roof + 0.15, h.z) * CFrame.Angles(0, math.rad(45), 0),
		Color = Color3.fromRGB(230, 120, 40),
		CanCollide = false,
		CanQuery = false,
		CastShadow = false,
		Parent = m,
	})
	part({
		Name = "Mark2",
		Size = Vector3.new(h.size - 9, 0.25, 1.4),
		CFrame = CFrame.new(h.x, h.roof + 0.15, h.z) * CFrame.Angles(0, math.rad(-45), 0),
		Color = Color3.fromRGB(230, 120, 40),
		CanCollide = false,
		CanQuery = false,
		CastShadow = false,
		Parent = m,
	})
	-- дверь и окна на всех сторонах
	for side = 0, 3 do
		local rot = CFrame.new(h.x, h.base, h.z) * CFrame.Angles(0, side * math.pi / 2, 0)
		local face = (h.size - 1) / 2 + 0.05
		if side == 0 then
			part({
				Name = "Door",
				Size = Vector3.new(3, 5, 0.3),
				CFrame = rot * CFrame.new(0, 2.5, face),
				Color = Color3.fromRGB(110, 70, 40),
				CanCollide = false,
				Parent = m,
			})
		end
		for _, ox in { -4, 4 } do
			if hgt > 8 then
				part({
					Name = "Window",
					Size = Vector3.new(2.6, 2.6, 0.3),
					CFrame = rot * CFrame.new(ox, hgt - 4.2, face),
					Color = Color3.fromRGB(120, 180, 230),
					Material = Enum.Material.Glass,
					CanCollide = false,
					Parent = m,
				})
			end
		end
	end
	if isPost then
		local sign = part({
			Name = "Sign",
			Size = Vector3.new(10, 3, 0.4),
			CFrame = CFrame.new(h.x, h.roof + 2.2, h.z - h.size / 2 + 1),
			Color = Color3.fromRGB(200, 60, 50),
			CanCollide = false,
			Parent = m,
		})
		local gui = Make("SurfaceGui", { Face = Enum.NormalId.Front, PixelsPerStud = 30, Parent = sign })
		Make("TextLabel", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Font = Enum.Font.BuilderSansBold,
			TextScaled = true,
			TextColor3 = Color3.new(1, 1, 1),
			Text = "POST",
			Attributes = { TextKey = "sign.post" },
			Parent = gui,
		})
		local gui2 = Make("SurfaceGui", { Face = Enum.NormalId.Back, PixelsPerStud = 30, Parent = sign })
		Make("TextLabel", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Font = Enum.Font.BuilderSansBold,
			TextScaled = true,
			TextColor3 = Color3.new(1, 1, 1),
			Text = "POST",
			Attributes = { TextKey = "sign.post" },
			Parent = gui2,
		})
	end
	return m
end

local function tree(t, base: number, folder: Instance, rng)
	local trunkH = t.h * 0.45
	cylinder({
		Name = "Trunk",
		Color = Color3.fromRGB(120, 85, 55),
		Material = Enum.Material.Wood,
		CanCollide = false,
		Parent = folder,
	}, t.x, base, t.z, trunkH, 1.4)
	local leaf = Color3.fromRGB(60 + rng:int(0, 30), 140 + rng:int(0, 40), 60 + rng:int(0, 20))
	for i, k in { 1, 0.7 } do
		local d = t.h * 0.5 * k
		part({
			Name = "Leaves",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(d, d, d),
			CFrame = CFrame.new(t.x, base + trunkH + (i - 1) * d * 0.55 + d * 0.3, t.z),
			Color = leaf,
			Material = Enum.Material.Grass,
			CanCollide = false,
			Parent = folder,
		})
	end
end

local function lighthouse(lh, base: number, folder: Instance)
	local m = Make("Model", { Name = "Lighthouse", Parent = folder })
	local h = lh.top - base
	local n = 6
	for i = 1, n do
		cylinder({
			Name = "Tower",
			Color = if i % 2 == 0 then Color3.fromRGB(220, 60, 50) else Color3.fromRGB(245, 245, 240),
			Parent = m,
		}, lh.x, base + (i - 1) * h / n, lh.z, h / n, E.LighthouseR * 2)
	end
	local lamp = cylinder({
		Name = "Lamp",
		Color = Color3.fromRGB(255, 230, 140),
		Material = Enum.Material.Neon,
		CanCollide = false,
		Parent = m,
	}, lh.x, lh.top, lh.z, 3, E.LighthouseR * 1.6)
	Make("PointLight", { Range = 30, Brightness = 2, Color = Color3.fromRGB(255, 220, 140), Parent = lamp })
	cylinder(
		{ Name = "Cap", Color = Color3.fromRGB(60, 60, 70), Parent = m },
		lh.x,
		lh.top + 3,
		lh.z,
		1,
		E.LighthouseR * 2.2
	)
end

local function island(w, isl, folder: Instance, rng): Model
	local m =
		Make("Model", { Name = "Island_" .. isl.id, Attributes = { IslandId = isl.id }, Parent = folder })
	-- пляж до уровня BeachH, уходит под воду
	cylinder(
		{ Name = "Beach", Color = SAND, Material = Enum.Material.Sand, Parent = m },
		isl.x,
		-8,
		isl.z,
		E.BeachH + 8,
		isl.r * 2
	)
	local inner = (isl.r - E.Beach) * 2
	cylinder(
		{ Name = "Cliff", Color = ROCK, Material = Enum.Material.Rock, Parent = m },
		isl.x,
		0,
		isl.z,
		isl.top - 0.8,
		inner
	)
	cylinder(
		{ Name = "Top", Color = GRASS, Material = Enum.Material.Grass, Parent = m },
		isl.x,
		isl.top - 0.8,
		isl.z,
		0.8,
		inner
	)
	for i, hid in isl.houses do
		house(w, w.houses[hid], m, rng, isl.harbor and i == 1)
	end
	for _, t in isl.trees do
		tree(t, isl.top, m, rng)
	end
	if isl.lighthouse then
		lighthouse(isl.lighthouse, isl.top, m)
	end
	if isl.harbor then
		-- поле старта: светлый круг
		cylinder({
			Name = "Field",
			Color = Color3.fromRGB(150, 210, 120),
			Material = Enum.Material.Grass,
			CanCollide = false,
			CastShadow = false,
			Parent = m,
		}, isl.x, isl.top, isl.z, 0.1, 140)
		-- причал
		for i = 0, 3 do
			part({
				Name = "Pier",
				Size = Vector3.new(8, 1, 10),
				CFrame = CFrame.new(isl.x, E.BeachH - 0.5, isl.z + isl.r + 4 + i * 10),
				Color = Color3.fromRGB(150, 110, 70),
				Material = Enum.Material.WoodPlanks,
				Parent = m,
			})
		end
	end
	return m
end

-- Строит весь архипелаг. Возвращает папку.
function WorldBuilder.build(w): Folder
	local old = Workspace:FindFirstChild("Archipelago")
	if old then
		old:Destroy()
	end
	local folder = Make("Folder", { Name = "Archipelago" })
	part({
		Name = "Sea",
		Size = Vector3.new(4096, 2, 4096),
		CFrame = CFrame.new(0, E.Water - 1, 0),
		Color = Color3.fromRGB(40, 125, 190),
		Material = Enum.Material.SmoothPlastic,
		Reflectance = 0.08,
		Transparency = 0.08,
		CastShadow = false,
		Parent = folder,
	})
	local rng = Rng.new(w.seed * 31 + 1)
	for _, isl in w.islands do
		island(w, isl, folder, rng)
	end
	folder.Parent = Workspace
	return folder
end

-- Место появления в свободном полёте: поле гавани, по кругу
function WorldBuilder.spawnPoint(w, i: number): (number, number, number)
	local h = w.islands[1]
	local a = (i % 12) / 12 * math.pi * 2
	local r = 22 + math.floor(i / 12) % 3 * 16
	local x, z = h.x + math.cos(a) * r, h.z + math.sin(a) * r
	return x, World.groundAt(w, x, z), z
end

-------------------------------------------------------------------------------
-- Стрелки ветра (мачта в гавани и чекпоинты)
-------------------------------------------------------------------------------
-- Стрелка «древко + шеврон», указывает по ветру слоя l
local function arrow(parent: Instance, l, x: number, y: number, z: number, scale: number, name: string)
	local m = Make("Model", { Name = name, Attributes = { Layer = l.index }, Parent = parent })
	local color = rgb(l.color)
	local at = Vector3.new(x, y, z)
	local dir = CFrame.lookAt(at, at + Vector3.new(math.cos(l.angle), 0, math.sin(l.angle)))
	local function bar(cf: CFrame, len: number)
		part({
			Name = "Bar",
			Size = Vector3.new(1.2 * scale, 1.2 * scale, len),
			CFrame = cf,
			Color = color,
			Material = Enum.Material.Neon,
			CanCollide = false,
			CanQuery = false,
			CastShadow = false,
			Parent = m,
		})
	end
	bar(dir, 8 * scale)
	for _, s in { 1, -1 } do
		bar(
			dir
				* CFrame.new(0, 0, -4 * scale)
				* CFrame.Angles(0, math.rad(35 * s), 0)
				* CFrame.new(0, 0, 2 * scale),
			4 * scale
		)
	end
	return m
end

-- Мачта ветров в гавани (перестраивается при смене ветра)
function WorldBuilder.windMast(w, winds)
	local folder = Workspace:FindFirstChild("WindMast")
	if folder then
		folder:Destroy()
	end
	folder = Make("Folder", { Name = "WindMast" })
	local h = w.islands[1]
	local x, z = h.x - 6, h.z - h.r + E.Beach + 4
	cylinder({
		Name = "Pole",
		Color = Color3.fromRGB(235, 235, 240),
		CanCollide = false,
		Parent = folder,
	}, x, h.top, z, Config.Wind.Ceiling - h.top, 1.2)
	for _, l in winds.layers do
		arrow(folder, l, x, Winds.mid(winds, l.index), z, 1.6, "Flag" .. l.index)
	end
	arrow(folder, winds.surface, x, h.top + 12, z, 1.2, "Flag0")
	folder.Parent = Workspace
	return folder
end

-- Чекпоинты гонки: полупрозрачный столб на всю высоту, кольца, номер, стрелки слоёв
function WorldBuilder.course(course, winds): Folder
	local old = Workspace:FindFirstChild("Course")
	if old then
		old:Destroy()
	end
	local folder = Make("Folder", { Name = "Course" })
	local n = #course.checkpoints
	for i, c in course.checkpoints do
		local finish = i == n
		local color = if finish then Color3.fromRGB(255, 215, 70) else Color3.fromRGB(120, 230, 255)
		local m = Make("Model", { Name = "CP" .. i, Attributes = { Index = i, Finish = finish } })
		local column = cylinder({
			Name = "Column",
			Color = color,
			Material = Enum.Material.ForceField,
			Transparency = 0.2,
			CanCollide = false,
			CanQuery = false,
			CastShadow = false,
			Parent = m,
		}, c.x, 0, c.z, Config.Wind.Ceiling + 20, c.r * 2)
		m.PrimaryPart = column
		for _, y in { Config.Wind.Bottom, Config.Wind.Ceiling } do
			cylinder({
				Name = "Ring",
				Color = color,
				Material = Enum.Material.Neon,
				Transparency = 0.3,
				CanCollide = false,
				CanQuery = false,
				CastShadow = false,
				Parent = m,
			}, c.x, y, c.z, 0.6, c.r * 2 + 2)
		end
		for _, l in winds.layers do
			arrow(m, l, c.x, Winds.mid(winds, l.index), c.z, 2.2, "Arrow" .. l.index)
		end
		local label = part({
			Name = "Label",
			Size = Vector3.new(1, 1, 1),
			CFrame = CFrame.new(c.x, Config.Wind.Ceiling + 24, c.z),
			Transparency = 1,
			CanCollide = false,
			CanQuery = false,
			Parent = m,
		})
		local gui = Make("BillboardGui", {
			Name = "Tag",
			Size = UDim2.fromOffset(160, 70),
			AlwaysOnTop = true,
			MaxDistance = 3000,
			Parent = label,
		})
		Make("TextLabel", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Font = Enum.Font.BuilderSansBold,
			TextScaled = true,
			TextColor3 = color,
			TextStrokeTransparency = 0.3,
			Text = if finish then "FINISH" else tostring(i),
			Attributes = if finish then { TextKey = "sign.finish" } else nil,
			Parent = gui,
		})
		m.Parent = folder
	end
	folder.Parent = Workspace
	return folder
end

function WorldBuilder.clearCourse()
	local old = Workspace:FindFirstChild("Course")
	if old then
		old:Destroy()
	end
end

return WorldBuilder
