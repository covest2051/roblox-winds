--[[
	Winds — слои ветра. Каждый слой дует в свою сторону; генерируются из seed
	одинаково на сервере, клиенте и в тестах (по сети передаётся только seed).

	Гарантии генерации (тест winds.spec):
	  • «роза» почти равномерная: любое направление ближе 45° к какому-то слою;
	  • соседние по высоте слои отличаются хотя бы на MinTurn (смена слоя = поворот);
	  • выше — быстрее.
	Угол — куда дует ветер: (cos a, sin a) в плоскости XZ.
]]

local Shared = script.Parent
local Config = require(Shared.Config)
local Rng = require(Shared.Rng)

local Winds = {}

export type Layer = {
	index: number, -- 0 — приземный бриз, 1..N — слои
	bottom: number,
	top: number,
	angle: number,
	speed: number,
	wx: number,
	wz: number,
	color: { number },
}
export type Winds = { seed: number, layers: { Layer }, surface: Layer }

local TAU = math.pi * 2

-- Разница углов в градусах, 0..180
function Winds.angleDiff(a: number, b: number): number
	local d = math.abs((a - b) % TAU)
	if d > math.pi then
		d = TAU - d
	end
	return math.deg(d)
end

local function layerOf(index: number, bottom: number, top: number, angle: number, speed: number, color): Layer
	return {
		index = index,
		bottom = bottom,
		top = top,
		angle = angle % TAU,
		speed = speed,
		wx = math.cos(angle) * speed,
		wz = math.sin(angle) * speed,
		color = color,
	}
end

function Winds.generate(seed: number): Winds
	local W = Config.Wind
	local rng = Rng.new(seed * 7919 + 13)
	local n = W.Layers
	local base = rng:range(0, TAU)
	local dirs = {}
	for i = 1, n do
		dirs[i] = base + (i - 1) * TAU / n + math.rad(rng:range(-W.Jitter, W.Jitter))
	end
	-- порядок по высоте: перемешиваем, пока соседние слои не станут достаточно разными
	local bestOrder, bestMin = nil, -1
	for _ = 1, 300 do
		local order = table.clone(dirs)
		for i = n, 2, -1 do
			local j = rng:int(1, i)
			order[i], order[j] = order[j], order[i]
		end
		local minTurn = 180
		for i = 2, n do
			minTurn = math.min(minTurn, Winds.angleDiff(order[i], order[i - 1]))
		end
		if minTurn > bestMin then
			bestOrder, bestMin = order, minTurn
		end
		if minTurn >= W.MinTurn + 10 then
			break
		end
	end
	local layers = {}
	for i = 1, n do
		local k = if n > 1 then (i - 1) / (n - 1) else 0
		local speed = W.SpeedMin + (W.SpeedMax - W.SpeedMin) * k + rng:range(-W.SpeedJitter, W.SpeedJitter)
		local bottom = W.Bottom + (i - 1) * W.Thick
		layers[i] = layerOf(i, bottom, bottom + W.Thick, (bestOrder :: { number })[i], speed, W.Colors[i])
	end
	local surface = layerOf(0, -math.huge, W.Bottom, rng:range(0, TAU), W.Surface, W.SurfaceColor)
	return { seed = seed, layers = layers, surface = surface }
end

-- Слой на высоте y (без размытия): 0 — бриз, 1..N
function Winds.layerAt(w: Winds, y: number): number
	local W = Config.Wind
	if y < W.Bottom then
		return 0
	end
	return math.clamp(math.floor((y - W.Bottom) / W.Thick) + 1, 1, #w.layers)
end

function Winds.layer(w: Winds, index: number): Layer
	if index <= 0 then
		return w.surface
	end
	return w.layers[math.min(index, #w.layers)]
end

-- Середина слоя по высоте (для бриза — 24)
function Winds.mid(w: Winds, index: number): number
	if index <= 0 then
		return Config.Wind.Bottom * 0.6
	end
	local l = Winds.layer(w, index)
	return (l.bottom + l.top) / 2
end

local function smooth(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

-- Ветер на высоте y (с размытием границ), без учёта края карты
function Winds.atHeight(w: Winds, y: number): (number, number)
	local W = Config.Wind
	local i = Winds.layerAt(w, y)
	local l = Winds.layer(w, i)
	local wx, wz = l.wx, l.wz
	-- ближайшая граница
	local lower = if i == 0 then nil else l.bottom
	local upper = if i == 0 then W.Bottom elseif i < #w.layers then l.top else nil
	if upper and upper - y < W.Blend then
		local o = Winds.layer(w, i + 1)
		local t = smooth((y - (upper - W.Blend)) / (2 * W.Blend))
		wx, wz = wx + (o.wx - wx) * t, wz + (o.wz - wz) * t
	elseif lower and y - lower < W.Blend then
		local o = Winds.layer(w, i - 1)
		local t = smooth(((lower + W.Blend) - y) / (2 * W.Blend))
		wx, wz = wx + (o.wx - wx) * t, wz + (o.wz - wz) * t
	end
	return wx, wz
end

-- Ветер в точке: слой + возврат к архипелагу за краем карты
function Winds.at(w: Winds, x: number, y: number, z: number): (number, number)
	local wx, wz = Winds.atHeight(w, y)
	local E = Config.World
	local r = math.sqrt(x * x + z * z)
	if r > E.Edge then
		local k = math.min(1, (r - E.Edge) / 120) * E.EdgePush
		wx -= x / r * k
		wz -= z / r * k
	end
	return wx, wz
end

-- Самый «попутный» слой для направления (dx, dz): индекс и косинус угла
function Winds.bestFor(w: Winds, dx: number, dz: number): (number, number)
	local len = math.sqrt(dx * dx + dz * dz)
	if len < 1e-6 then
		return 1, 0
	end
	local best, bestCos = 1, -2
	for i, l in w.layers do
		local c = (l.wx * dx + l.wz * dz) / (l.speed * len)
		if c > bestCos then
			best, bestCos = i, c
		end
	end
	return best, bestCos
end

return Winds
