--[[
	World — архипелаг из seed: острова (плато + пляж), дома с плоскими крышами (цели доставки),
	маяки. Высота поверхности в любой точке (groundAt) — для физики шара и сноса посылок:
	те же числа строят острова в игре, поэтому модель и движок совпадают.
	Трасса гонки (course) — цепочка островов от гавани.
]]

local Shared = script.Parent
local Config = require(Shared.Config)
local Rng = require(Shared.Rng)

local World = {}

export type House = {
	id: number,
	island: number,
	x: number,
	z: number,
	size: number,
	roof: number,
	base: number,
}
export type Island = {
	id: number,
	x: number,
	z: number,
	r: number,
	top: number,
	harbor: boolean,
	houses: { number },
	lighthouse: { x: number, z: number, top: number }?,
	trees: { { x: number, z: number, h: number } },
}
export type World = { seed: number, islands: { Island }, houses: { House } }
export type Checkpoint = { x: number, z: number, r: number, island: number }
export type Course = {
	start: { x: number, z: number, y: number, dirX: number, dirZ: number },
	checkpoints: { Checkpoint }, -- последний — финиш
	length: number,
}

local function dist(ax: number, az: number, bx: number, bz: number): number
	return math.sqrt((ax - bx) ^ 2 + (az - bz) ^ 2)
end
World.dist = dist

local function addHouses(w: World, isl: Island, rng, count: number, keepOut: number)
	local E = Config.World
	local placed = 0
	for _ = 1, 200 do
		if placed >= count then
			break
		end
		local a = rng:range(0, math.pi * 2)
		local maxR = isl.r - E.Beach - E.HouseSize * 0.75
		local rr = rng:range(keepOut, math.max(keepOut + 1, maxR))
		local x, z = isl.x + math.cos(a) * rr, isl.z + math.sin(a) * rr
		local ok = true
		for _, hid in isl.houses do
			local h = w.houses[hid]
			if dist(h.x, h.z, x, z) < E.HouseGap then
				ok = false
				break
			end
		end
		if ok and isl.lighthouse and dist(isl.lighthouse.x, isl.lighthouse.z, x, z) < E.HouseGap then
			ok = false
		end
		if ok then
			local h: House = {
				id = #w.houses + 1,
				island = isl.id,
				x = x,
				z = z,
				size = E.HouseSize,
				base = isl.top,
				roof = isl.top + rng:range(E.HouseH[1], E.HouseH[2]),
			}
			table.insert(w.houses, h)
			table.insert(isl.houses, h.id)
			placed += 1
		end
	end
end

function World.generate(seed: number): World
	local E = Config.World
	local rng = Rng.new(seed * 104729 + 7)
	local w: World = { seed = seed, islands = {}, houses = {} }
	local harbor: Island = {
		id = 1,
		x = 0,
		z = 0,
		r = E.HarborR,
		top = E.HarborTop,
		harbor = true,
		houses = {},
		trees = {},
	}
	table.insert(w.islands, harbor)
	local tries = 0
	while #w.islands < E.Islands and tries < 4000 do
		tries += 1
		local a = rng:range(0, math.pi * 2)
		local rr = math.sqrt(rng:next()) * E.Spread
		local x, z = math.cos(a) * rr, math.sin(a) * rr
		local ok = true
		for _, o in w.islands do
			if dist(o.x, o.z, x, z) < E.MinGap then
				ok = false
				break
			end
		end
		if ok then
			local isl: Island = {
				id = #w.islands + 1,
				x = x,
				z = z,
				r = rng:range(E.IslandR[1], E.IslandR[2]),
				top = rng:range(E.Top[1], E.Top[2]),
				harbor = false,
				houses = {},
				trees = {},
			}
			if rng:next() < E.Lighthouse then
				local la = rng:range(0, math.pi * 2)
				local lr = isl.r - E.Beach - 6
				isl.lighthouse = {
					x = x + math.cos(la) * lr,
					z = z + math.sin(la) * lr,
					top = isl.top + E.LighthouseH,
				}
			end
			table.insert(w.islands, isl)
		end
	end
	-- дома: в гавани — почта на краю поля, на островах — деревни
	addHouses(w, harbor, rng, 2, harbor.r - E.Beach - E.HouseSize * 0.75 - 2)
	for i = 2, #w.islands do
		addHouses(w, w.islands[i], rng, rng:int(E.Houses[1], E.Houses[2]), 0)
	end
	-- деревья: только декор (шар сквозь крону пролетает — их нет в groundAt)
	for _, isl in w.islands do
		local n = if isl.harbor then 6 else rng:int(4, 9)
		for _ = 1, n * 3 do
			if #isl.trees >= n then
				break
			end
			local a = rng:range(0, math.pi * 2)
			local rr = rng:range(if isl.harbor then isl.r * 0.7 else 4, isl.r - E.Beach - 3)
			local x, z = isl.x + math.cos(a) * rr, isl.z + math.sin(a) * rr
			local free = true
			for _, hid in isl.houses do
				if dist(w.houses[hid].x, w.houses[hid].z, x, z) < 14 then
					free = false
				end
			end
			if free then
				table.insert(isl.trees, { x = x, z = z, h = rng:range(9, 16) })
			end
		end
	end
	return w
end

-- Высота поверхности (вода = Config.World.Water) и что там: "water" | "island" | "roof" | "tower"
function World.groundAt(w: World, x: number, z: number): (number, string, number?)
	local E = Config.World
	for _, isl in w.islands do
		local dx, dz = x - isl.x, z - isl.z
		if math.abs(dx) <= isl.r and math.abs(dz) <= isl.r then
			local d = math.sqrt(dx * dx + dz * dz)
			if d <= isl.r then
				local lh = isl.lighthouse
				if lh and dist(lh.x, lh.z, x, z) <= E.LighthouseR then
					return lh.top, "tower", nil
				end
				local half = E.HouseSize / 2
				for _, hid in isl.houses do
					local h = w.houses[hid]
					if math.abs(x - h.x) <= half and math.abs(z - h.z) <= half then
						return h.roof, "roof", h.id
					end
				end
				if d <= isl.r - E.Beach then
					return isl.top, "island", nil
				end
				return E.BeachH, "island", nil
			end
		end
	end
	return E.Water, "water", nil
end

-- Остров под точкой (или nil)
function World.islandAt(w: World, x: number, z: number): Island?
	for _, isl in w.islands do
		if dist(isl.x, isl.z, x, z) <= isl.r then
			return isl
		end
	end
	return nil
end

--[[
	Трасса: гавань → Checkpoints островов → финиш (ещё один остров).
	Каждое плечо LegMin..LegMax, острова не повторяются, трасса поворачивает
	(угол между плечами ≥ TurnMin): одним слоем не пролететь.
]]
function World.course(w: World, seed: number): Course
	local R = Config.Race
	local rng = Rng.new(seed * 31337 + 3)
	local n = R.Checkpoints + 1
	local best: { Island }? = nil
	-- сначала строгие правила, потом мягче (редкие неудобные архипелаги)
	local rules = {
		{ R.LegMin, R.LegMax, R.TurnMin },
		{ R.LegMin * 0.85, R.LegMax * 1.15, R.TurnMin * 0.5 },
		{ R.LegMin * 0.6, R.LegMax * 1.4, 0 },
	}
	for _, rule in rules do
		local legMin, legMax, turnMin = rule[1], rule[2], rule[3]
		for _ = 1, 300 do
			local path = { w.islands[1] }
			local used = { [1] = true }
			local ok = true
			for _ = 1, n do
				local cur = path[#path]
				local prev = path[#path - 1]
				local cands = {}
				for _, isl in w.islands do
					if not used[isl.id] then
						local d = dist(cur.x, cur.z, isl.x, isl.z)
						if d >= legMin and d <= legMax then
							local turnOk = true
							if prev then
								local ax, az = cur.x - prev.x, cur.z - prev.z
								local bx, bz = isl.x - cur.x, isl.z - cur.z
								local c = (ax * bx + az * bz)
									/ (math.sqrt(ax * ax + az * az) * math.sqrt(bx * bx + bz * bz))
								turnOk = math.deg(math.acos(math.clamp(c, -1, 1))) >= turnMin
							end
							if turnOk then
								table.insert(cands, isl)
							end
						end
					end
				end
				if #cands == 0 then
					ok = false
					break
				end
				local pick = cands[rng:int(1, #cands)]
				used[pick.id] = true
				table.insert(path, pick)
			end
			if ok then
				best = path
				break
			end
		end
		if best then
			break
		end
	end
	if not best then
		-- последний вариант: острова по порядку
		local path = { w.islands[1] }
		for i = 2, math.min(#w.islands, n + 1) do
			table.insert(path, w.islands[i])
		end
		best = path
	end
	local path = best :: { Island }
	local cps = {}
	local length = 0
	for i = 2, #path do
		local isl = path[i]
		table.insert(cps, { x = isl.x, z = isl.z, r = R.CheckR, island = isl.id })
		length += dist(path[i - 1].x, path[i - 1].z, isl.x, isl.z)
	end
	local h = path[1]
	local dx, dz = cps[1].x - h.x, cps[1].z - h.z
	local l = math.sqrt(dx * dx + dz * dz)
	return {
		start = { x = h.x, z = h.z, y = h.top, dirX = dx / l, dirZ = dz / l },
		checkpoints = cps,
		length = length,
	}
end

-- Места на старте: ряды по GridRow поперёк направления на первый чекпоинт
function World.grid(course: Course, n: number): { { x: number, z: number } }
	local R = Config.Race
	local s = course.start
	local px, pz = -s.dirZ, s.dirX
	local out = {}
	for i = 1, n do
		local row = math.floor((i - 1) / R.GridRow)
		local col = (i - 1) % R.GridRow
		local inRow = math.min(R.GridRow, n - row * R.GridRow)
		local off = (col - (inRow - 1) / 2) * R.GridGap
		local back = -row * R.GridGap
		table.insert(out, {
			x = s.x + px * off + s.dirX * back,
			z = s.z + pz * off + s.dirZ * back,
		})
	end
	return out
end

return World
