return function(t)
	local Profile = t.shared("Profile")
	local Config = t.shared("Config")
	local Rewards = t.shared("Rewards")

	t.test("new profile owns and wears the defaults", function()
		local d = Profile.new()
		t.ok(d.owned.balloon_classic and d.owned.ribbon_white and d.owned.trail_mist)
		t.eq(d.equipped.balloon, "balloon_classic")
		t.eq(d.equipped.ribbon, "ribbon_white")
		t.eq(d.equipped.trail, "trail_mist")
		t.eq(d.coins, 0)
	end)

	t.test("migrate: garbage, old fields, unknown items", function()
		t.eq(Profile.migrate(nil).coins, 0)
		t.eq(Profile.migrate("x").coins, 0)
		local d = Profile.migrate({
			coins = 12.7,
			wins = 4,
			deliveries = -3,
			owned = { balloon_sky = true, bogus = true },
			equipped = { balloon = "ribbon_red", ribbon = "ribbon_teal", trail = 5 },
			receipts = { "a", 5 },
		})
		t.eq(d.coins, 12)
		t.eq(d.wins, 4)
		t.eq(d.deliveries, 0)
		t.ok(d.owned.balloon_sky and not d.owned.bogus)
		t.eq(d.equipped.balloon, "balloon_classic", "wrong kind falls back")
		t.eq(d.equipped.ribbon, "ribbon_teal")
		t.eq(d.equipped.trail, "trail_mist")
		t.eq(#d.receipts, 1)
	end)

	t.test("duplicates refund coins", function()
		local d = Profile.new()
		t.ok(not Profile.grantItem(d, "balloon_sky").dup)
		local b = Profile.grantItem(d, "balloon_sky")
		t.ok(b.dup)
		t.eq(b.refund, Config.Rarity.Common.refund)
		t.eq(d.coins, Config.Rarity.Common.refund)
	end)

	t.test("buying with coins", function()
		local d = Profile.new()
		local ok, err = Profile.buyWithCoins(d, "balloon_sky")
		t.ok(not ok and err == "shop.noCoins")
		d.coins = 1000
		t.ok((Profile.buyWithCoins(d, "balloon_sky")))
		t.eq(d.coins, 1000 - Config.Rarity.Common.price)
		ok, err = Profile.buyWithCoins(d, "balloon_sky")
		t.ok(not ok and err == "shop.owned")
		ok, err = Profile.buyWithCoins(d, "balloon_gold")
		t.ok(not ok and err == "shop.notForSale")
		ok, err = Profile.buyWithCoins(d, "trail_mist")
		t.ok(not ok and err == "shop.notForSale", "defaults are not for sale")
	end)

	t.test("equip rules and VIP items", function()
		local d = Profile.new()
		t.ok(not Profile.equip(d, "balloon_sky", false), "not owned")
		t.ok(not Profile.equip(d, "balloon_gold", false), "VIP without pass")
		t.ok(Profile.equip(d, "balloon_gold", true), "VIP with pass")
		t.ok(Profile.equip(d, "trail_gold", true))
		t.eq(Profile.effective(d, "balloon", true), "balloon_gold")
		t.eq(Profile.effective(d, "balloon", false), "balloon_classic", "pass gone → default")
		t.eq(Profile.effective(d, "trail", false), "trail_mist")
		t.eq(Profile.effective(d, "ribbon", false), "ribbon_white")
	end)

	t.test("direct purchase picks the wanted item or any missing one", function()
		local d = Profile.new()
		t.eq(Profile.pickDirect(d, "Epic", "balloon_neon"), "balloon_neon")
		t.ok(Profile.pickDirect(d, "Epic", "balloon_sky") ~= "balloon_sky", "wrong rarity ignored")
		d.owned.balloon_neon = true
		t.ok(Profile.pickDirect(d, "Epic", "balloon_neon") ~= "balloon_neon", "owned → another one")
		d.owned.balloon_rainbow = true
		d.owned.trail_rainbow = true
		t.eq(Profile.pickDirect(d, "Legendary", nil), nil, "all owned")
	end)

	t.test("receipt log is bounded and idempotent", function()
		local d = Profile.new()
		for i = 1, Config.DataStore.ReceiptLog + 20 do
			Profile.addReceipt(d, "p" .. i)
		end
		t.eq(#d.receipts, Config.DataStore.ReceiptLog)
		t.ok(not Profile.hasReceipt(d, "p1"))
		t.ok(Profile.hasReceipt(d, "p" .. (Config.DataStore.ReceiptLog + 20)))
	end)

	t.test("race and delivery stats, earned coins", function()
		local d = Profile.new()
		Profile.recordRace(d, 1)
		Profile.recordRace(d, 3)
		Profile.recordRace(d, 4)
		Profile.recordRace(d, nil)
		t.eq(d.races, 4)
		t.eq(d.wins, 1)
		t.eq(d.podiums, 2)
		Profile.recordDelivery(d)
		t.eq(d.deliveries, 1)
		Profile.earn(d, 40)
		Profile.earn(d, -5)
		t.eq(d.coins, 40)
		t.eq(d.earned, 40)
	end)

	t.test("rewards: passes multiply, rounding down", function()
		t.eq(Rewards.multiplier(false, false), 1)
		t.near(Rewards.multiplier(true, false), 2, 1e-9)
		t.near(Rewards.multiplier(true, true), 2.2, 1e-9)
		t.near(Rewards.multiplier(false, true), 1.1, 1e-9)
		t.eq(Rewards.apply(35, 1.1), 38)
		t.eq(Rewards.apply(10, 1.1), 11, "no float error")
	end)
end
