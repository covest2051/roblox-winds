--[[
	Баланс гонки на ботах (чистая модель). Голова ботов — src/shared/Pilot, та же, что у ИИ.
	Проверяем, что игра — про смену слоёв:
	  • пилот, который ищет нужный слой, финиширует почти всегда и укладывается в 2–3 минуты;
	  • новичок с медленной реакцией (0.8 с, решает раз в секунду) тоже финиширует;
	  • кто не меняет высоту — не финиширует; кто меняет наугад — тоже;
	  • за гонку пилот меняет слой много раз и использует разные слои.
]]
return function(t)
	local Config = t.shared("Config")
	local Race = t.shared("Race")
	local World = t.shared("World")
	local Winds = t.shared("Winds")
	local Bots = require("./lib/Bots").make(t.shared)

	local function summary(policy: string, seeds: number)
		local fin, times, switches, used, layerUse = 0, {}, 0, 0, {}
		for seed = 1, seeds do
			local _, stats = Bots.race(seed, { policy })
			local s = stats[1]
			if s.time then
				fin += 1
				table.insert(times, s.time)
			end
			switches += s.switches
			used += s.used
			for k in s.usedSet do
				layerUse[k] = (layerUse[k] or 0) + 1
			end
		end
		table.sort(times)
		local median = times[math.max(1, math.floor(#times / 2))] or math.huge
		print(
			string.format(
				"    %-7s finished %d/%d, median %.0f s, switches %.1f, layers used %.1f",
				policy,
				fin,
				seeds,
				median,
				switches / seeds,
				used / seeds
			)
		)
		return {
			fin = fin / seeds,
			median = median,
			switches = switches / seeds,
			used = used / seeds,
			layerUse = layerUse,
			times = times,
		}
	end

	local pro, novice

	t.test("a pilot who looks for the right layer finishes in 2–3 minutes", function()
		pro = summary("pro", 30)
		t.ok(pro.fin >= 0.95, "finish rate " .. pro.fin)
		t.ok(pro.median >= 90 and pro.median <= 180, "median " .. pro.median)
		t.ok(pro.switches >= 4, "layer switches per race " .. pro.switches)
		t.ok(pro.used >= 3, "different layers per race " .. pro.used)
	end)

	t.test("every layer is useful in some races", function()
		for k = 1, Config.Wind.Layers do
			t.ok(
				(pro.layerUse[k] or 0) >= 6,
				"layer " .. k .. " used in " .. tostring(pro.layerUse[k]) .. "/30"
			)
		end
	end)

	t.test("a slow novice still finishes, a bit slower", function()
		novice = summary("novice", 20)
		t.ok(novice.fin >= 0.85, "finish rate " .. novice.fin)
		t.ok(novice.median <= Config.Race.MaxTime * 0.8, "median " .. novice.median)
		t.ok(novice.median >= pro.median * 0.95, "the better pilot is not slower")
	end)

	t.test("never changing altitude does not finish", function()
		local passive = summary("passive", 12)
		t.ok(passive.fin <= 0.1, "finish rate " .. passive.fin)
	end)

	t.test("random altitude changes do not finish either", function()
		local random = summary("random", 12)
		t.ok(random.fin <= 0.25, "finish rate " .. random.fin)
	end)

	t.test("six AI pilots: race ends, places are unique, standings sorted", function()
		for seed = 1, 4 do
			local st, stats = Bots.race(seed, { "pro", "pro", "novice", "novice", "pro", "novice" })
			t.ok(st.done, "race over")
			local places = {}
			local finished = 0
			for _, s in stats do
				if s.place then
					t.ok(not places[s.place], "unique place")
					places[s.place] = true
					finished += 1
				end
			end
			t.ok(finished >= 4, "most AI finish (" .. finished .. ")")
			local order = Race.standings(st)
			for i = 2, #order do
				t.ok(Race.progress(st, order[i - 1]) >= Race.progress(st, order[i]), "sorted")
			end
			local first = st.entrants[order[1]]
			t.eq(first.place, 1)
			t.eq(Race.reward(st, order[1]), Config.Rewards.Places[1])
		end
	end)

	t.test("countdown freezes, splash returns to the last checkpoint", function()
		local world, winds = World.generate(3), Winds.generate(3)
		local st = Race.new(3, world, winds, {
			{ id = "a", name = "A", ai = false },
			{ id = "b", name = "B", ai = false },
		})
		t.ok(Race.isFrozen(st, "a"), "frozen before the start")
		local ev = Race.step(st, Config.Race.Countdown - 0.05)
		t.eq(#ev, 0)
		ev = Race.step(st, 0.1)
		t.eq(ev[1].t, "go")
		t.ok(not Race.isFrozen(st, "a"), "go")
		-- первый чекпоинт
		local c1 = st.course.checkpoints[1]
		Race.setPos(st, "a", c1.x + c1.r - 1, 80, c1.z)
		ev = Race.step(st, 0.1)
		t.eq(ev[1].t, "cp")
		t.eq(ev[1].n, 1)
		local x, y, z = Race.splash(st, "a")
		t.eq(x, c1.x)
		t.eq(z, c1.z)
		t.ok(y >= Config.Wind.Bottom, "back in the air")
		t.ok(Race.isFrozen(st, "a"), "frozen after a splash")
		-- b — без чекпоинтов: на старт
		local bx, _, bz = Race.splash(st, "b")
		local sx, _, sz = Race.start(st, "b")
		t.eq(bx, sx)
		t.eq(bz, sz)
		-- финиш a
		for i = 2, #st.course.checkpoints do
			local c = st.course.checkpoints[i]
			Race.setPos(st, "a", c.x, 80, c.z)
			Race.step(st, Config.Flight.SplashTime)
		end
		t.ok(st.entrants.a.finished and st.entrants.a.place == 1, "a finished first")
		t.ok(not st.done, "b still racing")
		Race.step(st, Config.Race.AfterFirst)
		t.ok(st.done, "race ends AfterFirst seconds after the first finish")
		t.eq(Race.reward(st, "b"), 0)
	end)

	t.test("a racer who leaves does not block the end", function()
		local world, winds = World.generate(4), Winds.generate(4)
		local st = Race.new(4, world, winds, { { id = 1, name = "x", ai = false } })
		Race.step(st, Config.Race.Countdown + 0.1)
		Race.leave(st, 1)
		local ev = Race.step(st, 0.1)
		t.ok(st.done and ev[#ev].t == "end", "no active racers → end")
	end)
end
