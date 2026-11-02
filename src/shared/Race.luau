--[[
	Race — гонка целиком, без инстансов: старт на поле гавани, чекпоинты (столбы радиусом CheckR
	на всю высоту), финиш, «намок» → старт с последнего чекпоинта, места, конец гонки.
	Позиции шаров приходят снаружи (сервер — из CFrame, тесты — из Flight).

	t < 0 — отсчёт; шары стоят. Конец: все финишировали, AfterFirst секунд после первого
	финиша или MaxTime.
]]

local Shared = script.Parent
local Config = require(Shared.Config)
local World = require(Shared.World)
local Winds = require(Shared.Winds)

local Race = {}

export type Entrant = {
	id: any,
	name: string,
	ai: boolean,
	cp: number, -- сколько чекпоинтов пройдено (последний — финиш)
	finished: boolean,
	place: number?,
	time: number?,
	x: number,
	y: number,
	z: number,
	splashes: number,
	frozenUntil: number,
	left: boolean,
}
export type State = {
	seed: number,
	world: any,
	winds: any,
	course: World.Course,
	t: number,
	phase: string, -- countdown | race | done
	entrants: { [any]: Entrant },
	order: { any },
	finishedN: number,
	firstFinish: number?,
	done: boolean,
	starts: { [any]: { x: number, y: number, z: number } },
}

function Race.new(seed: number, world, winds, entrants: { { id: any, name: string, ai: boolean } }): State
	local course = World.course(world, seed)
	local grid = World.grid(course, #entrants)
	local st: State = {
		seed = seed,
		world = world,
		winds = winds,
		course = course,
		t = -Config.Race.Countdown,
		phase = "countdown",
		entrants = {},
		order = {},
		finishedN = 0,
		firstFinish = nil,
		done = false,
		starts = {},
	}
	for i, e in entrants do
		local g = grid[i]
		local y = World.groundAt(world, g.x, g.z)
		st.entrants[e.id] = {
			id = e.id,
			name = e.name,
			ai = e.ai,
			cp = 0,
			finished = false,
			place = nil,
			time = nil,
			x = g.x,
			y = y,
			z = g.z,
			splashes = 0,
			frozenUntil = 0,
			left = false,
		}
		st.starts[e.id] = { x = g.x, y = y, z = g.z }
		table.insert(st.order, e.id)
	end
	return st
end

function Race.start(st: State, id: any): (number, number, number)
	local s = st.starts[id]
	return s.x, s.y, s.z
end

function Race.setPos(st: State, id: any, x: number, y: number, z: number)
	local e = st.entrants[id]
	if e then
		e.x, e.y, e.z = x, y, z
	end
end

function Race.isFrozen(st: State, id: any): boolean
	local e = st.entrants[id]
	return st.t < 0 or (e ~= nil and st.t < e.frozenUntil)
end

function Race.nextCheckpoint(st: State, id: any): World.Checkpoint?
	local e = st.entrants[id]
	if not e or e.finished then
		return nil
	end
	return st.course.checkpoints[e.cp + 1]
end

-- Шар коснулся воды: точка возврата над последним пройденным чекпоинтом (или над стартом)
function Race.splash(st: State, id: any): (number, number, number)
	local e = st.entrants[id]
	local R = Config.Race
	local x, z
	if e.cp > 0 then
		local c = st.course.checkpoints[e.cp]
		x, z = c.x, c.z
	else
		local s = st.starts[id]
		x, z = s.x, s.z
	end
	local y = math.max(R.RespawnY, Winds.mid(st.winds, 1))
	e.splashes += 1
	e.frozenUntil = st.t + Config.Flight.SplashTime
	e.x, e.y, e.z = x, y, z
	return x, y, z
end

-- Игрок ушёл с сервера / вышел из гонки
function Race.leave(st: State, id: any)
	local e = st.entrants[id]
	if e then
		e.left = true
	end
end

-- Прогресс для таблицы мест (больше — впереди)
function Race.progress(st: State, id: any): number
	local e = st.entrants[id]
	if e.finished then
		return 1e9 - (e.place :: number)
	end
	local c = st.course.checkpoints[e.cp + 1]
	local d = if c then World.dist(e.x, e.z, c.x, c.z) else 0
	return e.cp * 10000 - d
end

function Race.standings(st: State): { any }
	local ids = {}
	for _, id in st.order do
		if not st.entrants[id].left then
			table.insert(ids, id)
		end
	end
	table.sort(ids, function(a, b)
		return Race.progress(st, a) > Race.progress(st, b)
	end)
	return ids
end

function Race.step(st: State, dt: number): { { [string]: any } }
	local events = {}
	if st.done then
		return events
	end
	local R = Config.Race
	local wasCountdown = st.t < 0
	st.t += dt
	if wasCountdown then
		if st.t >= 0 then
			st.phase = "race"
			table.insert(events, { t = "go" })
		else
			return events
		end
	end
	local cps = st.course.checkpoints
	local active = 0
	for _, id in st.order do
		local e = st.entrants[id]
		if e.left or e.finished then
			continue
		end
		active += 1
		local c = cps[e.cp + 1]
		if c and st.t >= e.frozenUntil and World.dist(e.x, e.z, c.x, c.z) <= c.r then
			e.cp += 1
			if e.cp >= #cps then
				e.finished = true
				st.finishedN += 1
				e.place = st.finishedN
				e.time = st.t
				st.firstFinish = st.firstFinish or st.t
				active -= 1
				table.insert(events, { t = "finish", id = id, place = e.place, time = e.time })
			else
				table.insert(events, { t = "cp", id = id, n = e.cp, total = #cps })
			end
		end
	end
	local over = active == 0
		or st.t >= R.MaxTime
		or (st.firstFinish ~= nil and st.t - st.firstFinish >= R.AfterFirst)
	if over then
		st.done = true
		st.phase = "done"
		table.insert(events, { t = "end" })
	end
	return events
end

-- Сколько «сырых» монет за гонку (до множителей)
function Race.reward(st: State, id: any): number
	local e = st.entrants[id]
	local W = Config.Rewards
	if e.finished then
		return W.Places[e.place :: number] or W.Places[#W.Places]
	end
	return e.cp * W.PerCheckpoint
end

return Race
