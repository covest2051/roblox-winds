--[[
	Sim — минимальная «заглушка движка» для запуска СОБРАННОГО place-файла в Lune.
	Инстансы — настоящие (@lune/roblox проверяет имена и типы свойств),
	а сигналы, Raycast, Terrain:WriteVoxels, персонажи и т.п. — эмулируются.
	Цель — поймать runtime-ошибки серверного кода до Studio.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local task = require("@lune/task")

local Sim = {}

-------------------------------------------------------------------------------
-- Сигналы
-------------------------------------------------------------------------------
local Signal = {}
Signal.__index = Signal
function Signal.new()
	return setmetatable({ handlers = {} }, Signal)
end
function Signal:Connect(fn)
	local h = { fn = fn, connected = true }
	table.insert(self.handlers, h)
	return {
		Disconnect = function()
			h.connected = false
		end,
	}
end
function Signal:Once(fn)
	local conn
	conn = self:Connect(function(...)
		conn.Disconnect()
		fn(...)
	end)
	return conn
end
function Signal:Fire(...)
	for _, h in table.clone(self.handlers) do
		if h.connected then
			task.spawn(h.fn, ...)
		end
	end
end
function Signal:Wait()
	local thread = coroutine.running()
	self:Once(function(...)
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end
Sim.Signal = Signal

local signals = {} -- сильные ключи: иначе GC теряет подписки, пока игровой код не держит ссылку
local function signalOf(inst, name)
	signals[inst] = signals[inst] or {}
	local s = signals[inst][name]
	if not s then
		s = Signal.new()
		signals[inst][name] = s
	end
	return s
end
Sim.signalOf = signalOf

local function implementEvent(className, name)
	roblox.implementProperty(className, name, function(self)
		return signalOf(self, name)
	end)
end

for _, e in
	{
		{ "Players", "PlayerAdded" },
		{ "Players", "PlayerRemoving" },
		{ "Player", "CharacterAdded" },
		{ "ProximityPromptService", "PromptTriggered" },
		{ "RemoteEvent", "OnServerEvent" },
		{ "RemoteEvent", "OnClientEvent" },
		{ "BasePart", "Touched" },
		{ "RunService", "Heartbeat" },
		{ "RunService", "RenderStepped" },
		{ "ProximityPrompt", "Triggered" },
		{ "Humanoid", "Died" },
		{ "MarketplaceService", "PromptGamePassPurchaseFinished" },
		{ "MarketplaceService", "PromptProductPurchaseFinished" },
	}
do
	implementEvent(e[1], e[2])
end

roblox.implementMethod("Instance", "WaitForChild", function(self, name, timeout)
	local t0 = os.clock()
	while true do
		local c = self:FindFirstChild(name)
		if c then
			return c
		end
		if os.clock() - t0 > (timeout or 5) then
			if timeout then
				return nil
			end
			error("WaitForChild timed out: " .. self:GetFullName() .. "." .. name)
		end
		task.wait(0.05)
	end
end)
roblox.implementMethod("Instance", "GetAttributeChangedSignal", function(self, name)
	return signalOf(self, "Attr:" .. name)
end)
roblox.implementMethod("Instance", "GetPropertyChangedSignal", function(self, name)
	return signalOf(self, "Prop:" .. name)
end)

-------------------------------------------------------------------------------
-- Время, физика-заглушки
-------------------------------------------------------------------------------
Sim.timeOffset = 0
Sim.virtualTime = nil :: number? -- если задано, сервер видит это время (тест сам его двигает)
roblox.implementMethod("Workspace", "GetServerTimeNow", function()
	return Sim.virtualTime or (os.clock() + Sim.timeOffset)
end)

-- Position/AssemblyLinearVelocity нельзя переопределить через implementProperty:
-- игровой код читает CFrame.Position, а скорость задаём явно при создании персонажа.
roblox.implementMethod("PVInstance", "PivotTo", function(self, cf)
	if self:IsA("BasePart") then
		self.CFrame = cf
		return
	end
	local root = self.PrimaryPart or self:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	-- как в движке: модель двигается целиком
	local delta = cf * root.CFrame:Inverse()
	for _, d in self:GetDescendants() do
		if d:IsA("BasePart") then
			d.CFrame = delta * d.CFrame
		end
	end
end)

-------------------------------------------------------------------------------
-- Terrain: проверяем аргументы WriteVoxels как настоящий движок
-------------------------------------------------------------------------------
Sim.terrain = { writes = 0, voxels = 0, balls = {}, errors = {} }
roblox.implementMethod("Terrain", "Clear", function() end)
roblox.implementMethod("Terrain", "SetMaterialColor", function() end)
roblox.implementMethod("Terrain", "FillBall", function(_, center, radius, material)
	table.insert(Sim.terrain.balls, { c = center, r = radius, m = material })
end)
roblox.implementMethod("Terrain", "WriteVoxels", function(_, region, res, mats, occ)
	local T = Sim.terrain
	local function err(msg)
		table.insert(T.errors, msg)
	end
	if res ~= 4 then
		err("resolution must be 4")
	end
	local size = region.Size
	local min = region.CFrame.Position - size / 2
	for _, c in { min.X, min.Y, min.Z, size.X, size.Y, size.Z } do
		if math.abs(c / 4 - math.round(c / 4)) > 1e-6 then
			err("region not aligned to voxel grid: " .. tostring(min) .. " " .. tostring(size))
			break
		end
	end
	local nx, ny, nz = math.round(size.X / 4), math.round(size.Y / 4), math.round(size.Z / 4)
	if nx * ny * nz > 4194304 then
		err("region too large")
	end
	if #mats ~= nx or #occ ~= nx then
		err(string.format("x dim %d/%d vs %d", #mats, #occ, nx))
		return
	end
	for i = 1, nx do
		if #mats[i] ~= ny or #occ[i] ~= ny then
			err(string.format("y dim %d vs %d", #mats[i], ny))
			return
		end
		for j = 1, ny do
			if #mats[i][j] ~= nz or #occ[i][j] ~= nz then
				err("z dim mismatch")
				return
			end
			for k = 1, nz do
				local o = occ[i][j][k]
				if type(o) ~= "number" or o < 0 or o > 1 then
					err("bad occupancy " .. tostring(o))
					return
				end
				if typeof(mats[i][j][k]) ~= "EnumItem" then
					err("bad material")
					return
				end
			end
		end
	end
	T.writes += 1
	T.voxels += nx * ny * nz
end)

-------------------------------------------------------------------------------
-- Raycast: по рельефу (heightmap) и шарам FillBall; детали не учитываются
-------------------------------------------------------------------------------
Sim.heightAt = nil :: ((number, number) -> number)?
roblox.implementMethod("WorldRoot", "Raycast", function(_, origin, dir, _params)
	local len = dir.Magnitude
	local steps = math.max(4, math.ceil(len / 1.5))
	for i = 1, steps do
		local p = origin + dir * (i / steps)
		if Sim.heightAt and p.Y < Sim.heightAt(p.X, p.Z) then
			return { Position = p, Instance = nil, Material = roblox.Enum.Material.Snow }
		end
		for _, b in Sim.terrain.balls do
			if (p - b.c).Magnitude < b.r then
				return { Position = p, Instance = nil, Material = b.m }
			end
		end
	end
	return nil
end)

-------------------------------------------------------------------------------
-- Сервисы
-------------------------------------------------------------------------------
Sim.sent = {} -- { player, payload }
roblox.implementMethod("RemoteEvent", "FireClient", function(self, player, payload)
	table.insert(Sim.sent, { player = player, payload = payload })
	if Sim.clientMode and player == Sim.localPlayer then
		signalOf(self, "OnClientEvent"):Fire(payload)
	end
end)
roblox.implementMethod("RemoteEvent", "FireAllClients", function(self, payload)
	table.insert(Sim.sent, { player = "all", payload = payload })
	if Sim.clientMode then
		signalOf(self, "OnClientEvent"):Fire(payload)
	end
end)
roblox.implementMethod("Sound", "Play", function() end)
roblox.implementMethod("Sound", "Stop", function() end)
roblox.implementMethod("RunService", "IsStudio", function()
	return true
end)
roblox.implementMethod("RunService", "IsServer", function()
	return true
end)
roblox.implementMethod("Players", "GetPlayers", function(self)
	local out = {}
	for _, c in self:GetChildren() do
		if c.ClassName == "Player" then
			table.insert(out, c)
		end
	end
	return out
end)
roblox.implementMethod("Players", "GetPlayerFromCharacter", function(self, ch)
	for _, p in self:GetChildren() do
		if p.ClassName == "Player" and p.Character == ch then
			return p
		end
	end
	return nil
end)
roblox.implementMethod("Player", "RequestStreamAroundAsync", function() end)
roblox.implementMethod("Player", "LoadCharacter", function(self)
	local ch = roblox.Instance.new("Model")
	ch.Name = self.Name
	local root = roblox.Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = roblox.Vector3.new(2, 2, 1)
	root.CFrame = roblox.CFrame.new(0, 405, 0)
	root.AssemblyLinearVelocity = roblox.Vector3.zero
	root.Parent = ch
	local head = roblox.Instance.new("Part")
	head.Name = "Head"
	head.Parent = ch
	local torso = roblox.Instance.new("Part")
	torso.Name = "UpperTorso"
	torso.Size = roblox.Vector3.new(2, 1.6, 1)
	torso.Parent = ch
	local spawn = Sim.game:GetService("Workspace"):FindFirstChildWhichIsA("SpawnLocation", true)
	if spawn then
		root.CFrame = spawn.CFrame + roblox.Vector3.new(0, 4, 0)
	end
	local hum = roblox.Instance.new("Humanoid")
	hum.Health = 100
	hum.Parent = ch
	ch.PrimaryPart = root
	ch.Parent = Sim.game:GetService("Workspace")
	self.Character = ch
	signalOf(self, "CharacterAdded"):Fire(ch)
end)
roblox.implementMethod("CollectionService", "GetTagged", function(_, tag)
	local out = {}
	for _, d in Sim.game:GetDescendants() do
		if d:HasTag(tag) then
			table.insert(out, d)
		end
	end
	return out
end)
roblox.implementMethod("CollectionService", "GetInstanceAddedSignal", function(self, tag)
	return signalOf(self, "Added:" .. tag)
end)
roblox.implementMethod("PathfindingService", "CreatePath", function()
	return {
		Status = roblox.Enum.PathStatus.Success,
		ComputeAsync = function() end,
	}
end)

-------------------------------------------------------------------------------
-- Terrain (FillBlock/ReadVoxels), физика, сервисы магазина и данных
-------------------------------------------------------------------------------
Sim.fills = { count = 0, materials = {} }
roblox.implementMethod("Terrain", "FillBlock", function(_, cf, size, material)
	assert(
		typeof(cf) == "CFrame" and typeof(size) == "Vector3" and typeof(material) == "EnumItem",
		"FillBlock args"
	)
	assert(size.X > 0 and size.Y > 0 and size.Z > 0, "FillBlock size must be positive")
	Sim.fills.count += 1
	Sim.fills.materials[material.Name] = (Sim.fills.materials[material.Name] or 0) + 1
end)
roblox.implementMethod("Terrain", "ReadVoxels", function(_, region, res)
	assert(res == 4)
	return { { { roblox.Enum.Material.Water } } }, { { { 1 } } }
end)

local groups = { Default = true }
local collidable = {}
roblox.implementMethod("PhysicsService", "RegisterCollisionGroup", function(_, name)
	groups[name] = true
end)
roblox.implementMethod("PhysicsService", "IsCollisionGroupRegistered", function(_, name)
	return groups[name] == true
end)
roblox.implementMethod("PhysicsService", "CollisionGroupSetCollidable", function(_, a, b, v)
	assert(groups[a] and groups[b], "collision group not registered: " .. a .. "/" .. b)
	collidable[a .. "|" .. b] = v
end)
Sim.collidable = collidable
local owners = setmetatable({}, { __mode = "k" })
roblox.implementMethod("BasePart", "SetNetworkOwner", function(self, p)
	owners[self] = p or false
end)
roblox.implementMethod("BasePart", "GetNetworkOwner", function(self)
	return owners[self] or nil
end)
roblox.implementMethod("PVInstance", "GetPivot", function(self)
	local root = self:FindFirstChild("HumanoidRootPart") or self.PrimaryPart
	return root and root.CFrame or roblox.CFrame.new()
end)

-- DataStore в памяти; Sim.dataFail = true — все вызовы падают
Sim.dataStores = {}
Sim.dataFail = false
Sim.dataCalls = 0
roblox.implementMethod("DataStoreService", "GetDataStore", function(_, name)
	Sim.dataStores[name] = Sim.dataStores[name] or {}
	local mem = Sim.dataStores[name]
	return {
		GetAsync = function(_, key)
			Sim.dataCalls += 1
			if Sim.dataFail then
				error("DataStore unavailable (sim)")
			end
			return mem[key]
		end,
		UpdateAsync = function(_, key, fn)
			Sim.dataCalls += 1
			if Sim.dataFail then
				error("DataStore unavailable (sim)")
			end
			mem[key] = fn(mem[key])
			return mem[key]
		end,
	}
end)

-- Магазин
Sim.prompts = {}
Sim.ownedPasses = {}
Sim.policyRestricted = false
Sim.policyFail = false
roblox.implementProperty("MarketplaceService", "ProcessReceipt", function()
	return Sim.processReceipt
end, function(_, fn)
	Sim.processReceipt = fn
end)
roblox.implementMethod("MarketplaceService", "PromptProductPurchase", function(_, player, id)
	table.insert(Sim.prompts, { kind = "product", player = player, id = id })
end)
roblox.implementMethod("MarketplaceService", "PromptGamePassPurchase", function(_, player, id)
	table.insert(Sim.prompts, { kind = "pass", player = player, id = id })
end)
roblox.implementMethod("MarketplaceService", "UserOwnsGamePassAsync", function(_, userId, id)
	return Sim.ownedPasses[userId .. ":" .. id] == true
end)
roblox.implementMethod("PolicyService", "GetPolicyInfoForPlayerAsync", function()
	if Sim.policyFail then
		error("policy unavailable (sim)")
	end
	return { ArePaidRandomItemsRestricted = Sim.policyRestricted, IsSubjectToChinaPolicies = false }
end)
local guid = 0
roblox.implementMethod("HttpService", "GenerateGUID", function()
	guid += 1
	return string.format("guid-%06d", guid)
end)
roblox.implementMethod("DataModel", "BindToClose", function(_, fn)
	Sim.onClose = fn
end)
roblox.implementMethod("Players", "GetPlayerByUserId", function(self, id)
	for _, p in self:GetChildren() do
		if p.ClassName == "Player" and p.UserId == id then
			return p
		end
	end
	return nil
end)
roblox.implementMethod("SocialService", "PromptGameInvite", function(_, player)
	Sim.invites = (Sim.invites or 0) + 1
end)

-- Сиденье: Sit сажает (в движке Occupant только для чтения, в Lune можно записать)
Sim.seated = {}
roblox.implementMethod("Seat", "Sit", function(self, hum)
	Sim.seated[self] = hum
	self.Occupant = hum
	if hum then
		hum.Sit = true
	end
	signalOf(self, "Prop:Occupant"):Fire()
end)

-- Физики нет: игровой код двигает якорные детали сам, персонажей и шары двигают тесты.
-- Sim.stepPhysics(dt) — интегрирует LinearVelocity незакреплённых корзин (клиентский тест).
function Sim.stepPhysics(dt)
	for _, d in Sim.game:GetService("Workspace"):GetDescendants() do
		if d.ClassName == "LinearVelocity" and d.Parent and d.Parent:IsA("BasePart") then
			local root = d.Parent
			if not root.Anchored then
				root.CFrame = root.CFrame + d.VectorVelocity * dt
			end
		end
	end
end

-------------------------------------------------------------------------------
-- Клиентские заглушки (сервер и клиент в одном DataModel)
-------------------------------------------------------------------------------
Sim.clientMode = false
Sim.localPlayer = nil
for _, e in
	{
		{ "UserInputService", "InputBegan" },
		{ "UserInputService", "InputEnded" },
		{ "TextButton", "Activated" },
		{ "Sound", "Ended" },
		{ "Instance", "DescendantAdded" },
		{ "Instance", "DescendantRemoving" },
		{ "Instance", "ChildAdded" },
		{ "Instance", "ChildRemoved" },
	}
do
	implementEvent(e[1], e[2])
end
roblox.implementMethod("RemoteEvent", "FireServer", function(self, payload)
	signalOf(self, "OnServerEvent"):Fire(Sim.localPlayer, payload)
end)
Sim.tweens = 0
roblox.implementMethod("TweenService", "Create", function(_, inst, _info, goal)
	Sim.tweens += 1
	return {
		Play = function()
			-- мгновенно применяем цель: проверяет имена и типы свойств
			for k, v in goal do
				inst[k] = v
			end
		end,
		Cancel = function() end,
	}
end)
roblox.implementMethod("RunService", "BindToRenderStep", function(_, name, _prio, fn)
	Sim.renderSteps = Sim.renderSteps or {}
	Sim.renderSteps[name] = fn
end)
roblox.implementMethod("RunService", "UnbindFromRenderStep", function(_, name)
	if Sim.renderSteps then
		Sim.renderSteps[name] = nil
	end
end)
roblox.implementMethod("ContextActionService", "BindAction", function(_, name, fn)
	Sim.actions = Sim.actions or {}
	Sim.actions[name] = fn
end)
roblox.implementMethod("ContextActionService", "SetTitle", function() end)
roblox.implementMethod("ContextActionService", "SetPosition", function() end)
roblox.implementMethod("StarterGui", "SetCoreGuiEnabled", function() end)
roblox.implementMethod("StarterGui", "SetCore", function() end)

local TweenInfoMock = {
	new = function(...)
		return { ... }
	end,
}
Sim.TweenInfo = TweenInfoMock

-------------------------------------------------------------------------------
-- Загрузка place и запуск скриптов
-------------------------------------------------------------------------------
local RaycastParamsMock = {
	new = function()
		return { FilterType = nil, FilterDescendantsInstances = {}, IgnoreWater = false }
	end,
}

local RandomMock = {
	new = function()
		return {
			NextInteger = function(_, a, b)
				return math.random(a, b)
			end,
			NextNumber = function(_, a, b)
				return (a or 0) + math.random() * ((b or 1) - (a or 0))
			end,
		}
	end,
}

local cache = {}
local function makeEnv(script)
	return {
		script = script,
		game = Sim.game,
		workspace = Sim.game:GetService("Workspace"),
		require = Sim.require,
		Instance = roblox.Instance,
		Vector3 = roblox.Vector3,
		Vector2 = roblox.Vector2,
		CFrame = roblox.CFrame,
		Color3 = roblox.Color3,
		UDim = roblox.UDim,
		UDim2 = roblox.UDim2,
		Region3 = roblox.Region3,
		NumberSequence = roblox.NumberSequence,
		NumberSequenceKeypoint = roblox.NumberSequenceKeypoint,
		ColorSequence = roblox.ColorSequence,
		ColorSequenceKeypoint = roblox.ColorSequenceKeypoint,
		NumberRange = roblox.NumberRange,
		Vector3int16 = roblox.Vector3int16,
		Enum = roblox.Enum,
		RaycastParams = RaycastParamsMock,
		TweenInfo = TweenInfoMock,
		Random = RandomMock,
		task = task,
		warn = function(...)
			Sim.warnings = Sim.warnings or {}
			local parts = {}
			for _, v in { ... } do
				table.insert(parts, tostring(v))
			end
			table.insert(Sim.warnings, table.concat(parts, " "))
			print("WARN", ...)
		end,
	}
end

function Sim.require(module)
	if cache[module] ~= nil then
		return cache[module]
	end
	assert(module.ClassName == "ModuleScript", "require of non-module " .. tostring(module))
	local fn = luau.load(module.Source, { debugName = module:GetFullName(), environment = makeEnv(module) })
	local result = fn()
	cache[module] = result
	return result
end

function Sim.runScript(scriptInst)
	local fn = luau.load(
		scriptInst.Source,
		{ debugName = scriptInst:GetFullName(), environment = makeEnv(scriptInst) }
	)
	return task.spawn(fn)
end

function Sim.loadPlace(path)
	Sim.game = roblox.deserializePlace(fs.readFile(path))
	local ws = Sim.game:GetService("Workspace")
	if not ws:FindFirstChild("Terrain") then
		local t = roblox.Instance.new("Terrain")
		t.Name = "Terrain"
		t.Parent = ws
	end
	return Sim.game
end

local nextUserId = 1000
function Sim.addPlayer(name)
	local p = roblox.Instance.new("Player")
	p.Name = name
	nextUserId += 1
	p.UserId = nextUserId
	p.DisplayName = name
	p.Parent = Sim.game:GetService("Players")
	return p
end

return Sim
