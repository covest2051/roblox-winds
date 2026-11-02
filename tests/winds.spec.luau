return function(t)
	local Config = t.shared("Config")
	local Winds = t.shared("Winds")

	local W = Config.Wind

	t.test("ceiling = bottom + layers · thickness", function()
		t.eq(W.Ceiling, W.Bottom + W.Layers * W.Thick)
		t.eq(#W.Colors, W.Layers)
	end)

	t.test("any direction is within 45° of some layer (300 seeds)", function()
		local worst = 0
		for seed = 1, 300 do
			local w = Winds.generate(seed)
			for deg = 0, 359, 3 do
				local a = math.rad(deg)
				local best = 180
				for _, l in w.layers do
					best = math.min(best, Winds.angleDiff(a, l.angle))
				end
				worst = math.max(worst, best)
			end
		end
		t.ok(worst <= 46.5, string.format("worst gap %.1f°", worst))
	end)

	t.test("neighbouring layers differ by at least MinTurn (300 seeds)", function()
		local worst = 180
		for seed = 1, 300 do
			local w = Winds.generate(seed)
			for i = 2, #w.layers do
				worst = math.min(worst, Winds.angleDiff(w.layers[i].angle, w.layers[i - 1].angle))
			end
		end
		t.ok(worst >= W.MinTurn, string.format("smallest turn %.1f°", worst))
	end)

	t.test("higher is faster", function()
		for seed = 1, 100 do
			local w = Winds.generate(seed)
			for i = 2, #w.layers do
				t.ok(w.layers[i].speed > w.layers[i - 1].speed, "seed " .. seed .. " layer " .. i)
			end
		end
	end)

	t.test("deterministic", function()
		local a, b = Winds.generate(77), Winds.generate(77)
		for i, l in a.layers do
			t.eq(l.angle, b.layers[i].angle)
			t.eq(l.speed, b.layers[i].speed)
		end
		t.ok(Winds.generate(78).layers[1].angle ~= a.layers[1].angle, "different seed differs")
	end)

	t.test("layer lookup and layer wind inside a layer", function()
		local w = Winds.generate(5)
		t.eq(Winds.layerAt(w, 10), 0)
		t.eq(Winds.layerAt(w, W.Bottom + 1), 1)
		t.eq(Winds.layerAt(w, W.Ceiling - 1), W.Layers)
		t.eq(Winds.layerAt(w, W.Ceiling + 50), W.Layers)
		for k = 1, W.Layers do
			local wx, wz = Winds.atHeight(w, Winds.mid(w, k))
			t.near(wx, w.layers[k].wx, 1e-9)
			t.near(wz, w.layers[k].wz, 1e-9)
		end
		local sx = Winds.atHeight(w, 5)
		t.near(sx, w.surface.wx, 1e-9, "surface breeze")
	end)

	t.test("wind is continuous across boundaries", function()
		for seed = 1, 20 do
			local w = Winds.generate(seed)
			local px, pz = Winds.atHeight(w, 0)
			for i = 1, math.floor(W.Ceiling / 0.05) do
				local wx, wz = Winds.atHeight(w, i * 0.05)
				local d = math.sqrt((wx - px) ^ 2 + (wz - pz) ^ 2)
				t.ok(d < 1.2, string.format("jump %.2f at y=%.2f seed %d", d, i * 0.05, seed))
				px, pz = wx, wz
			end
		end
	end)

	t.test("beyond the edge the wind pushes back", function()
		local w = Winds.generate(9)
		local E = Config.World
		for _, k in { 1, 3, 6 } do
			local y = Winds.mid(w, k)
			local x = E.Edge + 200
			local wx = Winds.at(w, x, y, 0)
			local base = Winds.atHeight(w, y)
			t.ok(wx < base, "pushed inwards")
			t.near(wx, base - E.EdgePush, 1e-9)
		end
	end)

	t.test("bestFor picks the layer that blows that way", function()
		local w = Winds.generate(11)
		for k, l in w.layers do
			local i, c = Winds.bestFor(w, l.wx, l.wz)
			t.eq(i, k)
			t.near(c, 1, 1e-9)
		end
	end)
end
