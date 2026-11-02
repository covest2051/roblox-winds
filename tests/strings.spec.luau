return function(t)
	local Strings = t.shared("Strings")
	local Catalog = t.shared("Catalog")

	t.test("ru and en have the same keys", function()
		for k in Strings.ru do
			t.ok(Strings.en[k] ~= nil, "en missing " .. k)
		end
		for k in Strings.en do
			t.ok(Strings.ru[k] ~= nil, "ru missing " .. k)
		end
	end)

	t.test("every item and rarity has a name", function()
		for _, it in Catalog.Items do
			t.ok(Strings.ru["item." .. it.id] ~= nil, "item." .. it.id)
			t.ok(Strings.ru["rarity." .. it.rarity] ~= nil, "rarity." .. it.rarity)
		end
	end)

	t.test("substitution, nested keys, locale", function()
		t.eq(Strings.get("ru", "race.next", { t = "0:42" }), "Гонка через 0:42")
		t.eq(Strings.get("en", "shop.bought", { item = "item.balloon_sky" }), "Bought: Sky")
		t.eq(Strings.get("en", "no.such.key"), "no.such.key")
		t.eq(Strings.langFromLocale("ru-ru"), "ru")
		t.eq(Strings.langFromLocale("en-us"), "en")
		t.eq(Strings.langFromLocale(nil), "en")
		t.eq(Strings.formatTime(154.3), "2:34")
		t.eq(Strings.formatTime(59.6), "1:00")
	end)

	t.test("every key used in code exists", function()
		local fs = (require :: any)("@lune/fs")
		local missing = {}
		local known = { ui = 1, shop = 1, sign = 1, race = 1, results = 1, debug = 1, order = 1 }
		local function scan(dir)
			for _, f in fs.readDir(dir) do
				local path = dir .. "/" .. f
				if fs.isDir(path) then
					scan(path)
				elseif string.find(f, "%.luau$") then
					local src = fs.readFile(path)
					for key in string.gmatch(src, '"(%l+%.%a[%w]*)"') do
						local prefix = string.match(key, "^(%l+)%.")
						if known[prefix] and not Strings.ru[key] then
							missing[key .. " in " .. f] = true
						end
					end
				end
			end
		end
		scan("src")
		for k in missing do
			t.ok(false, "missing string " .. k)
		end
	end)
end
