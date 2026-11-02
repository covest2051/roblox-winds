--[[
	Lang — текущий язык клиента и подписка на его смену.
]]

local LocalizationService = game:GetService("LocalizationService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Strings = require(Shared.Strings)

local Lang = {}

local ok, locale = pcall(function()
	return LocalizationService.RobloxLocaleId
end)
Lang.current = Strings.langFromLocale(if ok then locale else nil)

local listeners = {}

function Lang.t(key: string, vars: { [string]: any }?): string
	return Strings.get(Lang.current, key, vars)
end

function Lang.set(lang: string)
	Lang.current = lang
	for _, fn in listeners do
		task.spawn(fn)
	end
end

function Lang.toggle()
	Lang.set(if Lang.current == "ru" then "en" else "ru")
end

function Lang.onChange(fn: () -> ())
	table.insert(listeners, fn)
end

Lang.formatTime = Strings.formatTime

return Lang
