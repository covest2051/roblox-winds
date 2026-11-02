--[[
	Catalog — косметика, которую видят все:
	  • balloon — оболочка шара: узор (полосы, две половины, пояс, лоскуты, радуга) и материал;
	  • ribbon  — ленты на углах корзины (развеваются по ветру — заодно показывают его);
	  • trail   — след за шаром.
	Шансы сундука считаются в целых «сотых процента» (Config.WeightTotal = 10000),
	поэтому показанные проценты точные.
]]

local Shared = script.Parent
local Config = require(Shared.Config)

local Catalog = {}

export type Item = {
	id: string,
	kind: "balloon" | "ribbon" | "trail",
	rarity: string, -- Common | Rare | Epic | Legendary | Default | Vip
	colors: { { number } }, -- 2+ цвета RGB
	pattern: string?, -- balloon: stripes | twotone | band | patch | rainbow
	material: string?, -- plastic | neon | glass | foil
	width: number?, -- trail: ширина
	rainbow: boolean?, -- цвет переливается (клиент)
}

Catalog.Kinds = { "balloon", "ribbon", "trail" }

Catalog.Items = {
	-- по умолчанию, у всех
	{
		id = "balloon_classic",
		kind = "balloon",
		rarity = "Default",
		colors = { { 230, 60, 60 }, { 250, 245, 235 } },
		pattern = "stripes",
		material = "plastic",
	},
	{
		id = "ribbon_white",
		kind = "ribbon",
		rarity = "Default",
		colors = { { 245, 245, 245 }, { 200, 210, 220 } },
	},
	{
		id = "trail_mist",
		kind = "trail",
		rarity = "Default",
		colors = { { 255, 255, 255 }, { 200, 220, 255 } },
		width = 1,
	},
	-- Common
	{
		id = "balloon_sky",
		kind = "balloon",
		rarity = "Common",
		colors = { { 80, 160, 255 }, { 245, 250, 255 } },
		pattern = "twotone",
		material = "plastic",
	},
	{
		id = "balloon_lemon",
		kind = "balloon",
		rarity = "Common",
		colors = { { 255, 220, 60 }, { 255, 140, 40 } },
		pattern = "stripes",
		material = "plastic",
	},
	{
		id = "ribbon_red",
		kind = "ribbon",
		rarity = "Common",
		colors = { { 230, 50, 50 }, { 255, 200, 200 } },
	},
	{
		id = "ribbon_teal",
		kind = "ribbon",
		rarity = "Common",
		colors = { { 40, 200, 190 }, { 200, 255, 250 } },
	},
	{
		id = "trail_pink",
		kind = "trail",
		rarity = "Common",
		colors = { { 255, 130, 200 }, { 255, 220, 240 } },
		width = 1.4,
	},
	{
		id = "trail_mint",
		kind = "trail",
		rarity = "Common",
		colors = { { 110, 255, 180 }, { 220, 255, 240 } },
		width = 1.4,
	},
	-- Rare
	{
		id = "balloon_patch",
		kind = "balloon",
		rarity = "Rare",
		colors = { { 255, 90, 90 }, { 255, 200, 60 }, { 90, 200, 120 }, { 80, 150, 255 }, { 180, 110, 255 } },
		pattern = "patch",
		material = "plastic",
	},
	{
		id = "balloon_night",
		kind = "balloon",
		rarity = "Rare",
		colors = { { 25, 30, 70 }, { 255, 200, 60 } },
		pattern = "band",
		material = "plastic",
	},
	{
		id = "ribbon_flag",
		kind = "ribbon",
		rarity = "Rare",
		colors = { { 255, 60, 60 }, { 255, 255, 255 }, { 60, 120, 255 } },
	},
	{
		id = "trail_fire",
		kind = "trail",
		rarity = "Rare",
		colors = { { 255, 200, 50 }, { 255, 60, 20 } },
		width = 1.8,
	},
	-- Epic
	{
		id = "balloon_neon",
		kind = "balloon",
		rarity = "Epic",
		colors = { { 0, 255, 230 }, { 255, 0, 200 } },
		pattern = "stripes",
		material = "neon",
	},
	{
		id = "balloon_glass",
		kind = "balloon",
		rarity = "Epic",
		colors = { { 180, 230, 255 }, { 120, 255, 220 } },
		pattern = "band",
		material = "glass",
	},
	{
		id = "ribbon_neon",
		kind = "ribbon",
		rarity = "Epic",
		colors = { { 0, 255, 200 }, { 255, 0, 220 } },
		material = "neon",
	},
	{
		id = "trail_comet",
		kind = "trail",
		rarity = "Epic",
		colors = { { 230, 245, 255 }, { 80, 120, 255 } },
		width = 2.6,
	},
	-- Legendary
	{
		id = "balloon_rainbow",
		kind = "balloon",
		rarity = "Legendary",
		colors = {
			{ 255, 70, 70 },
			{ 255, 170, 50 },
			{ 255, 240, 70 },
			{ 80, 220, 110 },
			{ 70, 160, 255 },
			{ 170, 100, 255 },
		},
		pattern = "rainbow",
		material = "neon",
		rainbow = true,
	},
	{
		id = "trail_rainbow",
		kind = "trail",
		rarity = "Legendary",
		colors = { { 255, 70, 70 }, { 70, 160, 255 } },
		width = 2.4,
		rainbow = true,
	},
	-- только VIP
	{
		id = "balloon_gold",
		kind = "balloon",
		rarity = "Vip",
		colors = { { 255, 195, 50 }, { 255, 245, 200 } },
		pattern = "band",
		material = "foil",
	},
	{ id = "ribbon_gold", kind = "ribbon", rarity = "Vip", colors = { { 255, 200, 50 }, { 255, 240, 170 } } },
	{
		id = "trail_gold",
		kind = "trail",
		rarity = "Vip",
		colors = { { 255, 220, 90 }, { 255, 170, 30 } },
		width = 2,
	},
}

Catalog.Default = { balloon = "balloon_classic", ribbon = "ribbon_white", trail = "trail_mist" }

local byId: { [string]: Item } = {}
local byRarity: { [string]: { Item } } = {}
for _, item in Catalog.Items do
	byId[item.id] = item
	byRarity[item.rarity] = byRarity[item.rarity] or {}
	table.insert(byRarity[item.rarity], item)
end

function Catalog.get(id: string): Item?
	return byId[id]
end

function Catalog.ofRarity(rarity: string): { Item }
	return byRarity[rarity] or {}
end

-- Предмет можно получить из сундука или купить (за монеты/Robux)
function Catalog.isTradable(item: Item): boolean
	return Config.Rarity[item.rarity] ~= nil
end

function Catalog.price(id: string): number?
	local item = byId[id]
	local r = item and Config.Rarity[item.rarity]
	return r and r.price
end

function Catalog.refund(id: string): number
	local item = byId[id]
	local r = item and Config.Rarity[item.rarity]
	return if r then r.refund else 0
end

--[[
	Точные шансы сундука: { {id, rarity, bp} }, bp — сотые доли процента.
	Сумма bp = Config.WeightTotal. Вес редкости делится между её предметами поровну;
	тест проверяет, что деление без остатка.
]]
function Catalog.odds(): { { id: string, rarity: string, bp: number } }
	local out = {}
	for _, rarity in Config.RarityOrder do
		local items = byRarity[rarity] or {}
		local w = Config.Rarity[rarity].weight
		for _, item in items do
			table.insert(out, { id = item.id, rarity = rarity, bp = math.floor(w / #items) })
		end
	end
	return out
end

function Catalog.rarityPercent(rarity: string): string
	return Catalog.formatBp(Config.Rarity[rarity].weight)
end

-- 1250 → "12.5%", 560 → "5.6%", 100 → "1%"
function Catalog.formatBp(bp: number): string
	local s = string.format("%.2f", bp / 100)
	s = string.gsub(s, "0+$", "")
	s = string.gsub(s, "%.$", "")
	return s .. "%"
end

--[[
	Бросок сундука. randInt(a, b) — целое в [a, b] (на сервере — Random.new():NextInteger).
	Возвращает id предмета.
]]
function Catalog.roll(randInt: (number, number) -> number): string
	local odds = Catalog.odds()
	local r = randInt(1, Config.WeightTotal)
	local acc = 0
	for _, o in odds do
		acc += o.bp
		if r <= acc then
			return o.id
		end
	end
	return odds[#odds].id
end

return Catalog
