--[[
	Rng — детерминированный генератор, одинаковый в Roblox и в Lune
	(в Lune нет Roblox-класса Random). Нужен, чтобы острова и ветра
	генерировались одинаково на сервере, на клиенте и в тестах.
]]

local Rng = {}
Rng.__index = Rng

export type Rng = typeof(setmetatable({} :: { state: number }, Rng))

local MOD = 2147483647 -- 2^31 - 1
local MUL = 48271

function Rng.new(seed: number): Rng
	local s = math.floor(math.abs(seed)) % MOD
	if s == 0 then
		s = 1
	end
	return setmetatable({ state = s }, Rng)
end

-- [0, 1)
function Rng.next(self: Rng): number
	self.state = (self.state * MUL) % MOD
	return (self.state - 1) / (MOD - 1)
end

function Rng.range(self: Rng, a: number, b: number): number
	return a + (b - a) * self:next()
end

function Rng.int(self: Rng, a: number, b: number): number
	return math.min(b, a + math.floor((b - a + 1) * self:next()))
end

local TWO32 = 4294967296

-- Умножение по модулю 2^32 без потери точности double
local function mul32(a: number, b: number): number
	local lo = (a * (b % 65536)) % TWO32
	local hi = ((a * (b // 65536)) % 65536) * 65536
	return (lo + hi) % TWO32
end

-- Хэш точки сетки → [0,1). Без состояния: удобно для «есть ли дерево в клетке».
-- Нелинейное перемешивание битов (иначе на карте видны полосы).
function Rng.hash2(x: number, z: number, seed: number): number
	local h = bit32.bxor(
		mul32(x % TWO32, 0x27d4eb2d),
		mul32(z % TWO32, 0x165667b1),
		mul32(seed % TWO32, 0x9e3779b1)
	)
	h = bit32.bxor(h, bit32.rshift(h, 15))
	h = mul32(h, 0x85ebca6b)
	h = bit32.bxor(h, bit32.rshift(h, 13))
	h = mul32(h, 0xc2b2ae35)
	h = bit32.bxor(h, bit32.rshift(h, 16))
	return h / TWO32
end

return Rng
