--[[
	Fx — звуки, тряска камеры, перевод табличек (атрибут TextKey).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Make = require(Shared.Make)

local Lang = require(script.Parent.Lang)

local player = Players.LocalPlayer

local Fx = {}

local sounds: { [string]: Sound } = {}
local shakeUntil, shakePower = 0, 0

local function localizeOne(d: Instance)
	local key = d:GetAttribute("TextKey")
	if type(key) == "string" and d:IsA("TextLabel") then
		d.Text = Lang.t(key)
	end
end

-- Таблички на текущем языке
function Fx.localize()
	for _, d in Workspace:GetDescendants() do
		localizeOne(d)
	end
end

function Fx.play(name: string, volume: number?)
	local s = sounds[name]
	local cfg = Config.Sounds[name]
	if s and cfg then
		s.Volume = cfg.Volume * (volume or 1)
		s.TimePosition = 0
		s:Play()
	end
end

function Fx.stop(name: string)
	local s = sounds[name]
	if s then
		s:Stop()
	end
end

function Fx.shake(power: number)
	shakePower = math.max(shakePower, power)
	shakeUntil = os.clock() + 0.35
end

function Fx.build()
	for name, cfg in Config.Sounds do
		sounds[name] = Make("Sound", {
			Name = "Fx_" .. name,
			SoundId = cfg.Id,
			Volume = cfg.Volume,
			PlaybackSpeed = cfg.Speed or 1,
			Parent = SoundService,
		})
	end
	Fx.localize()
	Lang.onChange(Fx.localize)
	Workspace.DescendantAdded:Connect(localizeOne)
end

function Fx.update(_dt: number)
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if hum then
		if os.clock() < shakeUntil then
			local p = shakePower
			hum.CameraOffset = Vector3.new((math.random() - 0.5) * p, (math.random() - 0.5) * p, 0)
		elseif shakePower > 0 then
			shakePower = 0
			hum.CameraOffset = Vector3.zero
		end
	end
end

return Fx
