--[[
	Отклик управления — главный риск игры («ватное» управление).
	Шаг 1/60 с, как у клиента.
]]
return function(t)
	local Config = t.shared("Config")
	local Winds = t.shared("Winds")
	local World = t.shared("World")
	local Flight = t.shared("Flight")

	local F = Config.Flight
	local DT = 1 / 60
	local open = { seed = 0, islands = {}, houses = {} } -- открытое море

	local function hover(winds, y)
		local fl = Flight.new(0, y, 0)
		for _ = 1, 120 do
			Flight.step(fl, 0, DT, winds, open)
		end
		return fl
	end

	t.test("burner and valve answer within 0.2 s", function()
		local winds = Winds.generate(1)
		local fl = hover(winds, 100)
		local n = 0
		while fl.vy < F.Climb * 0.5 do
			Flight.step(fl, 1, DT, winds, open)
			n += 1
		end
		t.ok(n * DT <= 0.2, string.format("climb: half speed after %.2f s", n * DT))
		for _ = 1, 120 do
			Flight.step(fl, 1, DT, winds, open)
		end
		n = 0
		while fl.vy > -F.Sink * 0.5 do
			Flight.step(fl, -1, DT, winds, open)
			n += 1
		end
		t.ok(n * DT <= 0.3, string.format("climb → sink: half speed after %.2f s", n * DT))
	end)

	t.test("no buttons → the balloon holds altitude (stops within 4 studs)", function()
		local winds = Winds.generate(2)
		local fl = hover(winds, 100)
		for _ = 1, 90 do
			Flight.step(fl, 1, DT, winds, open)
		end
		local released = fl.y
		for _ = 1, 600 do
			Flight.step(fl, 0, DT, winds, open)
		end
		t.ok(fl.y - released <= 4, string.format("overshoot %.1f studs", fl.y - released))
		local y0 = fl.y
		for _ = 1, 600 do
			Flight.step(fl, 0, DT, winds, open)
		end
		t.near(fl.y, y0, 0.05, "altitude drift over 10 s")
	end)

	t.test("inside a layer the balloon flies with its wind", function()
		local winds = Winds.generate(3)
		for k = 1, #winds.layers do
			local fl = hover(winds, Winds.mid(winds, k))
			for _ = 1, 180 do
				Flight.step(fl, 0, DT, winds, open)
			end
			local l = winds.layers[k]
			local a, sp = Flight.heading(fl)
			t.ok(Winds.angleDiff(a, l.angle) < 2, "layer " .. k .. " heading")
			t.near(sp, l.speed, 0.3, "layer " .. k .. " speed")
		end
	end)

	--[[
		Главная метрика: нажал ВЫШЕ/НИЖЕ в середине слоя → курс в пределах 30° от ветра
		соседнего слоя. 60 наборов ветров × все пары соседних слоёв.
	]]
	t.test("layer change turns the balloon within 2.2 s (60 wind sets)", function()
		local worst, sum, n = 0, 0, 0
		local worstCase = ""
		for seed = 1, 60 do
			local winds = Winds.generate(seed)
			for k = 1, #winds.layers do
				for _, dir in { 1, -1 } do
					local j = k + dir
					if j < 1 or j > #winds.layers then
						continue
					end
					local fl = hover(winds, Winds.mid(winds, k))
					for _ = 1, 120 do
						Flight.step(fl, 0, DT, winds, open)
					end
					local target = winds.layers[j].angle
					local time = 0
					while time < 6 do
						Flight.step(fl, dir, DT, winds, open)
						time += DT
						local a = Flight.heading(fl)
						if Winds.angleDiff(a, target) <= 30 then
							break
						end
					end
					sum += time
					n += 1
					if time > worst then
						worst = time
						worstCase = string.format("seed %d, %d→%d", seed, k, j)
					end
				end
			end
		end
		print(
			string.format(
				"    turn after pressing: mean %.2f s, worst %.2f s (%s)",
				sum / n,
				worst,
				worstCase
			)
		)
		t.ok(worst <= 2.2, string.format("worst %.2f s at %s", worst, worstCase))
		t.ok(sum / n <= 1.8, string.format("mean %.2f s", sum / n))
	end)

	t.test("ceiling, landing on an island, splash on the sea", function()
		local winds = Winds.generate(4)
		local fl = hover(winds, 200)
		for _ = 1, 60 * 12 do
			Flight.step(fl, 1, DT, winds, open)
		end
		t.near(fl.y, Config.Wind.Ceiling, 1e-6, "ceiling")
		local splash = false
		for _ = 1, 60 * 30 do
			if Flight.step(fl, -1, DT, winds, open) == "splash" then
				splash = true
				break
			end
		end
		t.ok(splash, "valve over the sea → splash")

		local world = World.generate(4)
		local isl = world.islands[1]
		local land = Flight.new(isl.x, 30, isl.z)
		local landed, splashed = false, false
		for _ = 1, 60 * 5 do
			local ev = Flight.step(land, -1, DT, winds, world)
			landed = landed or ev == "landed"
			splashed = splashed or ev == "splash"
		end
		t.ok(landed and not splashed and land.landed, "valve over the harbor → landed")
		local x0, z0 = land.x, land.z
		for _ = 1, 60 * 3 do
			Flight.step(land, 0, DT, winds, world)
		end
		local moved = math.sqrt((land.x - x0) ^ 2 + (land.z - z0) ^ 2)
		t.ok(
			moved < 0.8 * 3 * Config.Wind.Surface,
			string.format("landed balloon barely drifts (%.1f)", moved)
		)
	end)

	t.test("a cliff blocks the balloon instead of lifting it", function()
		local world = World.generate(5)
		local isl = world.islands[2]
		-- в море на высоте 2 над водой, «ветер» дует на остров
		local fake = {
			seed = 0,
			layers = {},
			surface = {
				index = 0,
				bottom = -math.huge,
				top = 40,
				angle = 0,
				speed = 5,
				wx = 0,
				wz = 0,
				color = {},
			},
		}
		for i = 1, Config.Wind.Layers do
			fake.layers[i] = fake.surface
		end
		local dx, dz = 1, 0
		fake.surface.wx, fake.surface.wz = dx * 12, dz * 12
		local fl = Flight.new(isl.x - isl.r - 10, 2, isl.z)
		for _ = 1, 60 * 6 do
			Flight.step(fl, 0, DT, fake, world)
		end
		t.ok(fl.x < isl.x - isl.r + Config.World.Beach + 0.5, "stopped at the plateau edge")
		t.ok(fl.y < 3, "did not climb the cliff")
	end)

	t.test("max speed covers what the model can produce", function()
		local h, v = Flight.maxSpeed()
		for seed = 1, 30 do
			local w = Winds.generate(seed)
			for _, l in w.layers do
				t.ok(l.speed <= h, "layer speed")
			end
		end
		t.ok(v >= F.Climb and v >= F.Sink, "vertical")
	end)
end
