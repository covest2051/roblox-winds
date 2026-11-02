--[[
	Config — все числа баланса и ID товаров в одном месте.
	После правки: `lune run tests/run.luau` (тест отклика скажет, если управление стало «ватным»,
	тест баланса — если трассу не пройти или она проходится без смены слоёв).
]]

local Config = {}

Config.Version = "1.0.0"

-- Архипелаг (studs). Центр мира (0, 0), море на Y = 0.
Config.World = {
	Islands = 11, -- вместе с гаванью
	Spread = 720, -- центры островов не дальше этого от центра
	MinGap = 220, -- между центрами островов
	IslandR = { 44, 70 },
	HarborR = 95,
	HarborTop = 5,
	Top = { 8, 18 }, -- высота плато острова
	Beach = 7, -- ширина пляжа (высота 3)
	BeachH = 3,
	Houses = { 2, 4 },
	HouseSize = 16,
	HouseH = { 9, 17 }, -- от плато до крыши
	HouseGap = 24,
	Lighthouse = 0.35, -- доля островов с маяком
	LighthouseH = 46,
	LighthouseR = 4,
	Edge = 960, -- дальше ветер сносит обратно к архипелагу
	EdgePush = 22,
	Water = 0,
}

-- Слои ветра. Цвет — по высоте (верхний всегда фиолетовый): игрок быстро запоминает.
Config.Wind = {
	Layers = 6,
	Bottom = 40, -- ниже — приземный бриз
	Thick = 36,
	Ceiling = 256, -- = Bottom + Layers·Thick
	Surface = 5, -- скорость бриза
	SpeedMin = 14, -- нижний слой
	SpeedMax = 26, -- верхний слой
	SpeedJitter = 1,
	Jitter = 15, -- ° случайный сдвиг от равномерной «розы»
	MinTurn = 50, -- ° соседние по высоте слои отличаются хотя бы на столько
	Blend = 4, -- ± studs: размытие границы слоя
	Colors = {
		{ 120, 200, 255 }, -- 1 голубой
		{ 90, 230, 140 }, -- 2 зелёный
		{ 255, 215, 70 }, -- 3 жёлтый
		{ 255, 140, 60 }, -- 4 оранжевый
		{ 255, 80, 120 }, -- 5 малиновый
		{ 185, 110, 255 }, -- 6 фиолетовый
	},
	SurfaceColor = { 200, 210, 220 },
}

-- Шар. Позиция шара = низ корзины.
Config.Flight = {
	Climb = 18, -- studs/s с горелкой
	Sink = 18, -- studs/s с открытым клапаном
	TauV = 0.18, -- с: вертикальная скорость догоняет цель (63%)
	TauH = 0.45, -- с: горизонтальная скорость догоняет ветер
	GroundGrip = 0.12, -- на земле ветер тащит шар слабо
	SplashH = 1.2, -- ниже этого над водой — шар намок
	SplashTime = 3,
	RootH = 1.75, -- центр корзины над её низом
	SpeedSlack = 1.3, -- сервер: допуск к максимальной скорости
	SpeedPad = 12, -- сервер: + studs/s допуска (лаги)
}

Config.Race = {
	Checkpoints = 3, -- + финиш
	CheckR = 45,
	LegMin = 280,
	LegMax = 540,
	TurnMin = 35, -- ° трасса не идёт по прямой
	MaxTime = 300,
	AfterFirst = 45, -- после первого финиша
	Intermission = 60, -- свободный полёт между гонками
	Countdown = 3,
	Results = 8,
	GridGap = 22,
	GridRow = 6,
	FillTo = 6, -- ИИ-соперники добавляются до этого числа шаров
	Max = 12,
	RespawnY = 58, -- над последним чекпоинтом после «намок» (середина 1-го слоя)
}

Config.Parcel = {
	Fall = 22, -- studs/s под парашютом
	Drift = 0.85, -- доля скорости ветра, с которой сносит посылку
	Margin = 3, -- крыша засчитывается с запасом
	MinDist = 220,
	MaxDist = 760,
	Step = 0.1,
}

Config.Rewards = {
	Places = { 60, 45, 35, 28, 24, 20, 18, 16, 14, 12, 10, 10 },
	PerCheckpoint = 4, -- не финишировал
	ParcelBase = 12,
	ParcelPerStud = 1 / 25,
	ParcelMax = 40,
	FastBonus = 0.5,
	ParBase = 20, -- с, + расстояние / ParSpeed
	ParSpeed = 12,
	DoubleCoins = 2,
	VipBonus = 0.1,
}

Config.Ai = {
	Names = {
		"Zephyr",
		"Mistral",
		"Sirocco",
		"Breeze",
		"Gale",
		"Bora",
		"Chinook",
		"Foehn",
		"Levant",
		"Monsoon",
	},
	Think = 0.5, -- с между решениями
	Reaction = { 0.2, 0.8 }, -- задержка «руки» ИИ
	Step = 0.1,
}

Config.Timing = {
	Step = 0.1, -- шаг серверной логики
	Validate = 0.25, -- проверка скорости шаров
}

-- Цены косметики в монетах и возврат за дубликат
Config.Rarity = {
	Common = { weight = 6000, price = 250, refund = 60, color = { 200, 205, 215 } },
	Rare = { weight = 2800, price = 600, refund = 150, color = { 90, 170, 255 } },
	Epic = { weight = 1000, price = 1500, refund = 400, color = { 190, 110, 255 } },
	Legendary = { weight = 200, price = 4000, refund = 1000, color = { 255, 190, 60 } },
}
Config.RarityOrder = { "Common", "Rare", "Epic", "Legendary" }
Config.WeightTotal = 10000 -- веса в сотых долях процента: 6000 = 60.00%

--[[
	ID товаров из Creator Hub (Monetization → Passes / Developer Products).
	Пока ID = 0: в Studio покупка эмулируется, в живой игре кнопка неактивна («скоро»).
	robux — рекомендуемые цены (настоящую цену игра берёт из GetProductInfo).
]]
Config.Passes = {
	DoubleCoins = { id = 0, robux = 149 },
	Cargo = { id = 0, robux = 99 },
	Vip = { id = 0, robux = 249 },
}
Config.Products = {
	Coins500 = { id = 0, robux = 25, coins = 500 },
	Coins3000 = { id = 0, robux = 99, coins = 3000 },
	Chest = { id = 0, robux = 35 },
	DirectRare = { id = 0, robux = 49, rarity = "Rare" },
	DirectEpic = { id = 0, robux = 99, rarity = "Epic" },
	DirectLegendary = { id = 0, robux = 199, rarity = "Legendary" },
}
Config.ProductOrder = { "Coins500", "Coins3000", "Chest", "DirectRare", "DirectEpic", "DirectLegendary" }
Config.ChestFallbackCoins = 500 -- если сундук недоступен игроку по политике

Config.DataStore = {
	Name = "WindsProfiles_v1",
	AutosaveEvery = 90,
	Retries = 4,
	ReceiptLog = 100,
}

-- Встроенные звуки клиента (rbxasset://). Свои — rbxassetid://<id>.
Config.Sounds = {
	Burner = { Id = "rbxasset://sounds/action_falling.mp3", Volume = 0.35, Speed = 0.55 },
	Valve = { Id = "rbxasset://sounds/action_swim.mp3", Volume = 0.3, Speed = 1.3 },
	Layer = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.25, Speed = 0.7 },
	Checkpoint = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.6, Speed = 1.2 },
	Finish = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.8, Speed = 0.9 },
	Splash = { Id = "rbxasset://sounds/impact_water.mp3", Volume = 0.7, Speed = 1 },
	Drop = { Id = "rbxasset://sounds/action_jump_land.mp3", Volume = 0.5, Speed = 1.2 },
	Delivered = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.6, Speed = 1.5 },
	Count = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.5, Speed = 1 },
	Button = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.2, Speed = 0.8 },
}

return Config
