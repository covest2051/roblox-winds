--[[
	Delivery — заказы доставки: выбрать крышу-цель, проверить «посылка упадёт на крышу»,
	посчитать награду. Сброс автоматический: как только метка падения на крыше.
]]

local Shared = script.Parent
local Config = require(Shared.Config)
local Parcel = require(Shared.Parcel)
local World = require(Shared.World)

local Delivery = {}

export type Order = {
	house: number,
	x: number,
	z: number,
	roof: number,
	dist: number,
	par: number,
	t0: number,
}

-- Дом-цель: на расстоянии MinDist..MaxDist от (x, z), не из exclude. randInt(a, b) — случайное целое.
function Delivery.pick(
	world,
	randInt: (number, number) -> number,
	x: number,
	z: number,
	exclude: { [number]: boolean }?
): number
	local P = Config.Parcel
	local ex = exclude or {}
	local good, any = {}, {}
	for _, h in world.houses do
		if not ex[h.id] then
			table.insert(any, h.id)
			local d = World.dist(x, z, h.x, h.z)
			if d >= P.MinDist and d <= P.MaxDist then
				table.insert(good, h.id)
			end
		end
	end
	local list = if #good > 0 then good else any
	return list[randInt(1, #list)]
end

function Delivery.newOrder(world, houseId: number, fromX: number, fromZ: number, t: number): Order
	local h = world.houses[houseId]
	local W = Config.Rewards
	local d = World.dist(fromX, fromZ, h.x, h.z)
	return {
		house = houseId,
		x = h.x,
		z = h.z,
		roof = h.roof,
		dist = d,
		par = W.ParBase + d / W.ParSpeed,
		t0 = t,
	}
end

-- Куда упадёт посылка, если сбросить сейчас, и попадёт ли на крышу
function Delivery.check(
	order: Order,
	winds,
	world,
	x: number,
	y: number,
	z: number
): (boolean, Parcel.Landing)
	local landing = Parcel.predict(winds, world, x, y, z, false, order.house)
	return Parcel.hits(landing, order.house), landing
end

-- «Сырые» монеты за доставку (до множителей)
function Delivery.reward(order: Order, elapsed: number): number
	local W = Config.Rewards
	local base = math.min(W.ParcelMax, W.ParcelBase + order.dist * W.ParcelPerStud)
	if elapsed <= order.par then
		base *= 1 + W.FastBonus
	end
	return math.floor(base + 0.5)
end

return Delivery
