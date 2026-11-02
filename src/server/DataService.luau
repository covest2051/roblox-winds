--[[
	DataService — профили игроков в DataStore.
	  • загрузка с повторами; если DataStore недоступен (Studio без доступа к API,
	    сбой Roblox), игрок играет на временном профиле, и он НЕ перезаписывает настоящий;
	  • автосохранение, сохранение при выходе и в BindToClose;
	  • leaderstats: Coins и Wins.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Profile = require(Shared.Profile)

local DataService = {}

type Entry = { data: Profile.Data, canSave: boolean, dirty: boolean, loaded: boolean, saving: boolean }

local entries: { [Player]: Entry } = {}
local loading: { [Player]: boolean } = {}
local listeners: { (Player) -> () } = {}

local store: DataStore? = nil
do
	local ok, s = pcall(function()
		return DataStoreService:GetDataStore(Config.DataStore.Name)
	end)
	if ok then
		store = s
	else
		warn("[Data] DataStore unavailable:", s)
	end
end

local function key(player: Player): string
	return "u_" .. player.UserId
end

local function retry<T>(fn: () -> T): (boolean, T | string)
	local lastErr
	for attempt = 1, Config.DataStore.Retries do
		local ok, res = pcall(fn)
		if ok then
			return true, res
		end
		lastErr = res
		if attempt < Config.DataStore.Retries then
			task.wait(attempt)
		end
	end
	return false, tostring(lastErr)
end

local function updateStats(player: Player)
	local e = entries[player]
	local ls = player:FindFirstChild("leaderstats")
	if not e or not ls then
		return
	end
	local coins = ls:FindFirstChild("Coins") :: IntValue?
	local wins = ls:FindFirstChild("Wins") :: IntValue?
	if coins then
		coins.Value = e.data.coins
	end
	if wins then
		wins.Value = e.data.wins
	end
end

local function makeStats(player: Player)
	local ls = Instance.new("Folder")
	ls.Name = "leaderstats"
	local coins = Instance.new("IntValue")
	coins.Name = "Coins"
	coins.Parent = ls
	local wins = Instance.new("IntValue")
	wins.Name = "Wins"
	wins.Parent = ls
	ls.Parent = player
end

function DataService.load(player: Player)
	if entries[player] or loading[player] then
		return
	end
	loading[player] = true
	makeStats(player)
	local data, canSave = nil, false
	if store then
		local ok, raw = retry(function()
			return (store :: DataStore):GetAsync(key(player))
		end)
		if ok then
			data, canSave = Profile.migrate(raw), true
		else
			warn("[Data] load failed for", player.Name, raw)
		end
	end
	loading[player] = nil
	if not player.Parent then
		return
	end
	entries[player] =
		{ data = data or Profile.new(), canSave = canSave, dirty = false, loaded = true, saving = false }
	player:SetAttribute("DataSaved", canSave)
	updateStats(player)
	for _, fn in listeners do
		task.spawn(fn, player)
	end
end

-- Профиль (ждёт загрузку до timeout секунд). nil — игрок ушёл или не загрузился.
function DataService.get(player: Player, timeout: number?): Profile.Data?
	local t0 = os.clock()
	while not entries[player] and player.Parent and os.clock() - t0 < (timeout or 0) do
		task.wait(0.1)
	end
	local e = entries[player]
	return e and e.data
end

function DataService.isLoaded(player: Player): boolean
	return entries[player] ~= nil
end

function DataService.changed(player: Player)
	local e = entries[player]
	if e then
		e.dirty = true
		updateStats(player)
	end
end

-- Сохранить сейчас. true — данные в DataStore (или сохранять нечего).
function DataService.save(player: Player): boolean
	local e = entries[player]
	if not e then
		return false
	end
	if not e.canSave or not store then
		return false
	end
	while e.saving do
		task.wait(0.1)
	end
	e.saving = true
	local snapshot = e.data
	local ok, err = retry(function()
		return (store :: DataStore):UpdateAsync(key(player), function()
			return snapshot
		end)
	end)
	e.saving = false
	if ok then
		e.dirty = false
	else
		warn("[Data] save failed for", player.Name, err)
	end
	return ok
end

-- Для ProcessReceipt: в Studio без DataStore покупка всё равно засчитывается
function DataService.commit(player: Player): boolean
	local e = entries[player]
	if not e then
		return false
	end
	if not e.canSave then
		return game:GetService("RunService"):IsStudio()
	end
	return DataService.save(player)
end

function DataService.onLoaded(fn: (Player) -> ())
	table.insert(listeners, fn)
	for p in entries do
		task.spawn(fn, p)
	end
end

function DataService.start()
	Players.PlayerAdded:Connect(DataService.load)
	for _, p in Players:GetPlayers() do
		task.spawn(DataService.load, p)
	end
	Players.PlayerRemoving:Connect(function(player)
		if entries[player] then
			DataService.save(player)
		end
		entries[player] = nil
	end)
	task.spawn(function()
		while true do
			task.wait(Config.DataStore.AutosaveEvery)
			for p, e in entries do
				if e.dirty then
					task.spawn(DataService.save, p)
				end
			end
		end
	end)
	pcall(function()
		game:BindToClose(function()
			local pending = 0
			for p in entries do
				pending += 1
				task.spawn(function()
					DataService.save(p)
					pending -= 1
				end)
			end
			local t0 = os.clock()
			while pending > 0 and os.clock() - t0 < 25 do
				task.wait(0.1)
			end
		end)
	end)
end

return DataService
