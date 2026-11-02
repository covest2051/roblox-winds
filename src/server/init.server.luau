--[[
	Точка входа сервера: строим архипелаг, запускаем сервисы, затем спавним игроков.
	Логика сервера идёт фиксированным шагом Config.Timing.Step; ИИ-шары и посылки
	двигаются плавно каждый кадр.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local World = require(Shared.World)

local WorldBuilder = require(script.WorldBuilder)
local DataService = require(script.DataService)
local Monetization = require(script.Monetization)
local Cosmetics = require(script.Cosmetics)
local FlightService = require(script.FlightService)
local RaceService = require(script.RaceService)
local DeliveryService = require(script.DeliveryService)
local Actions = require(script.Actions)
local SelfTest = require(script.SelfTest)

-- данные и покупки — сразу: ProcessReceipt должен быть назначен как можно раньше
DataService.start()
Monetization.start()
Cosmetics.start()
Actions.selfTest = SelfTest.run
Actions.start()

local t0 = os.clock()
local seed = Workspace:GetAttribute("WorldSeed")
if type(seed) ~= "number" then
	seed = Random.new():NextInteger(1, 2 ^ 30)
end
local world = World.generate(seed)
Workspace:SetAttribute("WorldSeed", seed)
WorldBuilder.lighting()
WorldBuilder.build(world)
FlightService.world = world
RaceService.init(world)
RaceService.setWinds(Random.new():NextInteger(1, 2 ^ 30))
DeliveryService.init(world)
FlightService.onSpawned = DeliveryService.assign
FlightService.start()
Workspace:SetAttribute("WorldReady", true)
print(string.format("[World] seed %d built in %.2fs", seed, os.clock() - t0))

-- общий шаг логики
local acc = 0
RunService.Heartbeat:Connect(function(dt)
	acc += dt
	local step = Config.Timing.Step
	local n = 0
	while acc >= step and n < 5 do
		acc -= step
		n += 1
		FlightService.step(step)
		RaceService.step(step)
		DeliveryService.step(step)
	end
	if n == 5 then
		acc = 0
	end
	RaceService.heartbeat(dt)
	DeliveryService.heartbeat(dt)
end)

-- персонажи появляются только когда мир готов (CharacterAutoLoads = false)
local function spawnLoop(player: Player)
	player.CharacterAdded:Connect(function(character)
		local hum = character:WaitForChild("Humanoid", 10) :: Humanoid?
		if hum then
			hum.Died:Connect(function()
				task.wait(2)
				if player.Parent then
					player:LoadCharacter()
				end
			end)
		end
	end)
	player:LoadCharacter()
end
Players.PlayerAdded:Connect(spawnLoop)
for _, p in Players:GetPlayers() do
	task.spawn(spawnLoop, p)
end

if RunService:IsStudio() then
	task.delay(5, SelfTest.run)
end
