--[[
	Hud — интерфейс:
	  • слева сверху: монеты, Магазин, Позвать друзей;
	  • сверху по центру: баннер (гонка через N · Участвую ✓ / следующий чекпоинт, время), тосты;
	  • справа снизу: две большие кнопки ▲ ВЫШЕ / ▼ НИЖЕ (держать) и слева от них
	    ЛЕСТНИЦА ВЕТРОВ: строка на каждый слой, стрелка повёрнута относительно камеры
	    (куда понесёт на этой высоте), слои «к цели» подсвечены, маркер «ты» на своей высоте;
	  • справа сверху: места в гонке; слева снизу: заказ доставки;
	  • отсчёт, «намок», итоги гонки.
	Состояние берётся из событий сервера и позиции своего шара; атрибуты — только как подсказка,
	интерфейс не ломается, если они ещё не пришли.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Parcel = require(Shared.Parcel)
local Winds = require(Shared.Winds)

local Ui = require(script.Parent.Ui)
local Lang = require(script.Parent.Lang)
local Sky = require(script.Parent.Sky)
local Controls = require(script.Parent.Controls)

local Make = Ui.Make
local C = Ui.colors
local player = Players.LocalPlayer
local W = Config.Wind

local Hud = {}

Hud.onShop = nil :: ((string?) -> ())?
Hud.onInvite = nil :: (() -> ())?
Hud.onOptIn = nil :: ((boolean) -> ())?
Hud.onSkip = nil :: (() -> ())?

local refs: { [string]: any } = {}
local LADDER_H = 300
local LADDER_H_TOTAL = LADDER_H + 36
local rows: { [number]: { frame: Frame, arrow: TextLabel, speed: TextLabel, mark: TextLabel } } = {}
local toasts: { Frame } = {}
local coinShown = 0
local orders: { any } = {}
local race: { [string]: any }? = nil -- { checkpoints, goAt, total }
local standings: { any } = {}
local resultsUntil = 0
local splashUntil = 0
local goShownUntil = 0
local tipStage = 0
local tipUntil = 0

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function rgb(c: { number }): Color3
	return Color3.fromRGB(c[1], c[2], c[3])
end

local function isTouch(): boolean
	local ok, v = pcall(function()
		return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
	end)
	return ok and v == true
end

-------------------------------------------------------------------------------
-- Построение
-------------------------------------------------------------------------------
local function buildTopLeft(root: Instance)
	local box = Ui.scaled(
		Make("Frame", {
			Name = "TopLeft",
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(16, 16),
			Size = UDim2.fromOffset(190, 160),
			Parent = root,
		}),
		0.75
	)
	Make("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = box })
	local pill = Ui.panel({ Name = "Coins", LayoutOrder = 1, Size = UDim2.fromOffset(190, 46), Parent = box })
	local icon = Make("Frame", {
		Size = UDim2.fromOffset(24, 24),
		Position = UDim2.fromOffset(12, 11),
		BackgroundColor3 = C.gold,
		Parent = pill,
	})
	Make("UICorner", { CornerRadius = UDim.new(1, 0), Parent = icon })
	Ui.stroke(icon, Color3.fromRGB(255, 240, 180), 1)
	refs.coins = Ui.label({
		Name = "Amount",
		Size = UDim2.new(1, -96, 1, 0),
		Position = UDim2.fromOffset(46, 0),
		Font = Ui.fontBold,
		TextSize = 24,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "0",
		Parent = pill,
	})
	local plus = Ui.button({
		Name = "Plus",
		Size = UDim2.fromOffset(36, 36),
		Position = UDim2.new(1, -41, 0, 5),
		BackgroundColor3 = C.robux,
		Text = "+",
		TextSize = 26,
		Parent = pill,
	})
	plus.Activated:Connect(function()
		if Hud.onShop then
			Hud.onShop("passes")
		end
	end)
	refs.coinPop = Ui.label({
		Size = UDim2.fromOffset(120, 30),
		Position = UDim2.fromOffset(196, 8),
		Font = Ui.fontBold,
		TextSize = 24,
		TextColor3 = C.gold,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
		Parent = pill,
	})
	local function btn(name: string, order: number, color: Color3, fn: () -> ())
		local b = Ui.button({
			Name = name,
			LayoutOrder = order,
			Size = UDim2.fromOffset(190, 42),
			BackgroundColor3 = color,
			Text = "",
			Parent = box,
		})
		b.Activated:Connect(fn)
		return b
	end
	refs.shopBtn = btn("ShopButton", 2, Color3.fromRGB(150, 70, 160), function()
		if Hud.onShop then
			Hud.onShop(nil)
		end
	end)
	refs.inviteBtn = btn("InviteButton", 3, C.button, function()
		if Hud.onInvite then
			Hud.onInvite()
		end
	end)
end

local function buildTop(root: Instance)
	local top = Ui.scaled(
		Make("Frame", {
			Name = "Top",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 14),
			Size = UDim2.fromOffset(560, 150),
			BackgroundTransparency = 1,
			Parent = root,
		}),
		0.75
	)
	local banner = Ui.panel({
		Name = "Banner",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromOffset(520, 44),
		Parent = top,
	})
	refs.banner = banner
	refs.bannerText = Ui.label({
		Name = "Text",
		Size = UDim2.new(1, -170, 1, 0),
		Position = UDim2.fromOffset(12, 0),
		Font = Ui.fontBold,
		TextSize = 22,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
		Parent = banner,
	})
	local opt = Ui.button({
		Name = "OptIn",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -6, 0.5, 0),
		Size = UDim2.fromOffset(150, 34),
		BackgroundColor3 = C.good,
		TextColor3 = Color3.fromRGB(10, 30, 20),
		TextSize = 17,
		Text = "",
		Parent = banner,
	})
	refs.optIn = opt
	opt.Activated:Connect(function()
		local on = player:GetAttribute("RaceOptIn") == false
		player:SetAttribute("RaceOptIn", on) -- сразу в интерфейсе; сервер подтвердит
		if Hud.onOptIn then
			Hud.onOptIn(on)
		end
	end)
	refs.status = Ui.label({
		Name = "Status",
		Size = UDim2.new(1, 0, 0, 24),
		Position = UDim2.fromOffset(0, 48),
		Font = Ui.fontBold,
		TextSize = 19,
		TextColor3 = C.gold,
		Text = "",
		Parent = top,
	})
	refs.toasts = Make("Frame", {
		Name = "Toasts",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 76),
		Size = UDim2.fromOffset(540, 160),
		BackgroundTransparency = 1,
		Parent = top,
	})
	Make("UIListLayout", {
		Padding = UDim.new(0, 6),
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = refs.toasts,
	})
	refs.count = Ui.scaled(
		Ui.label({
			Name = "Count",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.38),
			Size = UDim2.fromOffset(600, 120),
			Font = Ui.fontBold,
			TextSize = 96,
			TextColor3 = Color3.new(1, 1, 1),
			TextStrokeTransparency = 0.2,
			Text = "",
			Parent = root,
		}),
		0.75
	)
	refs.tip = Ui.scaled(
		Ui.label({
			Name = "Tip",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.4, 0.62),
			Size = UDim2.fromOffset(420, 60),
			Font = Ui.fontBold,
			TextSize = 20,
			TextColor3 = C.gold,
			TextStrokeTransparency = 0.3,
			Text = "",
			Parent = root,
		}),
		0.75
	)
end

local function holdButton(parent: Instance, name: string, pos: UDim2, color: Color3, dir: number)
	local b = Ui.button({
		Name = name,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = pos,
		Size = UDim2.fromOffset(112, 112),
		BackgroundColor3 = color,
		BackgroundTransparency = 0.1,
		TextSize = 22,
		AutoButtonColor = false,
		Text = "",
		Parent = parent,
	})
	b:FindFirstChildOfClass("UICorner").CornerRadius = UDim.new(1, 0)
	Ui.stroke(b, Color3.new(1, 1, 1), 3).Transparency = 0.35
	local function isPress(input: InputObject): boolean
		return input.UserInputType == Enum.UserInputType.Touch
			or input.UserInputType == Enum.UserInputType.MouseButton1
	end
	b.InputBegan:Connect(function(input)
		if isPress(input) then
			Controls.setTouch(dir, true)
		end
	end)
	b.InputEnded:Connect(function(input)
		if isPress(input) then
			Controls.setTouch(dir, false)
		end
	end)
	local key = Ui.label({
		Name = "Key",
		Size = UDim2.new(1, 0, 0, 16),
		Position = UDim2.new(0, 0, 1, -28),
		TextSize = 13,
		TextColor3 = Color3.fromRGB(235, 240, 255),
		Text = "",
		Parent = b,
	})
	return b, key
end

-- Справа снизу один контейнер: лестница ветров + кнопки (общий масштаб — не наезжают)
local function buildRight(root: Instance)
	refs.right = Ui.scaled(
		Make("Frame", {
			Name = "Right",
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -16, 1, -20),
			Size = UDim2.fromOffset(312, LADDER_H_TOTAL),
			BackgroundTransparency = 1,
			Parent = root,
		}),
		0.75
	)
end

local function buildControls(_root: Instance)
	local box = Make("Frame", {
		Name = "Controls",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.fromScale(1, 1),
		Size = UDim2.fromOffset(124, 252),
		BackgroundTransparency = 1,
		Parent = refs.right,
	})
	refs.upBtn, refs.upKey = holdButton(box, "UpButton", UDim2.fromOffset(62, 62), C.up, 1)
	refs.downBtn, refs.downKey = holdButton(box, "DownButton", UDim2.fromOffset(62, 190), C.down, -1)
end

local function altToY(alt: number): number
	return 26 + LADDER_H * (1 - math.clamp(alt / W.Ceiling, 0, 1))
end

local function buildLadder(_root: Instance)
	local box = Ui.panel({
		Name = "Ladder",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.fromOffset(176, LADDER_H_TOTAL),
		BackgroundTransparency = 0.35,
		Parent = refs.right,
	})
	refs.ladder = box
	refs.ladderTitle = Ui.label({
		Name = "Title",
		Size = UDim2.new(1, -60, 0, 22),
		Position = UDim2.fromOffset(8, 2),
		Font = Ui.fontBold,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
		Parent = box,
	})
	-- стрелка «к цели» в заголовке
	refs.targetArrow = Ui.label({
		Name = "TargetArrow",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, -22, 0, 13),
		Size = UDim2.fromOffset(24, 24),
		Font = Ui.fontBold,
		TextSize = 24,
		TextColor3 = C.gold,
		Text = "↑",
		Visible = false,
		Parent = box,
	})
	for k = 0, W.Layers do
		local lo = if k == 0 then 0 else W.Bottom + (k - 1) * W.Thick
		local hi = if k == 0 then W.Bottom else lo + W.Thick
		local y0, y1 = altToY(hi), altToY(lo)
		local f = Make("Frame", {
			Name = "Row" .. k,
			Position = UDim2.fromOffset(6, y0),
			Size = UDim2.new(1, -40, 0, y1 - y0 - 2),
			BackgroundColor3 = C.panel2,
			BackgroundTransparency = 0.5,
			BorderSizePixel = 0,
			Parent = box,
		})
		Make("UICorner", { CornerRadius = UDim.new(0, 6), Parent = f })
		local strip = Make("Frame", {
			Name = "Strip",
			Size = UDim2.new(0, 8, 1, 0),
			BackgroundColor3 = rgb(if k == 0 then W.SurfaceColor else W.Colors[k]),
			BorderSizePixel = 0,
			Parent = f,
		})
		Make("UICorner", { CornerRadius = UDim.new(0, 4), Parent = strip })
		local arrow = Ui.label({
			Name = "Arrow",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0, 34, 0.5, 0),
			Size = UDim2.fromOffset(30, 30),
			Font = Ui.fontBold,
			TextSize = 28,
			TextColor3 = rgb(if k == 0 then W.SurfaceColor else W.Colors[k]),
			TextStrokeTransparency = 0.4,
			Text = "↑",
			Parent = f,
		})
		local speed = Ui.label({
			Name = "Speed",
			Position = UDim2.fromOffset(54, 0),
			Size = UDim2.new(0, 34, 1, 0),
			TextSize = 14,
			TextColor3 = C.dim,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = "",
			Parent = f,
		})
		local mark = Ui.label({
			Name = "Mark",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -4, 0.5, 0),
			Size = UDim2.fromOffset(40, 24),
			Font = Ui.fontBold,
			TextSize = 20,
			TextColor3 = C.good,
			TextXAlignment = Enum.TextXAlignment.Right,
			Text = "",
			Parent = f,
		})
		rows[k] = { frame = f, arrow = arrow, speed = speed, mark = mark }
	end
	-- маркер «ты»: едет по высоте
	refs.you = Ui.label({
		Name = "You",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -2, 0, altToY(0)),
		Size = UDim2.fromOffset(36, 22),
		Font = Ui.fontBold,
		TextSize = 18,
		TextColor3 = Color3.new(1, 1, 1),
		TextStrokeTransparency = 0.2,
		Text = "◀",
		Parent = box,
	})
end

local BOARD_ROWS = 6 -- первые 5 и ты
local function buildBoard(root: Instance)
	local board = Ui.scaled(
		Ui.panel({
			Name = "Board",
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -16, 0, 16),
			Size = UDim2.fromOffset(230, 40),
			AutomaticSize = Enum.AutomaticSize.Y,
			Visible = false,
			Parent = root,
		}),
		0.75
	)
	Make("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder, Parent = board })
	Make("UIPadding", {
		PaddingTop = UDim.new(0, 6),
		PaddingBottom = UDim.new(0, 6),
		PaddingLeft = UDim.new(0, 8),
		PaddingRight = UDim.new(0, 8),
		Parent = board,
	})
	refs.board = board
	refs.boardRows = {}
	for i = 1, BOARD_ROWS do
		local l = Ui.label({
			Name = "R" .. i,
			LayoutOrder = i,
			Size = UDim2.new(1, 0, 0, 22),
			TextSize = 16,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = "",
			Visible = false,
			Parent = board,
		})
		refs.boardRows[i] = l
	end
end

local function buildOrder(root: Instance)
	local panel = Ui.scaled(
		Ui.panel({
			Name = "Order",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, 16, 1, -20),
			Size = UDim2.fromOffset(330, 104),
			Visible = false,
			Parent = root,
		}),
		0.75
	)
	Ui.stroke(panel, C.gold, 2)
	refs.order = panel
	refs.orderText = Ui.label({
		Name = "Text",
		Size = UDim2.new(1, -56, 0, 30),
		Position = UDim2.fromOffset(12, 6),
		Font = Ui.fontBold,
		TextSize = 18,
		TextColor3 = C.gold,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
		Parent = panel,
	})
	refs.orderArrow = Ui.label({
		Name = "Arrow",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, -26, 0, 22),
		Size = UDim2.fromOffset(30, 30),
		Font = Ui.fontBold,
		TextSize = 30,
		TextColor3 = C.gold,
		Text = "↑",
		Parent = panel,
	})
	refs.orderHint = Ui.label({
		Name = "Hint",
		Size = UDim2.new(1, -24, 0, 36),
		Position = UDim2.fromOffset(12, 34),
		TextSize = 14,
		TextColor3 = C.dim,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
		Parent = panel,
	})
	local skip = Ui.button({
		Name = "Skip",
		Size = UDim2.fromOffset(150, 28),
		Position = UDim2.new(0, 12, 1, -34),
		TextSize = 14,
		Text = "",
		Parent = panel,
	})
	refs.skip = skip
	skip.Activated:Connect(function()
		if Hud.onSkip then
			Hud.onSkip()
		end
	end)
end

local function buildResults(root: Instance)
	local panel = Ui.scaled(Ui.panel({
		Name = "Results",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.48),
		Size = UDim2.fromOffset(420, 440),
		Visible = false,
		ZIndex = 4,
		Parent = root,
	}))
	refs.resultsStroke = Ui.stroke(panel, C.sky, 2)
	refs.results = panel
	refs.resTitle = Ui.label({
		Name = "Title",
		Size = UDim2.new(1, 0, 0, 40),
		Position = UDim2.fromOffset(0, 12),
		Font = Ui.fontBold,
		TextSize = 30,
		Text = "",
		Parent = panel,
	})
	refs.resBody = Ui.label({
		Name = "Body",
		Size = UDim2.new(1, -40, 0, 100),
		Position = UDim2.fromOffset(20, 56),
		TextSize = 19,
		TextYAlignment = Enum.TextYAlignment.Top,
		Text = "",
		Parent = panel,
	})
	refs.resList = Ui.label({
		Name = "List",
		Size = UDim2.new(1, -40, 1, -230),
		Position = UDim2.fromOffset(20, 160),
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Text = "",
		Parent = panel,
	})
	local again = Ui.button({
		Name = "Again",
		Size = UDim2.new(1, -40, 0, 46),
		Position = UDim2.new(0, 20, 1, -58),
		BackgroundColor3 = Color3.fromRGB(30, 120, 170),
		TextSize = 22,
		Text = "",
		Parent = panel,
	})
	refs.again = again
	again.Activated:Connect(function()
		panel.Visible = false
	end)
end

function Hud.build()
	local root = Ui.screen()
	local hud = Make("Frame", {
		Name = "Hud",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Parent = root,
	})
	buildTopLeft(hud)
	buildTop(hud)
	buildRight(hud)
	buildControls(hud)
	buildLadder(hud)
	buildBoard(hud)
	buildOrder(hud)
	buildResults(root)
	Hud.relabel()
	Lang.onChange(Hud.relabel)
	Controls.onCtl = function(c)
		refs.upBtn.BackgroundTransparency = if c > 0 then 0 else 0.1
		refs.downBtn.BackgroundTransparency = if c < 0 then 0 else 0.1
		refs.upBtn.BackgroundColor3 = if c > 0 then Color3.fromRGB(255, 160, 60) else C.up
		refs.downBtn.BackgroundColor3 = if c < 0 then Color3.fromRGB(90, 170, 255) else C.down
		if Hud.onCtlFx then
			Hud.onCtlFx(c)
		end
	end
	tipStage, tipUntil = 1, os.clock() + 14
end

Hud.onCtlFx = nil :: ((number) -> ())?

function Hud.relabel()
	refs.shopBtn.Text = Lang.t("ui.shop")
	refs.inviteBtn.Text = Lang.t("ui.invite")
	refs.upBtn.Text = "▲\n" .. Lang.t("ui.up")
	refs.downBtn.Text = "▼\n" .. Lang.t("ui.down")
	local touch = isTouch()
	refs.upKey.Text = if touch then "" else Lang.t("ui.keysUp")
	refs.downKey.Text = if touch then "" else Lang.t("ui.keysDown")
	refs.ladderTitle.Text = Lang.t("ui.winds")
	refs.again.Text = Lang.t("results.again")
	refs.skip.Text = Lang.t("order.skip")
	refs.orderHint.Text = Lang.t("order.hint")
end

-------------------------------------------------------------------------------
-- Данные от сервера
-------------------------------------------------------------------------------
function Hud.setProfile(p)
	coinShown = p.coins or 0
	refs.coins.Text = tostring(coinShown)
end

function Hud.coinPop(n: number)
	if not n or n <= 0 then
		return
	end
	coinShown += n
	refs.coins.Text = tostring(coinShown)
	refs.coinPop.Text = "+" .. n
	local token = os.clock()
	refs.coinPopAt = token
	task.delay(1.5, function()
		if refs.coinPopAt == token then
			refs.coinPop.Text = ""
		end
	end)
end

function Hud.toast(text: string, color: Color3?)
	local f = Ui.panel({
		Size = UDim2.fromOffset(520, 34),
		BackgroundTransparency = 0.25,
		LayoutOrder = math.floor(os.clock() * 100),
		Parent = refs.toasts,
	})
	Ui.label({
		Size = UDim2.new(1, -16, 1, 0),
		Position = UDim2.fromOffset(8, 0),
		TextSize = 18,
		TextColor3 = color or C.text,
		Text = text,
		Parent = f,
	})
	table.insert(toasts, f)
	while #toasts > 3 do
		local old = table.remove(toasts, 1)
		if old then
			old:Destroy()
		end
	end
	task.delay(3.5, function()
		local i = table.find(toasts, f)
		if i then
			table.remove(toasts, i)
		end
		f:Destroy()
	end)
end

function Hud.setOrders(list: { any })
	orders = list or {}
end

function Hud.raceStart(p)
	race = { checkpoints = p.checkpoints, goAt = p.goAt, total = #p.checkpoints, count = p.count }
	standings = {}
	refs.results.Visible = false
end

function Hud.go()
	goShownUntil = os.clock() + 1.6
end

function Hud.standings(list: { any })
	standings = list or {}
end

function Hud.splash(time: number)
	splashUntil = os.clock() + (time or 3)
end

function Hud.showResults(p)
	race = nil
	standings = {}
	refs.resTitle.Text = Lang.t("results.title")
	local color = if p.place == 1 then C.gold elseif p.finished then C.good else C.text
	refs.resTitle.TextColor3 = color
	refs.resultsStroke.Color = color
	local lines = {}
	if p.finished then
		table.insert(
			lines,
			"<b>" .. Lang.t("results.place", { n = p.place }) .. "</b>  ·  " .. Lang.formatTime(p.time or 0)
		)
	else
		table.insert(lines, Lang.t("results.dnf", { n = p.cp or 0, total = p.total or 0 }))
	end
	table.insert(
		lines,
		'<font color="#FFD24A"><b>' .. Lang.t("results.coins", { n = p.coins or 0 }) .. "</b></font>"
	)
	if (p.mult or 1) > 1.001 then
		table.insert(lines, Lang.t("results.mult", { m = string.format("%.2f", p.mult) }))
	end
	table.insert(lines, Lang.t("results.wins", { n = p.wins or 0 }))
	refs.resBody.Text = table.concat(lines, "\n")
	local list = {}
	for i, r in p.list or {} do
		if i > 8 then
			break
		end
		local name = r.name .. (if r.ai then " · AI" else "")
		local right = if r.finished then Lang.formatTime(r.time or 0) else "—"
		local line = string.format("%d. %s   %s", i, name, right)
		if r.id == player.UserId then
			line = "<b>" .. line .. "</b>"
		end
		table.insert(list, line)
	end
	refs.resList.Text = table.concat(list, "\n")
	refs.results.Visible = true
	resultsUntil = os.clock() + 12
end

-------------------------------------------------------------------------------
-- Кадр
-------------------------------------------------------------------------------
-- Угол стрелки на экране (0 — от камеры вперёд, по часовой) для направления (dx, dz) в мире
local function screenAngle(dx: number, dz: number): number
	local cam = Workspace.CurrentCamera
	if not cam then
		return math.deg(math.atan2(dx, -dz))
	end
	local look = cam.CFrame.LookVector
	local right = cam.CFrame.RightVector
	local f = Vector3.new(look.X, 0, look.Z)
	local r = Vector3.new(right.X, 0, right.Z)
	if f.Magnitude < 1e-3 then
		f = Vector3.new(-right.Z, 0, right.X)
	end
	f, r = f.Unit, r.Unit
	local v = Vector3.new(dx, 0, dz)
	return math.deg(math.atan2(v:Dot(r), v:Dot(f)))
end
Hud.screenAngle = screenAngle

-- Цель сейчас: следующий чекпоинт или крыша заказа. Возвращает функцию «точка прицела для высоты y»
local function currentGoal(world, winds): ((number) -> (number, number))?
	if race and player:GetAttribute("Racing") == true then
		local i = (player:GetAttribute("Cp") or 0) + 1
		local c = race.checkpoints[i]
		if c then
			return function()
				return c.x, c.z
			end
		end
		return nil
	end
	local o = orders[1]
	if o and world then
		return function(y: number)
			if y <= o.roof then
				return o.x, o.z
			end
			local dx, dz = Parcel.drift(winds, y, o.roof)
			return o.x - dx, o.z - dz
		end
	end
	return nil
end

local function updateLadder()
	local winds = Sky.winds()
	local world = Sky.world()
	local st = Controls.state()
	if not winds then
		refs.ladder.Visible = false
		return
	end
	refs.ladder.Visible = true
	local goal = currentGoal(world, winds)
	local myLayer = if st then Winds.layerAt(winds, st.y) else -1
	for k, row in rows do
		local l = Winds.layer(winds, k)
		row.arrow.Rotation = screenAngle(l.wx, l.wz)
		row.speed.Text = tostring(math.floor(l.speed + 0.5))
		local tint, mark = 0.55, ""
		if goal and st then
			local y = Winds.mid(winds, k)
			local tx, tz = goal(y)
			local dx, dz = tx - st.x, tz - st.z
			local d = math.sqrt(dx * dx + dz * dz)
			if d > 1 and l.speed > 0.1 then
				local cos = (l.wx * dx + l.wz * dz) / (l.speed * d)
				if cos > 0.85 then
					tint, mark = 0.15, "✓"
					row.mark.TextColor3 = C.good
				elseif cos > 0.5 then
					tint, mark = 0.35, "·"
					row.mark.TextColor3 = C.gold
				end
			end
		end
		row.frame.BackgroundColor3 = if mark == "✓"
			then Color3.fromRGB(30, 110, 60)
			elseif mark == "·" then Color3.fromRGB(110, 95, 30)
			else C.panel2
		row.frame.BackgroundTransparency = tint
		row.mark.Text = mark
		local stroke = row.frame:FindFirstChildOfClass("UIStroke")
		if k == myLayer then
			if not stroke then
				Ui.stroke(row.frame, Color3.new(1, 1, 1), 2)
			end
		elseif stroke then
			stroke:Destroy()
		end
	end
	if st then
		refs.you.Position = UDim2.new(1, -2, 0, altToY(st.y))
	end
	if goal and st then
		local tx, tz = goal(st.y)
		refs.targetArrow.Visible = true
		refs.targetArrow.Rotation = screenAngle(tx - st.x, tz - st.z)
	else
		refs.targetArrow.Visible = false
	end
end

local function updateBanner()
	local phase = Workspace:GetAttribute("Phase")
	local st = Controls.state()
	local racing = race ~= nil and player:GetAttribute("Racing") == true
	refs.optIn.Visible = not racing and phase ~= "race"
	if racing and race then
		local r = race :: any
		local i = (player:GetAttribute("Cp") or 0) + 1
		local c = r.checkpoints[i]
		local goAt = r.goAt or 0
		local el = math.max(0, now() - goAt)
		if c and st then
			local d = math.floor(math.sqrt((c.x - st.x) ^ 2 + (c.z - st.z) ^ 2))
			local key = if i == r.total then "race.toFinish" else "race.toCp"
			refs.bannerText.Text = Lang.t(key, { n = i, total = r.total, d = d })
				.. "   ⏱ "
				.. Lang.formatTime(el)
		else
			refs.bannerText.Text = "⏱ " .. Lang.formatTime(el)
		end
		-- место
		local rank, total = nil, #standings
		for _, s in standings do
			if s.id == player.UserId then
				rank = s.rank
			end
		end
		refs.status.Text = if rank then Lang.t("race.place", { n = rank, total = total }) else ""
		-- отсчёт
		local left = goAt - now()
		if left > 0 then
			refs.count.Text = tostring(math.ceil(left))
		elseif os.clock() < goShownUntil then
			refs.count.Text = Lang.t("race.go")
		else
			refs.count.Text = ""
		end
	else
		local nextRace = Workspace:GetAttribute("NextRace")
		if phase == "race" then
			refs.bannerText.Text = Lang.t("race.startedOthers")
		elseif type(nextRace) == "number" then
			refs.bannerText.Text = Lang.t("race.next", { t = Lang.formatTime(math.max(0, nextRace - now())) })
		else
			refs.bannerText.Text = ""
		end
		local on = player:GetAttribute("RaceOptIn") ~= false
		refs.optIn.Text = Lang.t(if on then "race.optIn" else "race.optOut")
		refs.optIn.BackgroundColor3 = if on then C.good else C.button
		refs.optIn.TextColor3 = if on then Color3.fromRGB(10, 30, 20) else C.text
		refs.status.Text = ""
		refs.count.Text = if os.clock() < splashUntil then Lang.t("ui.splash") else ""
	end
	if racing and os.clock() < splashUntil then
		refs.count.Text = Lang.t("ui.splash")
	end
	refs.count.TextSize = if string.len(refs.count.Text) > 3 then 40 else 96
end

local function updateBoard()
	local show = race ~= nil and #standings > 0
	refs.board.Visible = show
	if not show then
		return
	end
	-- на маленьком экране — слева под монетами (баннер и лестница не перекрываются)
	refs.board.AnchorPoint = if Ui.isSmall() then Vector2.new(0, 0) else Vector2.new(1, 0)
	refs.board.Position = if Ui.isSmall() then UDim2.fromOffset(16, 150) else UDim2.new(1, -16, 0, 16)
	-- первые 5 и ты
	local list = {}
	local meShown = false
	for i, s in standings do
		if i <= BOARD_ROWS - 1 then
			table.insert(list, s)
			meShown = meShown or s.id == player.UserId
		end
	end
	for i, s in standings do
		-- последняя строка: ты (если не в первых пяти) или шестой
		local mine = s.id == player.UserId and not meShown
		if i > BOARD_ROWS - 1 and (mine or (i == BOARD_ROWS and meShown)) then
			table.insert(list, s)
		end
	end
	for i, l in refs.boardRows do
		local s = list[i]
		if s then
			l.Visible = true
			local mark = if s.finished then "🏁 " else ""
			local text = string.format("%d. %s%s", s.rank, mark, s.name)
			if s.id == player.UserId then
				l.TextColor3 = C.gold
				text = "<b>" .. text .. "</b>"
			else
				l.TextColor3 = if s.ai then C.dim else C.text
			end
			l.Text = text
		else
			l.Visible = false
		end
	end
end

local function updateOrder()
	local o = orders[1]
	local racing = race ~= nil and player:GetAttribute("Racing") == true
	refs.order.Visible = o ~= nil and not racing
	if not o or racing then
		return
	end
	local st = Controls.state()
	if st then
		local d = math.floor(math.sqrt((o.x - st.x) ^ 2 + (o.z - st.z) ^ 2))
		refs.orderText.Text = Lang.t("order.to", { d = d }) .. (if #orders > 1 then "  ×" .. #orders else "")
		refs.orderArrow.Rotation = screenAngle(o.x - st.x, o.z - st.z)
	end
end

local function updateTip()
	if tipStage == 0 then
		refs.tip.Text = ""
		return
	end
	if os.clock() > tipUntil then
		tipStage += 1
		tipUntil = os.clock() + 12
		if tipStage > 2 then
			tipStage = 0
			refs.tip.Text = ""
			return
		end
	end
	refs.tip.Text = Lang.t(if tipStage == 1 then "ui.welcome" else "ui.tipLadder")
end

function Hud.update(_dt: number)
	updateLadder()
	updateBanner()
	updateBoard()
	updateOrder()
	updateTip()
	if refs.results.Visible and os.clock() > resultsUntil then
		refs.results.Visible = false
	end
end

return Hud
