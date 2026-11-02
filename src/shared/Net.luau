--[[
	Net — доступ к двум RemoteEvent проекта (созданы в default.project.json).
	ClientAction: клиент → сервер, payload { t = "up" | "race" | ... }
	ServerEvent:  сервер → клиент, payload { t = "toast" | "race" | ... }
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = {}

local remotes = ReplicatedStorage:WaitForChild("Remotes")
Net.ClientAction = remotes:WaitForChild("ClientAction") :: RemoteEvent
Net.ServerEvent = remotes:WaitForChild("ServerEvent") :: RemoteEvent

return Net
