--[[
	Экспорт архипелага и гонки ботов в JSON для картинки:
	  lune run scripts/export_map.luau [seed] [build/map.json]
	Затем: python3 scripts/render_map.py build/map.json docs/img/map.png
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local Loader = require("../tests/lib/Loader")
local Config = Loader.shared("Config")
local Winds = Loader.shared("Winds")
local World = Loader.shared("World")
local Flight = Loader.shared("Flight")
local Pilot = Loader.shared("Pilot")
local Race = Loader.shared("Race")

local seed = tonumber(process.args[1]) or 3
local out = process.args[2] or "build/map.json"

local world = World.generate(seed)
local winds = Winds.generate(seed)
local policies = { "pro", "novice" }
local entrants = {}
for i in policies do
	table.insert(entrants, { id = i, name = policies[i], ai = true })
end
local st = Race.new(seed, world, winds, entrants)
local fls, mems, trails = {}, {}, {}
for i, p in policies do
	local x, y, z = Race.start(st, i)
	fls[i] = Flight.new(x, y, z)
	mems[i] = Pilot.new({
		skill = p,
		reaction = if p == "pro" then 0.3 else 0.8,
		think = if p == "pro" then 0.5 else 1,
	})
	trails[i] = {}
end
local k = 0
while not st.done do
	for i in policies do
		local e = st.entrants[i]
		if e.finished then
			continue
		end
		local c = Race.nextCheckpoint(st, i)
		local frozen = Race.isFrozen(st, i)
		local ctl = if c and not frozen
			then Pilot.decide(mems[i], fls[i], { x = c.x, z = c.z, r = c.r }, world, winds, 0.1)
			else 0
		local ev = Flight.step(fls[i], ctl, 0.1, winds, world, frozen)
		if ev == "splash" then
			local x, y, z = Race.splash(st, i)
			Flight.place(fls[i], x, y, z)
		end
		Race.setPos(st, i, fls[i].x, fls[i].y, fls[i].z)
	end
	Race.step(st, 0.1)
	k += 1
	if k % 5 == 0 then
		for i in policies do
			local f = fls[i]
			table.insert(trails[i], { x = f.x, z = f.z, y = f.y, layer = Winds.layerAt(winds, f.y) })
		end
	end
end

local layers = {}
for _, l in winds.layers do
	table.insert(layers, { angle = l.angle, speed = l.speed, color = l.color })
end
fs.writeDir("build")
fs.writeFile(
	out,
	serde.encode("json", {
		seed = seed,
		islands = world.islands,
		houses = world.houses,
		checkpoints = st.course.checkpoints,
		start = st.course.start,
		layers = layers,
		surface = { angle = winds.surface.angle, speed = winds.surface.speed, color = winds.surface.color },
		trails = trails,
		results = {
			{ name = "pro", time = st.entrants[1].time, switches = mems[1].switches },
			{ name = "novice", time = st.entrants[2].time, switches = mems[2].switches },
		},
		spread = Config.World.Spread,
	})
)
print(
	string.format(
		"seed %d: pro %s s (%d switches), novice %s s → %s",
		seed,
		tostring(st.entrants[1].time and math.floor(st.entrants[1].time)),
		mems[1].switches,
		tostring(st.entrants[2].time and math.floor(st.entrants[2].time)),
		out
	)
)
