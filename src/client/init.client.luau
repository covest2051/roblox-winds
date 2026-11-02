--[[
	Клиент: управление своим шаром, ленты ветра, интерфейс, звуки, реакции на события сервера.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SocialService = game:GetService("SocialService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)

local Ui = require(script.Ui)
local Lang = require(script.Lang)
local Sky = require(script.Sky)
local Controls = require(script.Controls)
local WindFx = require(script.WindFx)
local Hud = require(script.Hud)
local Shop = require(script.Shop)
local Fx = require(script.Fx)
local DebugPanel = require(script.DebugPanel)

local player = Players.LocalPlayer
local C = Ui.colors

-- ждём мир
while not Workspace:GetAttribute("WorldReady") do
	task.wait(0.2)
end

Ui.watchViewport()
Sky.start()
Controls.build()
WindFx.build()
Hud.build()
Shop.build()
Fx.build()
DebugPanel.build()

local function send(payload)
	Net.ClientAction:FireServer(payload)
end

local function invite()
	local ok, can = pcall(function()
		return SocialService:CanSendGameInviteAsync(player)
	end)
	if ok and can then
		pcall(function()
			SocialService:PromptGameInvite(player)
		end)
	end
end

WindFx.racing = Hud.racing
WindFx.nextCp = Hud.nextCp

Hud.onShop = function(tab)
	if tab then
		Shop.open(tab)
	else
		Shop.toggle()
	end
end
Hud.onInvite = invite
Hud.onOptIn = function(on)
	send({ t = "optIn", on = on })
end
Hud.onSkip = function()
	send({ t = "skipOrder" })
end
Hud.onCtlFx = function(c)
	if c > 0 then
		Fx.play("Burner")
	elseif c < 0 then
		Fx.play("Valve")
	else
		Fx.stop("Burner")
	end
end
Controls.onLayer = function(_from, to)
	Fx.play("Layer", 0.6 + to * 0.08)
end
Controls.onCeiling = function()
	Hud.toast(Lang.t("ui.ceiling"), C.warn)
end

local handlers = {}

handlers.profile = function(p)
	Hud.setProfile(p)
	Shop.setProfile(p)
end

handlers.toast = function(p)
	Hud.toast(Lang.t(p.key, p.vars))
end

handlers.balloon = function()
	Controls.teleported()
end

handlers.teleport = function()
	Controls.teleported()
end

handlers.splash = function(p)
	Hud.splash(p.time)
	Fx.play("Splash")
	Fx.shake(0.8)
end

handlers.orders = function(p)
	Hud.setOrders(p.list)
	WindFx.setOrders(p.list)
end

handlers.dropped = function()
	Hud.toast(Lang.t("order.dropped"), C.gold)
	Fx.play("Drop")
end

handlers.delivered = function(p)
	Hud.toast(
		Lang.t("order.delivered", { n = p.coins })
			.. (if p.fast then "  ·  " .. Lang.t("order.fast") else ""),
		C.good
	)
	Hud.coinPop(p.coins)
	Fx.play("Delivered")
end

handlers.raceStart = function(p)
	Hud.raceStart(p)
	Shop.close()
	Fx.play("Count")
end

handlers.go = function()
	Hud.go()
	Fx.play("Finish", 0.7)
end

handlers.cp = function(p)
	Hud.cp(p.n)
	Hud.toast(Lang.t("race.cp", { n = p.n, total = p.total }), C.sky)
	Fx.play("Checkpoint")
end

handlers.standings = function(p)
	Hud.standings(p.list)
end

handlers.finish = function(p)
	local t = Lang.formatTime(p.time or 0)
	if p.userId == player.UserId then
		Hud.toast(Lang.t("race.youFinished", { place = p.place, t = t }), C.gold)
		Fx.play("Finish")
		Fx.shake(0.4)
	else
		Hud.toast(Lang.t("race.finished", { name = p.name, place = p.place, t = t }))
	end
end

handlers.results = function(p)
	Hud.showResults(p)
	Hud.coinPop(p.coins)
end

handlers.chestResult = function(p)
	Shop.showReward(p.id, Lang.t("shop.chestGot"), if p.dup then p.refund else nil)
end

handlers.directResult = function(p)
	Shop.showReward(p.id, Lang.t("shop.directGot"), nil)
end

handlers.selftest = function(p)
	for _, line in p.lines do
		print(line)
	end
	Hud.toast(p.lines[#p.lines] or "selftest")
end

Net.ServerEvent.OnClientEvent:Connect(function(payload)
	if type(payload) ~= "table" then
		return
	end
	local h = handlers[payload.t]
	if h then
		local ok, err = pcall(h, payload)
		if not ok then
			warn("[Client]", payload.t, err)
		end
	end
end)

send({ t = "profile" })
send({ t = "orders" })

-- управление шаром — до физики кадра; картинка — перед отрисовкой
RunService.Heartbeat:Connect(function(dt)
	Controls.update(dt)
end)
RunService.RenderStepped:Connect(function(dt)
	WindFx.update(dt)
	Hud.update(dt)
	Fx.update(dt)
end)
