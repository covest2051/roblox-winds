--[[
	SelfTest — проверки внутри движка (запускается в Studio при старте и кнопкой DBG).
	Пишет в Output строки [SELFTEST] PASS/WARN/FAIL и итог RESULT.
]]

local Players = game:GetService("Players")
local PolicyService = game:GetService("PolicyService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local World = require(Shared.World)

local FlightService = require(script.Parent.FlightService)

local SelfTest = {}

function SelfTest.run(): { string }
	local lines = {}
	local pass, warns, total = 0, 0, 0
	local function check(name: string, fn: () -> (boolean | string, string?))
		total += 1
		local ok, res, detail = pcall(fn)
		local line
		if not ok then
			line = "[SELFTEST] FAIL " .. name .. ": " .. tostring(res)
		elseif res == true then
			pass += 1
			line = "[SELFTEST] PASS " .. name .. (if detail then " (" .. detail .. ")" else "")
		elseif res == "warn" then
			pass += 1
			warns += 1
			line = "[SELFTEST] WARN " .. name .. (if detail then ": " .. detail else "")
		else
			line = "[SELFTEST] FAIL " .. name .. (if detail then ": " .. detail else "")
		end
		print(line)
		table.insert(lines, line)
	end

	local w = FlightService.world

	check("archipelago built", function()
		local f = Workspace:FindFirstChild("Archipelago")
		if not f or not w then
			return false, "no Archipelago"
		end
		local islands, houses = 0, 0
		for _, c in f:GetChildren() do
			if c.Name:sub(1, 7) == "Island_" then
				islands += 1
				for _, h in c:GetChildren() do
					if h.Name:sub(1, 6) == "House_" then
						houses += 1
					end
				end
			end
		end
		return islands == #w.islands and houses == #w.houses,
			string.format("%d islands, %d houses, %d instances", islands, houses, #f:GetDescendants())
	end)

	check("roofs in the world match the flight model", function()
		local f = Workspace:FindFirstChild("Archipelago") :: Instance
		local worst = 0
		for _, h in w.houses do
			local m = f:FindFirstChild("House_" .. h.id, true)
			local roof = m and m:FindFirstChild("Roof") :: BasePart?
			if not roof then
				return false, "no roof " .. h.id
			end
			local top = roof.CFrame.Position.Y + roof.Size.Y / 2
			worst = math.max(worst, math.abs(top - World.groundAt(w, h.x, h.z)))
		end
		return worst < 0.05, string.format("max error %.3f", worst)
	end)

	check("winds published", function()
		local seed = Workspace:GetAttribute("WindSeed")
		local mast = Workspace:FindFirstChild("WindMast")
		return type(seed) == "number" and mast ~= nil and FlightService.winds ~= nil,
			"seed " .. tostring(seed)
	end)

	check("streaming off, characters spawn after the world", function()
		return Workspace.StreamingEnabled == false and Players.CharacterAutoLoads == false
	end)

	check("players fly: balloon, seat, lift constraint", function()
		local n, ok = 0, 0
		for _, p in Players:GetPlayers() do
			n += 1
			local m = FlightService.balloonOf(p)
			local root = m and m.PrimaryPart
			local lift = root and root:FindFirstChild("Lift")
			local seat = m and m:FindFirstChild("Seat") :: Seat?
			local hum = p.Character and p.Character:FindFirstChildOfClass("Humanoid")
			if lift and seat and hum and seat.Occupant == hum then
				ok += 1
			end
		end
		if n == 0 then
			return "warn", "no players"
		end
		return ok == n, ok .. "/" .. n .. " seated with a Lift"
	end)

	check("products configured", function()
		local missing = {}
		for _, k in Config.ProductOrder do
			if Config.Products[k].id == 0 then
				table.insert(missing, k)
			end
		end
		for k, p in Config.Passes do
			if p.id == 0 then
				table.insert(missing, k)
			end
		end
		if #missing > 0 then
			return "warn", "ID = 0 (emulated in Studio): " .. table.concat(missing, ", ")
		end
		return true
	end)

	check("player data saves", function()
		local p = Players:GetPlayers()[1]
		if not p then
			return "warn", "no players"
		end
		if p:GetAttribute("DataSaved") ~= true then
			return "warn",
				"DataStore off: Game Settings → Security → Enable Studio Access to API Services"
		end
		return true
	end)

	check("PolicyService answers", function()
		local p = Players:GetPlayers()[1]
		if not p then
			return "warn", "no players"
		end
		local info = PolicyService:GetPolicyInfoForPlayerAsync(p)
		return true, "ArePaidRandomItemsRestricted=" .. tostring(info.ArePaidRandomItemsRestricted)
	end)

	local result = string.format("[SELFTEST] RESULT %d/%d passed, %d warnings", pass, total, warns)
	print(result)
	table.insert(lines, result)
	return lines
end

return SelfTest
