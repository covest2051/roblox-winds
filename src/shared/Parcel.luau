--[[
	Parcel — посылка под парашютом: падает с постоянной скоростью Fall и сносится
	ветром каждого слоя, через который летит (доля Drift). Детерминированно: клиент
	рисует метку «куда упадёт», сервер решает, когда сбросить, тесты проверяют.
]]

local Shared = script.Parent
local Config = require(Shared.Config)
local Winds = require(Shared.Winds)
local World = require(Shared.World)

local Parcel = {}

export type Landing = {
	x: number,
	y: number,
	z: number,
	t: number,
	kind: string, -- "roof" | "island" | "tower" | "water"
	house: number?,
	path: { { x: number, y: number, z: number } }?,
}

--[[
	Где упадёт посылка, сброшенная из (x, y, z). withPath — точки траектории каждые 0.5 с.
	target — дом-цель: если посылка проходит высоту его крыши в пределах крыши + Margin,
	она «цепляет» крышу (край считается попаданием).
]]
function Parcel.predict(
	winds,
	world,
	x: number,
	y: number,
	z: number,
	withPath: boolean?,
	target: number?
): Landing
	local P = Config.Parcel
	local dt = P.Step
	local t = 0
	local path = if withPath then { { x = x, y = y, z = z } } else nil
	local nextMark = 0.5
	local th = if target then world.houses[target] else nil
	local half = if th then th.size / 2 + P.Margin else 0
	for _ = 1, 600 do
		local g, kind, house = World.groundAt(world, x, z)
		if y <= g then
			return { x = x, y = g, z = z, t = t, kind = kind, house = house, path = path }
		end
		local wx, wz = Winds.at(winds, x, y, z)
		local px, pz, py = x, z, y
		x += wx * P.Drift * dt
		z += wz * P.Drift * dt
		y -= P.Fall * dt
		t += dt
		if th and py > th.roof and y <= th.roof then
			-- точка пересечения высоты крыши
			local k = (py - th.roof) / (py - y)
			local cx, cz = px + (x - px) * k, pz + (z - pz) * k
			if math.abs(cx - th.x) <= half and math.abs(cz - th.z) <= half then
				local s2 = th.size / 2
				return {
					x = math.clamp(cx, th.x - s2, th.x + s2),
					y = th.roof,
					z = math.clamp(cz, th.z - s2, th.z + s2),
					t = t - dt * (1 - k),
					kind = "roof",
					house = th.id,
					path = path,
				}
			end
		end
		if path and t >= nextMark then
			nextMark += 0.5
			table.insert(path, { x = x, y = y, z = z })
		end
	end
	local g, kind, house = World.groundAt(world, x, z)
	return { x = x, y = g, z = z, t = t, kind = kind, house = house, path = path }
end

-- Снос по горизонтали при падении с высоты y до высоты floor (без учёта рельефа)
function Parcel.drift(winds, y: number, floor: number): (number, number)
	local P = Config.Parcel
	local dx, dz = 0, 0
	local h = y
	local dy = P.Fall * P.Step
	while h > floor do
		local wx, wz = Winds.atHeight(winds, h)
		local step = math.min(dy, h - floor)
		dx += wx * P.Drift * step / P.Fall
		dz += wz * P.Drift * step / P.Fall
		h -= step
	end
	return dx, dz
end

-- Попала ли посылка на крышу дома houseId (landing — из predict с target = houseId)
function Parcel.hits(landing: Landing, houseId: number): boolean
	return landing.kind == "roof" and landing.house == houseId
end

return Parcel
