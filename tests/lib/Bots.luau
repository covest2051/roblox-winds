--[[
	Bots — гонки и доставки на чистой модели (без движка) для тестов баланса.
	Голова — src/shared/Pilot (та же, что ведёт ИИ-соперников в игре); здесь только
	«тело» (Flight) и дополнительные тестовые политики:
	  "pro"     — Pilot skill=pro (оценивает время до цели с учётом смены высоты);
	  "novice"  — Pilot skill=novice («найди слой, который дует к цели»), реакция 0.8 с;
	  "passive" — взлетел в лучший на старте слой и больше ничего не трогает;
	  "random"  — раз в 3–6 с выбирает случайный слой.

	local Bots = require("./lib/Bots").make(shared)
	Bots.race(seed, policies, opts?) → st, stats[id] = { time?, place?, switches, used, splashes, cp }
	Bots.deliver(seed, policy, n?) → { {ok, time, dist} }
	Bots.drive(mem, policy, fl, goal, world, winds, dt) → ctl   -- одно решение (для движка)
]]

local Bots = {}

function Bots.make(shared)
	local Config = shared("Config")
	local Winds = shared("Winds")
	local World = shared("World")
	local Flight = shared("Flight")
	local Pilot = shared("Pilot")
	local Race = shared("Race")
	local Delivery = shared("Delivery")
	local Rng = shared("Rng")

	local DT = Config.Ai.Step

	local function newMem(policy: string, seed: number)
		if policy == "pro" then
			return Pilot.new({ skill = "pro", reaction = 0.3 })
		elseif policy == "novice" then
			return Pilot.new({ skill = "novice", reaction = 0.8, think = 1 })
		end
		local m = Pilot.new({ skill = "pro" })
		m.policy = policy
		m.rng = Rng.new(seed)
		m.next = 0
		return m
	end

	local function drive(mem, policy, fl, goal, world, winds, dt)
		if policy == "pro" or policy == "novice" then
			return Pilot.decide(mem, fl, goal, world, winds, dt)
		end
		mem.t += dt
		if policy == "passive" then
			if not mem.layer then
				Pilot.choose(mem, fl, goal, world, winds)
			end
		elseif policy == "random" then
			if mem.t >= mem.next then
				mem.next = mem.t + mem.rng:range(3, 6)
				local k = mem.rng:int(1, #winds.layers)
				if mem.layer and k ~= mem.layer then
					mem.switches += 1
				end
				mem.layer = k
				mem.used[k] = true
				mem.targetY = Winds.mid(winds, k)
			end
		end
		if fl.y < mem.targetY - 4 then
			return 1
		elseif fl.y > mem.targetY + 4 then
			return -1
		end
		return 0
	end

	-- policies: список политик (по одной на шар); opts: { worldSeed, windSeed }
	local function race(seed: number, policies: { string }, opts: { [string]: any }?)
		local o = opts or {}
		local world = World.generate(o.worldSeed or seed)
		local winds = Winds.generate(o.windSeed or seed)
		local entrants = {}
		for i in policies do
			table.insert(entrants, { id = i, name = "bot" .. i, ai = true })
		end
		local st = Race.new(seed, world, winds, entrants)
		local fls, mems = {}, {}
		for i, policy in policies do
			local x, y, z = Race.start(st, i)
			fls[i] = Flight.new(x, y, z)
			mems[i] = if o.mem then o.mem(i) else newMem(policy, seed * 100 + i)
		end
		local stats = {}
		for i in policies do
			stats[i] = { splashes = 0 }
		end
		while not st.done do
			for i, policy in policies do
				local e = st.entrants[i]
				if e.finished then
					continue
				end
				local fl = fls[i]
				local frozen = Race.isFrozen(st, i)
				local c = Race.nextCheckpoint(st, i)
				local ctl = 0
				if c and not frozen then
					ctl = drive(mems[i], policy, fl, { x = c.x, z = c.z, r = c.r }, world, winds, DT)
				end
				local ev = Flight.step(fl, ctl, DT, winds, world, frozen)
				if ev == "splash" then
					local x, y, z = Race.splash(st, i)
					Flight.place(fl, x, y, z)
					stats[i].splashes += 1
				end
				Race.setPos(st, i, fl.x, fl.y, fl.z)
			end
			Race.step(st, DT)
		end
		for i in policies do
			local e = st.entrants[i]
			local s = stats[i]
			s.time = e.time
			s.place = e.place
			s.cp = e.cp
			s.switches = mems[i].switches
			local n = 0
			for _ in mems[i].used do
				n += 1
			end
			s.used = n
			s.usedSet = mems[i].used
		end
		return st, stats
	end

	-- n доставок подряд одним шаром из гавани. Возвращает { {ok, time, dist} }
	local function deliver(seed: number, policy: string, n: number?, opts: { [string]: any }?)
		local o = opts or {}
		local world = World.generate(o.worldSeed or seed)
		local winds = Winds.generate(o.windSeed or seed)
		local rng = Rng.new(seed * 17 + 5)
		local randInt = function(a, b)
			return rng:int(a, b)
		end
		local h = world.islands[1]
		local fl = Flight.new(h.x, World.groundAt(world, h.x, h.z), h.z)
		local out = {}
		local t = 0
		for _ = 1, n or 3 do
			local house = Delivery.pick(world, randInt, fl.x, fl.z, nil)
			local order = Delivery.newOrder(world, house, fl.x, fl.z, t)
			local mem = newMem(policy, seed)
			local goal = { x = order.x, z = order.z, r = 8, house = house }
			local ok = false
			local t0 = t
			while t - t0 < (o.timeout or 240) do
				local ctl = drive(mem, policy, fl, goal, world, winds, DT)
				local ev = Flight.step(fl, ctl, DT, winds, world)
				t += DT
				if ev == "splash" then
					Flight.place(fl, fl.x, Winds.mid(winds, 1), fl.z)
				end
				if Delivery.check(order, winds, world, fl.x, fl.y, fl.z) then
					ok = true
					break
				end
			end
			table.insert(
				out,
				{ ok = ok, time = t - t0, dist = order.dist, par = order.par, switches = mem.switches }
			)
		end
		return out
	end

	return {
		race = race,
		deliver = deliver,
		drive = drive,
		newMem = newMem,
	}
end

return Bots
