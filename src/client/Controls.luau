--[[
	Controls — управление своим шаром. Две команды: ВЫШЕ (W / Пробел / ↑ / кнопка A)
	и НИЖЕ (S / Ctrl / ↓ / кнопка B), на телефоне — две большие кнопки HUD.

	Отклик без задержки: каждый кадр клиент берёт позицию своей корзины, считает shared/Flight
	(та же физика, что в тестах) и пишет скорость в LinearVelocity «Lift». Сетевой владелец
	корзины — этот клиент, поэтому движение сразу видно и реплицируется остальным.
	Серверу уходит только смена команды (для пламени у других).
]]

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Flight = require(Shared.Flight)
local Net = require(Shared.Net)
local Winds = require(Shared.Winds)

local Sky = require(script.Parent.Sky)

local Controls = {}

local player = Players.LocalPlayer
local RH = Config.Flight.RootH

local keyUp, keyDown = false, false
local touchUp, touchDown = false, false
local ctl = 0
local fl: Flight.State? = nil
local lastLayer: number? = nil
local cameraSet: Instance? = nil

Controls.onCtl = nil :: ((number) -> ())?
Controls.onLayer = nil :: ((number, number) -> ())?
Controls.onCeiling = nil :: (() -> ())?

function Controls.balloon(): Model?
	local f = Workspace:FindFirstChild("Balloons")
	return f and f:FindFirstChild("Balloon_" .. player.UserId) :: Model?
end

function Controls.ctl(): number
	return ctl
end

function Controls.state(): Flight.State?
	return fl
end

function Controls.layer(): number?
	return lastLayer
end

local function refresh()
	local up = keyUp or touchUp
	local down = keyDown or touchDown
	local c = if up and not down then 1 elseif down and not up then -1 else 0
	if c ~= ctl then
		ctl = c
		Net.ClientAction:FireServer({ t = "ctl", v = c })
		if Controls.onCtl then
			Controls.onCtl(c)
		end
	end
end

-- Кнопки HUD (держать)
function Controls.setTouch(dir: number, on: boolean)
	if dir > 0 then
		touchUp = on
	else
		touchDown = on
	end
	refresh()
end

-- Сервер переставил шар: сбросить скорость модели
function Controls.teleported()
	if fl then
		fl.vx, fl.vy, fl.vz = 0, 0, 0
	end
end

local function noJump(character: Model)
	local hum = character:WaitForChild("Humanoid", 10) :: Humanoid?
	if hum then
		pcall(function()
			hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
		end)
	end
end

function Controls.build()
	local function bind(name: string, dir: number, keys: { Enum.KeyCode })
		local function handler(_, state: Enum.UserInputState)
			local on = state == Enum.UserInputState.Begin
			if state == Enum.UserInputState.Begin or state == Enum.UserInputState.End then
				if dir > 0 then
					keyUp = on
				else
					keyDown = on
				end
				refresh()
			elseif state == Enum.UserInputState.Cancel then
				keyUp, keyDown = false, false
				refresh()
			end
			return Enum.ContextActionResult.Sink
		end
		ContextActionService:BindActionAtPriority(name, handler, false, 3000, table.unpack(keys))
	end
	bind("WindsUp", 1, { Enum.KeyCode.W, Enum.KeyCode.Space, Enum.KeyCode.Up, Enum.KeyCode.ButtonA })
	bind("WindsDown", -1, {
		Enum.KeyCode.S,
		Enum.KeyCode.Down,
		Enum.KeyCode.LeftControl,
		Enum.KeyCode.C,
		Enum.KeyCode.ButtonB,
	})
	-- ходить не нужно: стик и прыжок на телефоне прячем
	pcall(function()
		GuiService.TouchControlsEnabled = false
	end)
	player.CharacterAdded:Connect(noJump)
	if player.Character then
		task.spawn(noJump, player.Character)
	end
	-- камера сначала отъезжает, чтобы был виден весь шар
	pcall(function()
		player.CameraMinZoomDistance = 55
		task.delay(0.6, function()
			player.CameraMinZoomDistance = 22
		end)
	end)
end

function Controls.update(dt: number)
	local model = Controls.balloon()
	local root = model and model.PrimaryPart
	local lift = root and root:FindFirstChild("Lift") :: LinearVelocity?
	local world, winds = Sky.world(), Sky.winds()
	if not model or not root or not lift or not world or not winds then
		fl = nil
		return
	end
	-- камера следит за корзиной
	local cam = Workspace.CurrentCamera
	if cam and cameraSet ~= root then
		cameraSet = root
		pcall(function()
			cam.CameraSubject = root
		end)
	end
	local p = root.CFrame.Position
	if not fl then
		fl = Flight.new(p.X, p.Y - RH, p.Z)
	end
	local st = fl :: Flight.State
	st.x, st.y, st.z = p.X, p.Y - RH, p.Z
	local frozen = root.Anchored or model:GetAttribute("Frozen") ~= nil
	local wasCeiling = st.y >= Config.Wind.Ceiling - 0.5
	Flight.step(st, if frozen then 0 else ctl, dt, winds, world, frozen)
	lift.VectorVelocity = Vector3.new(st.vx, st.vy, st.vz)
	local k = Winds.layerAt(winds, st.y)
	if lastLayer ~= nil and k ~= lastLayer and Controls.onLayer then
		Controls.onLayer(lastLayer, k)
	end
	lastLayer = k
	if not wasCeiling and st.y >= Config.Wind.Ceiling - 0.5 and ctl > 0 and Controls.onCeiling then
		Controls.onCeiling()
	end
end

return Controls
