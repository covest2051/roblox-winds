--[[
	BalloonBuilder — модель шара из примитивов:
	  корзина (корень, PrimaryPart) + сиденье, стропы, горелка (Fire + свет, включает клиент
	  по атрибуту Ctl), оболочка из 7 дисков и шара сверху (узор и материал — косметика),
	  след (Trail), табличка с именем.
	Ленты на углах корзины рисует каждый клиент сам (атрибут Ribbon) — они развеваются по ветру.

	Шар игрока: детали сварены с корзиной, корзина не закреплена, движет её клиент через
	LinearVelocity «Lift». Шар ИИ: всё закреплено, двигает сервер (PivotTo).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Catalog = require(Shared.Catalog)
local Config = require(Shared.Config)
local Make = require(Shared.Make)

local BalloonBuilder = {}

local RH = Config.Flight.RootH
local THROAT = RH + 6 -- низ оболочки над центром корзины
local DISC_H = 2.2
local RADII = { 2.6, 4.2, 5.6, 6.8, 7.8, 8.5, 9 }
local TOP_D = 18

BalloonBuilder.Height = THROAT + #RADII * DISC_H + TOP_D / 2 -- верх оболочки над корнем

local function rgb(t: { number }): Color3
	return Color3.fromRGB(t[1], t[2], t[3])
end

local MATERIALS = {
	plastic = Enum.Material.SmoothPlastic,
	neon = Enum.Material.Neon,
	glass = Enum.Material.Glass,
	foil = Enum.Material.Foil,
}

-- Цвет диска i (1..7) и верха (i = 8) для узора
function BalloonBuilder.discColor(item, i: number): { number }
	local c = item.colors
	local p = item.pattern
	if p == "stripes" then
		return if i % 2 == 1 then c[1] else c[2]
	elseif p == "twotone" then
		return if i <= 4 then c[2] else c[1]
	elseif p == "band" then
		return if i == 5 or i == 6 then c[2] else c[1]
	elseif p == "patch" or p == "rainbow" then
		if i == 8 then
			return c[1]
		end
		return c[(i - 1) % #c + 1]
	end
	return c[1]
end

local function weldTo(root: BasePart, p: BasePart)
	Make("WeldConstraint", { Part0 = root, Part1 = p, Parent = p })
end

local function envelope(model: Model, root: BasePart, item, anchored: boolean)
	local old = model:FindFirstChild("Envelope")
	if old then
		old:Destroy()
	end
	local env = Make("Model", { Name = "Envelope" })
	local mat = MATERIALS[item.material or "plastic"] or Enum.Material.SmoothPlastic
	local base = root.CFrame
	local function add(p: BasePart)
		p.Anchored = anchored
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Massless = true
		p.Material = mat
		if item.material == "glass" then
			p.Transparency = 0.35
		elseif item.material == "foil" then
			p.Reflectance = 0.25
		end
		p.Parent = env
		if not anchored then
			weldTo(root, p)
		end
	end
	for i, r in RADII do
		local y = THROAT + (i - 0.5) * DISC_H
		add(Make("Part", {
			Name = "Disc" .. i,
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(DISC_H + 0.02, r * 2, r * 2),
			CFrame = base * CFrame.new(0, y, 0) * CFrame.Angles(0, 0, math.pi / 2),
			Color = rgb(BalloonBuilder.discColor(item, i)),
			Attributes = { Disc = i },
		}))
	end
	add(Make("Part", {
		Name = "Top",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(TOP_D, TOP_D, TOP_D),
		CFrame = base * CFrame.new(0, THROAT + #RADII * DISC_H, 0),
		Color = rgb(BalloonBuilder.discColor(item, 8)),
		Attributes = { Disc = 8 },
	}))
	env:SetAttribute("Item", item.id)
	env:SetAttribute("Rainbow", item.rainbow == true)
	env.Parent = model
end

local function trail(model: Model, root: BasePart, item)
	for _, n in { "Trail", "TrailA", "TrailB" } do
		local old = root:FindFirstChild(n)
		if old then
			old:Destroy()
		end
	end
	local w = (item.width or 1) * 1.4
	local a0 =
		Make("Attachment", { Name = "TrailA", Position = Vector3.new(-w, -RH + 0.3, 0), Parent = root })
	local a1 = Make("Attachment", { Name = "TrailB", Position = Vector3.new(w, -RH + 0.3, 0), Parent = root })
	local colors = item.colors
	local seq
	if item.rainbow then
		seq = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 70, 70)),
			ColorSequenceKeypoint.new(0.2, Color3.fromRGB(255, 170, 50)),
			ColorSequenceKeypoint.new(0.4, Color3.fromRGB(255, 240, 70)),
			ColorSequenceKeypoint.new(0.6, Color3.fromRGB(80, 220, 110)),
			ColorSequenceKeypoint.new(0.8, Color3.fromRGB(70, 160, 255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(170, 100, 255)),
		})
	else
		seq = ColorSequence.new(rgb(colors[1]), rgb(colors[2]))
	end
	Make("Trail", {
		Name = "Trail",
		Attachment0 = a0,
		Attachment1 = a1,
		Color = seq,
		Lifetime = 1.8,
		MinLength = 0.2,
		FaceCamera = true,
		LightEmission = 0.5,
		Transparency = NumberSequence.new(0.15, 1),
		WidthScale = NumberSequence.new(1, 0.2),
		Attributes = { Item = item.id },
		Parent = root,
	})
	_ = model
end

export type Style = { balloon: string, ribbon: string, trail: string }

function BalloonBuilder.build(
	style: Style,
	opts: {
		name: string,
		anchored: boolean,
		cf: CFrame,
		ai: boolean?,
		owner: number?,
		vip: boolean?,
	}
): Model
	local anchored = opts.anchored
	local model = Make("Model", {
		Name = opts.name,
		Attributes = {
			Ctl = 0,
			Ai = opts.ai == true,
			Owner = opts.owner or 0,
			Ribbon = style.ribbon,
		},
	})
	local root = Make("Part", {
		Name = "Basket",
		Size = Vector3.new(5, RH * 2, 5),
		CFrame = opts.cf,
		Color = Color3.fromRGB(150, 105, 60),
		Material = Enum.Material.WoodPlanks,
		Anchored = anchored,
		CanCollide = true,
		TopSurface = Enum.SurfaceType.Smooth,
		BottomSurface = Enum.SurfaceType.Smooth,
		Parent = model,
	})
	model.PrimaryPart = root
	local function deco(props)
		props.Anchored = anchored
		props.CanCollide = false
		props.CanQuery = false
		props.CanTouch = false
		props.Massless = true
		props.TopSurface = Enum.SurfaceType.Smooth
		props.BottomSurface = Enum.SurfaceType.Smooth
		props.Parent = model
		local p = Make("Part", props)
		if not anchored then
			weldTo(root, p)
		end
		return p
	end
	-- обод корзины
	for i = 0, 3 do
		local rot = CFrame.Angles(0, i * math.pi / 2, 0)
		deco({
			Name = "Rim",
			Size = Vector3.new(5.4, 0.5, 0.5),
			CFrame = opts.cf * rot * CFrame.new(0, RH, 2.45),
			Color = Color3.fromRGB(100, 65, 35),
			Material = Enum.Material.Wood,
		})
	end
	-- стропы от углов к горловине
	for _, c in { { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } } do
		local a = (opts.cf * CFrame.new(c[1] * 2.3, RH, c[2] * 2.3)).Position
		local b = (opts.cf * CFrame.new(c[1] * 2.2, THROAT, c[2] * 2.2)).Position
		deco({
			Name = "Rope",
			Size = Vector3.new(0.18, 0.18, (b - a).Magnitude),
			CFrame = CFrame.lookAt((a + b) / 2, b),
			Color = Color3.fromRGB(60, 50, 40),
		})
	end
	-- горелка
	local burner = deco({
		Name = "Burner",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(1.4, 2, 2),
		CFrame = opts.cf * CFrame.new(0, THROAT - 1.4, 0) * CFrame.Angles(0, 0, math.pi / 2),
		Color = Color3.fromRGB(70, 70, 80),
		Material = Enum.Material.Metal,
	})
	Make("Fire", {
		Name = "Flame",
		Size = 5,
		Heat = 12,
		Color = Color3.fromRGB(255, 150, 40),
		SecondaryColor = Color3.fromRGB(255, 230, 120),
		Enabled = false,
		Parent = burner,
	})
	Make("PointLight", {
		Name = "Glow",
		Range = 18,
		Brightness = 3,
		Color = Color3.fromRGB(255, 170, 70),
		Enabled = false,
		Parent = burner,
	})
	-- сиденье (только у игроков)
	if not opts.ai then
		local seat = Make("Seat", {
			Name = "Seat",
			Size = Vector3.new(2, 0.4, 2),
			CFrame = opts.cf * CFrame.new(0, -0.4, 0.6),
			Transparency = 1,
			Anchored = anchored,
			CanCollide = false,
			CanQuery = false,
			CanTouch = false,
			Massless = true,
			Parent = model,
		})
		if not anchored then
			weldTo(root, seat)
		end
	end
	-- табличка
	local tag = Make("BillboardGui", {
		Name = "Tag",
		Size = UDim2.fromOffset(220, 46),
		StudsOffset = Vector3.new(0, BalloonBuilder.Height + 3, 0),
		AlwaysOnTop = false,
		MaxDistance = 450,
		Parent = root,
	})
	Make("TextLabel", {
		Name = "NameLabel",
		Size = UDim2.fromScale(1, 0.6),
		BackgroundTransparency = 1,
		Font = Enum.Font.BuilderSansBold,
		TextScaled = true,
		TextColor3 = if opts.vip then Color3.fromRGB(255, 210, 70) else Color3.new(1, 1, 1),
		TextStrokeTransparency = 0.4,
		Text = (if opts.vip then "★ " else "") .. opts.name .. (if opts.ai then " · AI" else ""),
		Parent = tag,
	})
	Make("TextLabel", {
		Name = "Info",
		Size = UDim2.fromScale(1, 0.4),
		Position = UDim2.fromScale(0, 0.6),
		BackgroundTransparency = 1,
		Font = Enum.Font.BuilderSans,
		TextScaled = true,
		TextColor3 = Color3.fromRGB(220, 235, 255),
		TextStrokeTransparency = 0.5,
		Text = "",
		Parent = tag,
	})
	-- управление для шара игрока
	if not anchored then
		local center = Make("Attachment", { Name = "Center", Parent = root })
		Make("LinearVelocity", {
			Name = "Lift",
			Attachment0 = center,
			VelocityConstraintMode = Enum.VelocityConstraintMode.Vector,
			RelativeTo = Enum.ActuatorRelativeTo.World,
			VectorVelocity = Vector3.zero,
			MaxForce = math.huge,
			Parent = root,
		})
		Make("AlignOrientation", {
			Name = "Upright",
			Mode = Enum.OrientationAlignmentMode.OneAttachment,
			Attachment0 = center,
			RigidityEnabled = true,
			CFrame = CFrame.new(),
			Parent = root,
		})
	end
	BalloonBuilder.restyle(model, style)
	return model
end

-- Сменить косметику на уже построенном шаре
function BalloonBuilder.restyle(model: Model, style: Style)
	local root = model.PrimaryPart :: BasePart
	local anchored = root.Anchored and model:GetAttribute("Ai") == true
	local b = Catalog.get(style.balloon) or Catalog.get(Catalog.Default.balloon)
	local t = Catalog.get(style.trail) or Catalog.get(Catalog.Default.trail)
	envelope(model, root, b, anchored)
	trail(model, root, t)
	model:SetAttribute("Ribbon", style.ribbon)
	model:SetAttribute("Balloon", (b :: any).id)
	model:SetAttribute("TrailItem", (t :: any).id)
end

function BalloonBuilder.setVip(model: Model, vip: boolean, name: string)
	local root = model.PrimaryPart
	local tag = root and root:FindFirstChild("Tag")
	local label = tag and tag:FindFirstChild("NameLabel")
	if label and label:IsA("TextLabel") then
		label.Text = (if vip then "★ " else "") .. name
		label.TextColor3 = if vip then Color3.fromRGB(255, 210, 70) else Color3.new(1, 1, 1)
	end
end

return BalloonBuilder
