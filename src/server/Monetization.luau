--[[
	Monetization — геймпассы, developer products, шкатулка и PolicyService.

	Правила:
	  • Промпт покупки открывает только сервер. Перед сундуком сервер сам проверяет
	    PolicyService (ArePaidRandomItemsRestricted). Ошибка запроса = «запрещено».
	  • ProcessReceipt идемпотентен: PurchaseId пишется в профиль, и только после
	    успешного сохранения возвращается PurchaseGranted.
	  • ID = 0 (товар ещё не создан): в Studio покупка эмулируется, в живой игре — «скоро».
]]

local HttpService = game:GetService("HttpService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local PolicyService = game:GetService("PolicyService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Catalog = require(Shared.Catalog)
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local Profile = require(Shared.Profile)

local Data = require(script.Parent.DataService)

local Monetization = {}

local passes: { [Player]: { [string]: boolean } } = {}
local policy: { [Player]: { restricted: boolean, ok: boolean } } = {}
local pendingDirect: { [Player]: string } = {}
local passListeners: { (Player, string) -> () } = {}

local productByKey = Config.Products
local keyByProductId: { [number]: string } = {}
local keyByPassId: { [number]: string } = {}
for k, p in Config.Products do
	if p.id ~= 0 then
		keyByProductId[p.id] = k
	end
end
for k, p in Config.Passes do
	if p.id ~= 0 then
		keyByPassId[p.id] = k
	end
end

local function isStudio(): boolean
	return RunService:IsStudio()
end

local function toast(player: Player, key: string, vars: { [string]: any }?)
	Net.ServerEvent:FireClient(player, { t = "toast", key = key, vars = vars })
end

-------------------------------------------------------------------------------
-- Геймпассы
-------------------------------------------------------------------------------
function Monetization.hasPass(player: Player, key: string): boolean
	local p = passes[player]
	return p ~= nil and p[key] == true
end

function Monetization.onPass(fn: (Player, string) -> ())
	table.insert(passListeners, fn)
end

local function setPass(player: Player, key: string)
	passes[player] = passes[player] or {}
	if passes[player][key] then
		return
	end
	passes[player][key] = true
	player:SetAttribute("Pass_" .. key, true)
	for _, fn in passListeners do
		task.spawn(fn, player, key)
	end
end

local function loadPasses(player: Player)
	passes[player] = passes[player] or {}
	for key, p in Config.Passes do
		if p.id ~= 0 then
			local ok, owns = pcall(function()
				return MarketplaceService:UserOwnsGamePassAsync(player.UserId, p.id)
			end)
			if ok and owns then
				setPass(player, key)
			end
		end
	end
end

function Monetization.promptPass(player: Player, key: string)
	local p = Config.Passes[key]
	if not p then
		return
	end
	if Monetization.hasPass(player, key) then
		toast(player, "shop.owned")
		return
	end
	if p.id == 0 then
		if isStudio() then
			setPass(player, key)
			toast(player, "shop.studioGrant")
			Monetization.sendProfile(player)
		else
			toast(player, "shop.soon")
		end
		return
	end
	MarketplaceService:PromptGamePassPurchase(player, p.id)
end

-------------------------------------------------------------------------------
-- PolicyService
-------------------------------------------------------------------------------
-- true — игроку можно показывать и продавать платные случайные предметы
function Monetization.chestAllowed(player: Player): boolean
	local cached = policy[player]
	if cached and cached.ok then
		return not cached.restricted
	end
	local ok, info = pcall(function()
		return PolicyService:GetPolicyInfoForPlayerAsync(player)
	end)
	local restricted = true -- при ошибке — безопасный вариант
	if ok and type(info) == "table" then
		restricted = info.ArePaidRandomItemsRestricted == true
	end
	policy[player] = { restricted = restricted, ok = ok }
	return not restricted
end

-------------------------------------------------------------------------------
-- Профиль для клиента
-------------------------------------------------------------------------------
function Monetization.available(kind: "pass" | "product", key: string): boolean
	local t = if kind == "pass" then Config.Passes[key] else Config.Products[key]
	return t ~= nil and (t.id ~= 0 or isStudio())
end

function Monetization.sendProfile(player: Player)
	local d = Data.get(player)
	if not d then
		return
	end
	local owned = {}
	for id in d.owned do
		table.insert(owned, id)
	end
	local avail = {}
	for k in Config.Passes do
		avail[k] = Monetization.available("pass", k)
	end
	for k in Config.Products do
		avail[k] = Monetization.available("product", k)
	end
	local hasVip = Monetization.hasPass(player, "Vip")
	local equipped = {}
	for _, kind in Catalog.Kinds do
		equipped[kind] = Profile.effective(d, kind, hasVip)
	end
	Net.ServerEvent:FireClient(player, {
		t = "profile",
		coins = d.coins,
		owned = owned,
		equipped = equipped,
		races = d.races,
		wins = d.wins,
		podiums = d.podiums,
		deliveries = d.deliveries,
		passes = passes[player] or {},
		chestAllowed = Monetization.chestAllowed(player),
		available = avail,
		saved = player:GetAttribute("DataSaved") == true,
	})
end

-------------------------------------------------------------------------------
-- Developer products
-------------------------------------------------------------------------------
local grantFns = {}

local function coinsPack(key: string)
	return function(player: Player, d: Profile.Data)
		local n = Config.Products[key].coins
		Profile.addCoins(d, n)
		toast(player, "shop.coinsAdded", { n = n })
	end
end
grantFns.Coins500 = coinsPack("Coins500")
grantFns.Coins3000 = coinsPack("Coins3000")

local rng = Random.new()
grantFns.Chest = function(player: Player, d: Profile.Data)
	if not Monetization.chestAllowed(player) then
		-- сюда не должны попадать (сервер не открывает промпт), но если попали — не случайная награда
		Profile.addCoins(d, Config.ChestFallbackCoins)
		toast(player, "shop.coinsAdded", { n = Config.ChestFallbackCoins })
		return
	end
	local id = Catalog.roll(function(a, b)
		return rng:NextInteger(a, b)
	end)
	local res = Profile.grantItem(d, id)
	d.chests += 1
	Net.ServerEvent:FireClient(player, { t = "chestResult", id = res.id, dup = res.dup, refund = res.refund })
end

local function direct(key: string)
	return function(player: Player, d: Profile.Data)
		local rarity = Config.Products[key].rarity
		local id = Profile.pickDirect(d, rarity, pendingDirect[player])
		pendingDirect[player] = nil
		if id then
			Profile.grantItem(d, id)
			Net.ServerEvent:FireClient(player, { t = "directResult", id = id })
		else
			local n = Config.Rarity[rarity].price
			Profile.addCoins(d, n)
			toast(player, "shop.allOwned", { n = n })
		end
	end
end
grantFns.DirectRare = direct("DirectRare")
grantFns.DirectEpic = direct("DirectEpic")
grantFns.DirectLegendary = direct("DirectLegendary")

-- Выдать товар key игроку по чеку purchaseId. true — выдано и сохранено.
function Monetization.grant(player: Player, key: string, purchaseId: string): boolean
	local fn = grantFns[key]
	if not fn then
		warn("[Shop] no handler for product", key)
		return false
	end
	local d = Data.get(player, 15)
	if not d then
		return false
	end
	if not Profile.hasReceipt(d, purchaseId) then
		fn(player, d)
		Profile.addReceipt(d, purchaseId)
		Data.changed(player)
		Monetization.sendProfile(player)
	end
	return Data.commit(player)
end

function Monetization.processReceipt(receipt): Enum.ProductPurchaseDecision
	local key = keyByProductId[receipt.ProductId]
	local player = Players:GetPlayerByUserId(receipt.PlayerId)
	if not key or not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local ok, granted = pcall(Monetization.grant, player, key, tostring(receipt.PurchaseId))
	if ok and granted then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	if not ok then
		warn("[Shop] grant error:", granted)
	end
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

-- Запрос клиента «купить товар». extra — выбранный предмет для прямой покупки.
function Monetization.promptProduct(player: Player, key: string, extra: string?)
	local p = productByKey[key]
	if not p then
		return
	end
	if key == "Chest" and not Monetization.chestAllowed(player) then
		toast(player, "shop.chestRestricted")
		return
	end
	if p.rarity then
		local item = extra and Catalog.get(extra)
		if not item or item.rarity ~= p.rarity then
			return
		end
		local d = Data.get(player)
		if d and Profile.owns(d, item.id) then
			toast(player, "shop.owned")
			return
		end
		pendingDirect[player] = item.id
	end
	if p.id == 0 then
		if isStudio() then
			Monetization.grant(player, key, "studio-" .. HttpService:GenerateGUID(false))
			toast(player, "shop.studioGrant")
		else
			toast(player, "shop.soon")
		end
		return
	end
	MarketplaceService:PromptProductPurchase(player, p.id)
end

function Monetization.start()
	MarketplaceService.ProcessReceipt = Monetization.processReceipt
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, purchased)
		local key = keyByPassId[passId]
		if purchased and key then
			setPass(player, key)
			Monetization.sendProfile(player)
		end
	end)
	local function added(player: Player)
		loadPasses(player)
		task.spawn(Monetization.chestAllowed, player)
	end
	Players.PlayerAdded:Connect(added)
	for _, p in Players:GetPlayers() do
		task.spawn(added, p)
	end
	Players.PlayerRemoving:Connect(function(player)
		passes[player] = nil
		policy[player] = nil
		pendingDirect[player] = nil
	end)
	Data.onLoaded(function(player)
		Monetization.sendProfile(player)
	end)
end

return Monetization
