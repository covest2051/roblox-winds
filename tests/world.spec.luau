return function(t)
	local Config = t.shared("Config")
	local World = t.shared("World")

	local E, R = Config.World, Config.Race

	t.test("islands: count, spacing, inside the map (40 seeds)", function()
		for seed = 1, 40 do
			local w = World.generate(seed)
			t.eq(#w.islands, E.Islands, "seed " .. seed)
			t.ok(w.islands[1].harbor and w.islands[1].x == 0 and w.islands[1].z == 0, "harbor in the center")
			for i, a in w.islands do
				t.ok(World.dist(0, 0, a.x, a.z) <= E.Spread + 1e-6, "inside")
				for j = i + 1, #w.islands do
					local b = w.islands[j]
					t.ok(World.dist(a.x, a.z, b.x, b.z) >= E.MinGap, "gap")
				end
			end
		end
	end)

	t.test("houses: on the plateau, apart, groundAt gives the roof", function()
		for seed = 1, 40 do
			local w = World.generate(seed)
			for _, isl in w.islands do
				t.ok(#isl.houses >= 2, "seed " .. seed .. " island " .. isl.id .. " has houses")
				for i, hid in isl.houses do
					local h = w.houses[hid]
					local half = h.size / 2
					local far = World.dist(isl.x, isl.z, h.x, h.z) + half * math.sqrt(2)
					t.ok(far <= isl.r - E.Beach + 1e-6, "house on the plateau")
					t.ok(h.roof > isl.top + 5, "roof above the ground")
					local g, kind, id = World.groundAt(w, h.x, h.z)
					t.eq(g, h.roof)
					t.eq(kind, "roof")
					t.eq(id, h.id)
					for j = i + 1, #isl.houses do
						local o = w.houses[isl.houses[j]]
						t.ok(World.dist(h.x, h.z, o.x, o.z) >= E.HouseGap, "houses apart")
					end
				end
			end
		end
	end)

	t.test("ground profile: sea, beach, plateau, lighthouse", function()
		local seen = { tower = false }
		for seed = 1, 20 do
			local w = World.generate(seed)
			t.eq((World.groundAt(w, 5000, 5000)), E.Water)
			for _, isl in w.islands do
				local g = World.groundAt(w, isl.x + isl.r - 1, isl.z)
				t.eq(g, E.BeachH, "beach")
				if isl.lighthouse then
					local lh = isl.lighthouse
					local gl, kind = World.groundAt(w, lh.x, lh.z)
					t.eq(kind, "tower")
					t.eq(gl, lh.top)
					seen.tower = true
				end
			end
		end
		t.ok(seen.tower, "some islands have a lighthouse")
	end)

	t.test("course: legs, turns, no repeats (60 seeds; strict rules ≥ 90%)", function()
		local lengths = {}
		local strict = 0
		for seed = 1, 60 do
			local w = World.generate(seed)
			local c = World.course(w, seed * 3)
			t.eq(#c.checkpoints, R.Checkpoints + 1)
			local used = { [1] = true }
			local px, pz = c.start.x, c.start.z
			local pdx, pdz = nil, nil
			local isStrict = true
			for _, cp in c.checkpoints do
				t.ok(not used[cp.island], "island used once")
				used[cp.island] = true
				local d = World.dist(px, pz, cp.x, cp.z)
				t.ok(d >= R.LegMin * 0.6 - 1e-6 and d <= R.LegMax * 1.4 + 1e-6, string.format("leg %.0f", d))
				isStrict = isStrict and d >= R.LegMin - 1e-6 and d <= R.LegMax + 1e-6
				local dx, dz = (cp.x - px) / d, (cp.z - pz) / d
				if pdx then
					local turn = math.deg(math.acos(math.clamp(dx * pdx + dz * pdz, -1, 1)))
					isStrict = isStrict and turn >= R.TurnMin - 1e-6
				end
				pdx, pdz = dx, dz
				px, pz = cp.x, cp.z
			end
			if isStrict then
				strict += 1
			end
			table.insert(lengths, c.length)
		end
		table.sort(lengths)
		print(
			string.format(
				"    course length: min %.0f, median %.0f, max %.0f; strict %d/60",
				lengths[1],
				lengths[30],
				lengths[60],
				strict
			)
		)
		t.ok(strict >= 54, "strict courses " .. strict)
	end)

	t.test("start grid: 12 balloons on the harbor field, apart", function()
		for seed = 1, 20 do
			local w = World.generate(seed)
			local c = World.course(w, seed)
			local g = World.grid(c, R.Max)
			t.eq(#g, R.Max)
			for i, p in g do
				local h, kind = World.groundAt(w, p.x, p.z)
				t.eq(kind, "island", "seed " .. seed .. " slot " .. i)
				t.eq(h, E.HarborTop, "on the field, not on a roof or the beach")
				for j = i + 1, #g do
					t.ok(World.dist(p.x, p.z, g[j].x, g[j].z) >= R.GridGap - 1e-6, "apart")
				end
			end
		end
	end)
end
