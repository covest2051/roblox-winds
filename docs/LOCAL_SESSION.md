# Локальная сессия Claude Code + Studio MCP

Подготовка Studio MCP — как в `roblox/docs/LOCAL_SESSION.md` (Assistant → Manage MCP Servers → Enable Studio as MCP server, Quick connect → Claude Code). Сначала пройди [`PLAYTEST.md`](PLAYTEST.md) руками — это не тратит лимиты. Найденное (текст из Output, описание) дешевле присылать в облачную сессию.

## Промпт для старта (скопируй целиком)

```
Проект — Roblox-игра «Ветра», Rojo-проект в этом репозитории.
Studio открыта и синхронизирована через `rojo serve`, Studio MCP подключён.

Правила экономии:
- Не читай весь репозиторий: структура — в README.md, механики — в docs/DESIGN.md.
- Правь ТОЛЬКО src/**, Rojo синхронизирует сам. Не правь скрипты в Studio напрямую.
- screen_capture — только если я прошу или баг без картинки не понять.
- После каждой правки логики: `lune run tests/run.luau`.

Задача:
1. start_stop_play (Play), подожди ~8 с, get_console_output.
2. Найди строки [SELFTEST] и красные ошибки, пришли короткую сводку.
3. Исправляй ошибки по одной: правка → стоп/Play → Output.
4. Когда Output чистый, проверь физику шара через execute_luau (datamodel Server):
     local p = game.Players:GetPlayers()[1]
     local b = workspace.Balloons["Balloon_" .. p.UserId]
     print(b.Seat.Occupant, b.PrimaryPart.Anchored, b.PrimaryPart:GetNetworkOwner())
   Ожидается: Humanoid, false, имя игрока. Потом (datamodel Client):
     local b = workspace.Balloons["Balloon_" .. game.Players.LocalPlayer.UserId]
     print(b.PrimaryPart.Lift.VectorVelocity, b.PrimaryPart.AssemblyLinearVelocity)
   Скорости должны совпадать (≈ ветер слоя): клиент управляет корзиной.
5. Проверь гонку командами (datamodel Server), по одной, после каждой — get_console_output:
     workspace:SetAttribute("DebugCommand", "race")    -- гонка сейчас
     workspace:SetAttribute("DebugCommand", "cp")      -- к следующему чекпоинту
     workspace:SetAttribute("DebugCommand", "splash")  -- в море
     workspace:SetAttribute("DebugCommand", "finish")  -- к финишу
   Потом screen_capture один раз: видны столб чекпоинта со стрелками, ИИ-шары, лестница ветров?
   Остальные команды: stop | order | winds | high | harbor | coins | reset | selftest.
6. Коммить исправления с понятными сообщениями.
```

## Типичные проблемы, видимые только в движке

| Симптом | Где править |
|---|---|
| Персонаж не садится / выпадает из корзины | `FlightService.seatCharacter`: `seat:Sit(hum)` после `PivotTo` персонажа к сиденью; сиденье — `BalloonBuilder` (`Seat`, `CFrame` внутри корзины). Пересадка при `Occupant == nil` — через 0,5 с |
| Шар падает / не летит, `Lift` есть | Сетевой владелец: `FlightService.giveOwnership` (`SetNetworkOwner(player)` после снятия `Anchored`); `LinearVelocity.MaxForce = math.huge`; детали шара сварены `WeldConstraint` с корзиной |
| Шар кувыркается | `AlignOrientation` «Upright» (`RigidityEnabled = true`) в `BalloonBuilder.build` |
| Управление «ватное» в живой игре, хотя тесты зелёные | Клиент пишет скорость в `Controls.update` на `Heartbeat`; можно перенести на `RunService.PreSimulation`. Числа отклика — `Config.Flight` (`Climb`, `TauV`, `TauH`), после правки — `lune run tests/run.luau` |
| Сервер «откатывает» шар (в Output `[Flight] … moved too fast`) | `Config.Flight.SpeedSlack` / `SpeedPad` (допуск проверки скорости) |
| Камера в оболочке / слишком близко | `StarterPlayer.CameraMinZoomDistance` в `default.project.json`; стартовый отъезд — `Controls.build` |
| Ленты ветра мешают / не видны | `WindFx.luau`: `AREA`, `PER_LAYER`, прозрачность в `updateStreaks` |
| ИИ-шары дёргаются | `RaceService.heartbeat` (интерполяция между шагами логики); шаг — `Config.Timing.Step` |
| Посылка падает мимо метки | Метка и сервер считают одно и то же (`Parcel.predict`); проверь, что `WindSeed` у клиента тот же (атрибут Workspace) |
| Лагает | число лент `PER_LAYER`, частота метки (`predictAcc`, 0,1 с) в `WindFx.luau` |

## Звуки
`Config.Sounds` — встроенные `rbxasset://` звуки (заглушки). Найди через `search_asset` бесплатные (автор Roblox или public): рёв горелки (Burner, лучше зацикленный), шипение клапана, ветер (фон, громче выше), «динь» чекпоинта, плюх в воду — и впиши `rbxassetid://<id>` в `Config.Sounds`.
