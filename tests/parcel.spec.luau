--[[
	Посылки: снос ветрами слоёв, попадание на крышу, доставка ботами.
]]
return function(t)
	local Config = t.shared("Config")
	local Winds = t.shared("Winds")
	local World = t.shared("World")
	local Parcel = t.shared("Parcel")
	local Delivery = t.shared("Delivery")
	local Bots = require("./lib/Bots").make(t.shared)

	local P = Config.Parcel
	local open = { seed = 0, islands = {}, houses = {} }

	t.test("a parcel drifts with each layer it falls through", function()
		local w = Winds.generate(6)
		-- из бриза: снос = ветер · Drift · время падения
		local y = 30
		local l = Parcel.predict(w, open, 0, y, 0)
		local tFall = y / P.Fall
		t.near(l.x, w.surface.wx * P.Drift * tFall, 1.5, "x drift")
		t.near(l.z, w.surface.wz * P.Drift * tFall, 1.5, "z drift")
		t.eq(l.kind, "water")
		-- сверху: снос складывается из всех слоёв
		local top = Config.Wind.Ceiling
		local dx, dz = 0, 0
		for _, layer in w.layers do
			dx += layer.wx * P.Drift * Config.Wind.Thick / P.Fall
			dz += layer.wz * P.Drift * Config.Wind.Thick / P.Fall
		end
		dx += w.surface.wx * P.Drift * Config.Wind.Bottom / P.Fall
		dz += w.surface.wz * P.Drift * Config.Wind.Bottom / P.Fall
		local l2 = Parcel.predict(w, open, 0, top, 0, true)
		t.near(l2.x, dx, 6, "sum of layers x")
		t.near(l2.z, dz, 6, "sum of layers z")
		t.near(l2.t, top / P.Fall, 0.15, "fall time")
		t.ok(#(l2.path :: any) >= math.floor(top / P.Fall / 0.5), "path points for the marker")
		local fx, fz = Parcel.drift(w, top, 0)
		t.near(fx, dx, 3, "drift() agrees with predict()")
		t.near(fz, dz, 3)
	end)

	t.test("dropped right above the roof → lands on it", function()
		for seed = 1, 10 do
			local world, w = World.generate(seed), Winds.generate(seed)
			for _, h in world.houses do
				local l = Parcel.predict(w, world, h.x, h.roof + 1, h.z, false, h.id)
				t.ok(Parcel.hits(l, h.id), "house " .. h.id)
			end
		end
	end)

	t.test("roof edge counts, a miss does not", function()
		local world, w = World.generate(2), Winds.generate(2)
		local h = world.houses[3]
		-- падение строго вниз: ветра нет
		local calm = Winds.generate(2)
		for _, l in calm.layers do
			l.wx, l.wz = 0, 0
		end
		calm.surface.wx, calm.surface.wz = 0, 0
		local edge = h.size / 2 + P.Margin - 0.5
		local hit = Parcel.predict(calm, world, h.x + edge, h.roof + 30, h.z, false, h.id)
		t.ok(Parcel.hits(hit, h.id), "edge catches the roof")
		local miss = Parcel.predict(calm, world, h.x + edge + 2, h.roof + 30, h.z, false, h.id)
		t.ok(not Parcel.hits(miss, h.id), "beyond the margin misses")
		t.ok(not Parcel.hits(hit, h.id + 1), "a roof counts only for its own order")
		_ = w
	end)

	t.test("orders: distance range, reward, fast bonus", function()
		local world = World.generate(8)
		local n = 0
		local randInt = function(a, b)
			n += 1
			return a + n % (b - a + 1)
		end
		for _ = 1, 30 do
			local id = Delivery.pick(world, randInt, 0, 0, nil)
			local o = Delivery.newOrder(world, id, 0, 0, 0)
			t.ok(o.dist >= P.MinDist and o.dist <= P.MaxDist, "distance " .. o.dist)
			local slow = Delivery.reward(o, o.par + 1)
			local fast = Delivery.reward(o, o.par - 1)
			t.ok(slow >= Config.Rewards.ParcelBase and slow <= Config.Rewards.ParcelMax, "reward " .. slow)
			t.ok(fast > slow, "fast bonus")
		end
		local ex = { [1] = true, [2] = true }
		for _ = 1, 20 do
			local id = Delivery.pick(world, randInt, 0, 0, ex)
			t.ok(not ex[id], "exclude respected")
		end
	end)

	t.test("bots deliver: steering the drop marker onto a roof is doable", function()
		local stats = {}
		for _, policy in { "novice", "pro" } do
			local ok, n, times = 0, 0, {}
			for seed = 1, 15 do
				for _, r in Bots.deliver(seed, policy, 3) do
					n += 1
					if r.ok then
						ok += 1
						table.insert(times, r.time)
					end
				end
			end
			table.sort(times)
			local median = times[math.max(1, math.floor(#times / 2))] or math.huge
			print(string.format("    deliver %-6s %d/%d, median %.0f s", policy, ok, n, median))
			stats[policy] = { rate = ok / n, median = median }
		end
		t.ok(stats.novice.rate >= 0.9, "novice delivery rate " .. stats.novice.rate)
		t.ok(stats.pro.rate >= 0.9, "pro delivery rate " .. stats.pro.rate)
		t.ok(stats.novice.median <= 90, "median delivery time " .. stats.novice.median)
	end)
end
