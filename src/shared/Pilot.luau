--[[
	Pilot — «голова» пилота: решает ВЫШЕ / НИЖЕ / держать, глядя на ветра и цель.
	Одна и та же голова ведёт ИИ-соперников в игре и ботов в тестах баланса.

	Как думает: для каждого слоя оценивает время до цели, если подняться/спуститься
	в его середину и лететь по его ветру (с учётом, насколько близко ветер пронесёт мимо).
	Выбирает лучший с гистерезисом, раз в Think секунд. Рука срабатывает с задержкой reaction.

	skill = "pro"    — оценка с учётом времени смены высоты и бокового промаха;
	skill = "novice" — «найди слой, который дует в сторону цели» (как новичок по подсказке).

	Цель: { x, z, r } — пройти в радиусе r; для доставки ещё house — тогда точка цели
	своя для каждой высоты (крыша минус снос посылки с этой высоты).
]]

local Shared = script.Parent
local Config = require(Shared.Config)
local Winds = require(Shared.Winds)
local Parcel = require(Shared.Parcel)

local Pilot = {}

export type Goal = { x: number, z: number, r: number, house: number? }
export type Mem = {
	skill: string,
	reaction: number,
	think: number,
	t: number,
	layer: number?,
	cost: number,
	targetY: number,
	queue: { { t: number, ctl: number } },
	out: number,
	stuck: number,
	climbFor: number,
	switches: number,
	used: { [number]: boolean },
	nextThink: number,
}

function Pilot.new(opts: { skill: string?, reaction: number?, think: number? }?): Mem
	local o = opts or {}
	return {
		skill = o.skill or "pro",
		reaction = o.reaction or 0,
		think = o.think or Config.Ai.Think,
		t = 0,
		layer = nil,
		cost = math.huge,
		targetY = 0,
		queue = {},
		out = 0,
		stuck = 0,
		climbFor = 0,
		switches = 0,
		used = {},
		nextThink = 0,
	}
end

local MARGIN = 1 -- с: меняем слой, только если новый план лучше хотя бы на столько

-- Точка, над которой надо пролететь на высоте y
local function aimAt(goal: Goal, world, winds, y: number): (number, number)
	if goal.house then
		local h = world.houses[goal.house]
		local dx, dz = Parcel.drift(winds, y, h.roof)
		return h.x - dx, h.z - dz
	end
	return goal.x, goal.z
end

local function climbTime(dy: number): number
	local F = Config.Flight
	return math.abs(dy) / (if dy > 0 then F.Climb else F.Sink)
end

-- Лучшее «прямое» время из точки Q на высоте y: перейти в слой j и лететь к цели
local function restTime(
	qx: number,
	qz: number,
	y: number,
	goal: Goal,
	world,
	winds,
	layers: { number }
): number
	local best = math.huge
	for _, j in layers do
		local l = Winds.layer(winds, j)
		local yj = Winds.mid(winds, j)
		local tx, tz = aimAt(goal, world, winds, yj)
		local dx, dz = tx - qx, tz - qz
		local d = math.sqrt(dx * dx + dz * dz)
		if d <= goal.r * 0.5 then
			best = math.min(best, climbTime(yj - y))
		else
			local c = (l.wx * dx + l.wz * dz) / (l.speed * d)
			if c > 0.25 then
				best = math.min(best, climbTime(yj - y) + (d - goal.r * 0.5) / (l.speed * c))
			end
		end
	end
	if best == math.huge then
		return 1000
	end
	return best
end

-- Снос и время при смене высоты y0 → y1 (шар проходит через ветра промежуточных слоёв)
local function transit(winds, y0: number, y1: number): (number, number, number)
	local F = Config.Flight
	local dy = y1 - y0
	if math.abs(dy) < 1 then
		return 0, 0, 0
	end
	local v = if dy > 0 then F.Climb else F.Sink
	local n = math.max(1, math.ceil(math.abs(dy) / 6))
	local h = dy / n
	local dt = math.abs(h) / v
	local dx, dz = 0, 0
	for i = 1, n do
		local wx, wz = Winds.atHeight(winds, y0 + h * (i - 0.5))
		dx += wx * dt
		dz += wz * dt
	end
	return dx, dz, math.abs(dy) / v
end

-- Переходы между серединами слоёв не меняются, пока не сменились ветра: кэш
local transitCache: { [any]: { [number]: { number } } } = setmetatable({}, { __mode = "k" }) :: any
local function transitMid(winds, k: number, j: number): (number, number, number)
	local c = transitCache[winds]
	if not c then
		c = {}
		transitCache[winds] = c
	end
	local key = k * 100 + j
	local v = c[key]
	if not v then
		local dx, dz, t = transit(winds, Winds.mid(winds, k), Winds.mid(winds, j))
		v = { dx, dz, t }
		c[key] = v
	end
	return v[1], v[2], v[3]
end

--[[
	Оценка «время до цели», если сейчас идти в слой k (pro). Быстрейший путь по ветрам —
	решение линейной задачи «a·w_k + b·w_j = D, a, b ≥ 0, минимум a + b»: оптимум всегда
	из одного или двух слоёв. Плюс время и снос при смене высоты (сначала в k, потом в j).
	Если k не входит ни в одну пару — слой сейчас бесполезен.
]]
local function costPro(st, goal: Goal, world, winds, k: number, layers: { number }): number
	local lk = Winds.layer(winds, k)
	local yk = Winds.mid(winds, k)
	local sx, sz, tc = transit(winds, st.y, yk)
	local px, pz = st.x + sx, st.z + sz
	local best = math.huge
	local tol = goal.r * 0.5
	for _, j in layers do
		local lj = Winds.layer(winds, j)
		local tx, tz = aimAt(goal, world, winds, Winds.mid(winds, j))
		local dx, dz = tx - px, tz - pz
		-- цель — круг: достаточно долететь до его края (с запасом)
		local dl = math.sqrt(dx * dx + dz * dz)
		local cut = goal.r * 0.6
		if dl > cut and cut > 1 then
			dx -= dx / dl * cut
			dz -= dz / dl * cut
		end
		if j == k then
			-- один слой: ветер несёт прямо на цель
			local a = (dx * lk.wx + dz * lk.wz) / (lk.speed * lk.speed)
			if a >= 0 then
				local ex, ez = dx - lk.wx * a, dz - lk.wz * a
				if ex * ex + ez * ez <= tol * tol then
					best = math.min(best, a)
				end
			end
		else
			local mx, mz, mt = transitMid(winds, k, j)
			dx -= mx
			dz -= mz
			local det = lk.wx * lj.wz - lk.wz * lj.wx
			if math.abs(det) > 1e-3 then
				local a = (dx * lj.wz - dz * lj.wx) / det
				local b = (lk.wx * dz - lk.wz * dx) / det
				if a >= -0.3 and b >= 0 then
					best = math.min(best, math.max(a, 0) + mt + b)
				end
			end
		end
	end
	if best == math.huge then
		return 1e4 + tc
	end
	return tc + best
end

-- Новичок: слой с ветром ближе всего к направлению на цель (минус немного за высоту)
local function costNovice(st, goal: Goal, world, winds, k: number, _layers: { number }): number
	local l = Winds.layer(winds, k)
	local y = Winds.mid(winds, k)
	local tx, tz = aimAt(goal, world, winds, y)
	local dx, dz = tx - st.x, tz - st.z
	local d = math.sqrt(dx * dx + dz * dz)
	if d < 1 then
		return 0
	end
	local c = (l.wx * dx + l.wz * dz) / (l.speed * d)
	return -c + math.abs(y - st.y) / 400
end

local function candidates(goal: Goal, world, winds): { number }
	local out = {}
	local lowest = 1
	if goal.house then
		-- бриз у самой земли подходит, только если крыша заметно ниже его середины
		local h = world.houses[goal.house]
		if h.roof + 10 < Winds.mid(winds, 0) then
			lowest = 0
		end
	end
	for k = lowest, #winds.layers do
		table.insert(out, k)
	end
	return out
end

function Pilot.choose(mem: Mem, st, goal: Goal, world, winds): number
	local best, bestCost = mem.layer or 1, math.huge
	local curCost = math.huge
	local layers = candidates(goal, world, winds)
	-- вблизи маленькой цели (крыша) план «два слоя» слишком чувствителен к ошибкам:
	-- достаточно лететь слоем, который дует прямо на цель
	local near = goal.r < 20 and math.sqrt((goal.x - st.x) ^ 2 + (goal.z - st.z) ^ 2) < 160
	for _, k in layers do
		local c = if mem.skill == "novice" or near
			then costNovice(st, goal, world, winds, k, layers)
			elseif mem.skill == "direct" then restTime(st.x, st.z, st.y, goal, world, winds, { k })
			else costPro(st, goal, world, winds, k, layers)
		if c < bestCost then
			best, bestCost = k, c
		end
		if k == mem.layer then
			curCost = c
		end
	end
	local margin = if mem.skill == "novice" or near then 0.08 else MARGIN
	if mem.layer == nil or bestCost < curCost - margin then
		if mem.layer ~= nil and best ~= mem.layer then
			mem.switches += 1
		end
		mem.layer = best
		mem.cost = bestCost
	else
		mem.cost = curCost
	end
	mem.used[mem.layer :: number] = true
	mem.targetY = Winds.mid(winds, mem.layer :: number)
	return mem.layer :: number
end

-- Решение на этот шаг: ctl (-1, 0, 1) с учётом задержки руки
function Pilot.decide(mem: Mem, st, goal: Goal, world, winds, dt: number): number
	mem.t += dt
	if mem.t >= mem.nextThink then
		mem.nextThink = mem.t + mem.think
		Pilot.choose(mem, st, goal, world, winds)
	end
	-- упёрся в стену (маяк, дом) — поднимаемся
	local wx, wz = Winds.at(winds, st.x, st.y, st.z)
	local want = math.sqrt(wx * wx + wz * wz)
	local have = math.sqrt(st.vx * st.vx + st.vz * st.vz)
	if not st.landed and want > 6 and have < want * 0.25 then
		mem.stuck += dt
	else
		mem.stuck = 0
	end
	if mem.stuck > 1 then
		mem.climbFor = 1.5
		mem.stuck = 0
	end
	local ctl = 0
	if mem.climbFor > 0 then
		mem.climbFor -= dt
		ctl = 1
	elseif st.y < mem.targetY - 4 then
		ctl = 1
	elseif st.y > mem.targetY + 4 then
		ctl = -1
	end
	if mem.reaction <= 0 then
		mem.out = ctl
		return ctl
	end
	table.insert(mem.queue, { t = mem.t, ctl = ctl })
	while #mem.queue > 0 and mem.queue[1].t <= mem.t - mem.reaction do
		mem.out = table.remove(mem.queue, 1).ctl
	end
	return mem.out
end

return Pilot
