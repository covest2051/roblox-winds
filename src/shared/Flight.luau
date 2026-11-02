--[[
	Flight — физика воздушного шара. Одна и та же функция работает:
	  • на клиенте для своего шара (результат — скорость для LinearVelocity, без сетевой задержки);
	  • на сервере для ИИ-шаров;
	  • в тестах (боты, тест отклика).

	Управление ctl: 1 — горелка (вверх), -1 — клапан (вниз), 0 — держать высоту.
	Вертикаль догоняет цель за TauV, горизонталь догоняет ветер слоя за TauH.
	Позиция шара — низ корзины.
]]

local Shared = script.Parent
local Config = require(Shared.Config)
local Winds = require(Shared.Winds)
local World = require(Shared.World)

local Flight = {}

export type State = {
	x: number,
	y: number,
	z: number,
	vx: number,
	vy: number,
	vz: number,
	ctl: number,
	landed: boolean,
	surface: string,
}

function Flight.new(x: number, y: number, z: number): State
	return { x = x, y = y, z = z, vx = 0, vy = 0, vz = 0, ctl = 0, landed = false, surface = "air" }
end

-- Сбросить скорость (телепорт, старт гонки)
function Flight.place(st: State, x: number, y: number, z: number)
	st.x, st.y, st.z = x, y, z
	st.vx, st.vy, st.vz = 0, 0, 0
	st.landed = false
end

function Flight.targetVy(ctl: number): number
	local F = Config.Flight
	if ctl > 0 then
		return F.Climb
	elseif ctl < 0 then
		return -F.Sink
	end
	return 0
end

-- Максимальная скорость, которую может развить шар (для проверки на сервере)
function Flight.maxSpeed(): (number, number)
	local W, F, E = Config.Wind, Config.Flight, Config.World
	return W.SpeedMax + W.SpeedJitter + E.EdgePush, math.max(F.Climb, F.Sink)
end

--[[
	Один шаг. Возвращает событие: "splash" (коснулся воды), "landed" (сел на сушу) или nil.
	frozen = true — шар стоит (отсчёт перед стартом, «намок»).
]]
function Flight.step(st: State, ctl: number, dt: number, winds, world, frozen: boolean?): string?
	local F, E = Config.Flight, Config.World
	st.ctl = ctl
	if frozen then
		st.vx, st.vy, st.vz = 0, 0, 0
		return nil
	end
	local kv = 1 - math.exp(-dt / F.TauV)
	st.vy += (Flight.targetVy(ctl) - st.vy) * kv
	local wx, wz = Winds.at(winds, st.x, st.y, st.z)
	local ground = World.groundAt(world, st.x, st.z)
	if st.y <= ground + 0.05 and st.vy <= 0.01 then
		-- стоит на земле: ветер тащит слабо
		wx *= F.GroundGrip
		wz *= F.GroundGrip
	end
	local kh = 1 - math.exp(-dt / F.TauH)
	st.vx += (wx - st.vx) * kh
	st.vz += (wz - st.vz) * kh

	-- горизонталь: стена (обрыв, дом, маяк) выше корзины — упираемся
	local nx, nz = st.x + st.vx * dt, st.z + st.vz * dt
	local ng = World.groundAt(world, nx, nz)
	if ng > st.y + 0.5 then
		local gx = World.groundAt(world, nx, st.z)
		local gz = World.groundAt(world, st.x, nz)
		if gx <= st.y + 0.5 then
			st.x = nx
			st.vz = 0
		elseif gz <= st.y + 0.5 then
			st.z = nz
			st.vx = 0
		else
			st.vx, st.vz = 0, 0
		end
	else
		st.x, st.z = nx, nz
	end

	-- вертикаль: земля и потолок
	local g, kind = World.groundAt(world, st.x, st.z)
	local ny = st.y + st.vy * dt
	local event = nil
	local wasLanded = st.landed
	st.landed = false
	if ny <= g then
		ny = g
		if st.vy < 0 then
			st.vy = 0
		end
		st.landed = true
		if not wasLanded and kind ~= "water" then
			event = "landed"
		end
	end
	local ceiling = Config.Wind.Ceiling
	if ny >= ceiling then
		ny = ceiling
		if st.vy > 0 then
			st.vy = 0
		end
	end
	st.y = ny
	st.surface = if st.landed then kind else "air"
	if kind == "water" and st.y <= E.Water + F.SplashH then
		event = "splash"
	end
	return event
end

-- Курс (угол движения по горизонтали) и горизонтальная скорость
function Flight.heading(st: State): (number, number)
	return math.atan2(st.vz, st.vx), math.sqrt(st.vx * st.vx + st.vz * st.vz)
end

return Flight
