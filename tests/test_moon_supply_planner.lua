#!/usr/bin/env lua
local boot = loadfile("tests/loader.lua")()
local T = boot({ projects = { "moon_supply" } })
local A = T.assert

local planner = require("planner")
local configMod = require("config")

A.suite("moon_supply config fingerprint", {
    {
        name = "itemsFingerprint tracks order id target",
        fn = function()
            local a = {
                { name = "x", target = 1 },
                { name = "y", target = 2 },
            }
            local b = {
                { name = "x", target = 1 },
                { name = "y", target = 3 },
            }
            local c = {
                { name = "y", target = 2 },
                { name = "x", target = 1 },
            }
            A.eq(configMod.itemsFingerprint(a), "x=1;y=2")
            A.truthy(configMod.itemsFingerprint(a) ~= configMod.itemsFingerprint(b))
            A.truthy(configMod.itemsFingerprint(a) ~= configMod.itemsFingerprint(c))
            A.eq(configMod.hwFingerprint({
                bridge = "meBridge_2",
                monitor = "monitor_1",
                modem = "bottom",
                buffer = "",
                loader_prefix = "pref",
                expected = 10,
                relay = "top",
                relay_side = "back",
            }), "meBridge_2|monitor_1|bottom||pref|10|top|back")
        end,
    },
})

A.suite("moon_supply planner", {
    {
        name = "ALARM if any item below red_line",
        fn = function()
            local items = {
                { name = "a", target = 100 },
                { name = "b", target = 100 },
            }
            local rows, mode = planner.assess(items, { a = 10, b = 80 }, 0.25)
            A.eq(mode, planner.ZONE_ALARM)
            A.eq(rows[1].zone, planner.ZONE_ALARM)
            A.eq(rows[2].zone, planner.ZONE_WARN)
        end,
    },
    {
        name = "WARN when deficits but none below red",
        fn = function()
            local items = {
                { name = "a", target = 100 },
                { name = "b", target = 100 },
            }
            local rows, mode = planner.assess(items, { a = 50, b = 100 }, 0.25)
            A.eq(mode, planner.ZONE_WARN)
            A.eq(rows[1].zone, planner.ZONE_WARN)
            A.eq(rows[2].zone, planner.ZONE_OK)
        end,
    },
    {
        name = "OK when all at target",
        fn = function()
            local items = { { name = "a", target = 10 } }
            local _, mode = planner.assess(items, { a = 10 }, 0.25)
            A.eq(mode, planner.ZONE_OK)
        end,
    },
    {
        name = "ALARM package includes warn deficits",
        fn = function()
            local rows = {
                { name = "a", zone = "ALARM", deficit = 5 },
                { name = "b", zone = "WARN", deficit = 3 },
                { name = "c", zone = "OK", deficit = 0 },
            }
            local wants, order = planner.packageWants(rows, planner.ZONE_ALARM)
            A.eq(wants.a, 5)
            A.eq(wants.b, 3)
            A.eq(wants.c, nil)
            A.eq(#order, 2)
            A.eq(order[1], "a")
            A.eq(order[2], "b")
        end,
    },
    {
        name = "ALARM loads alarm items before warn items",
        fn = function()
            local rows = {
                { name = "warn", zone = "WARN", deficit = 9 },
                { name = "alarm", zone = "ALARM", deficit = 2 },
            }
            local _, order = planner.packageWants(rows, planner.ZONE_ALARM)
            A.eq(order[1], "alarm")
            A.eq(order[2], "warn")
        end,
    },
    {
        name = "fire when package is loaded or loaders are full",
        fn = function()
            A.eq(planner.shouldFire(true, false), true)
            A.eq(planner.shouldFire(false, true), true)
            A.eq(planner.shouldFire(false, false), false)
        end,
    },
    {
        name = "packageDone skips unobtainable items",
        fn = function()
            local wants = { a = 10, b = 5 }
            A.eq(planner.packageDone(wants, { a = 10, b = 0 }), false)
            A.eq(planner.packageDone(wants, { a = 10, b = 0 }, { b = true }), true)
            A.eq(planner.packageDone(wants, { a = 0, b = 0 }, { a = true, b = true }), false)
            A.eq(planner.waitItem(wants, { "a", "b" }, { a = 10, b = 0 }, {}), "b")
            A.eq(planner.waitItem(wants, { "a", "b" }, { a = 10, b = 0 }, { b = true }), nil)
            A.eq(planner.waitItem(wants, { "a", "b" }, { a = 10, b = 5 }, {}), nil)
            local w2, o2 = planner.filterObtainable(wants, { "a", "b" }, { b = true })
            A.eq(w2.a, 10)
            A.eq(w2.b, nil)
            A.eq(#o2, 1)
            A.eq(o2[1], "a")
            local skipped = planner.skippedNames({ "a", "b" }, { b = true })
            A.eq(#skipped, 1)
            A.eq(skipped[1], "b")
        end,
    },
    {
        name = "yield only after craft wait when nothing more can load",
        fn = function()
            A.eq(planner.shouldYield(true, false, false, false), false)
            A.eq(planner.shouldYield(false, true, false, false), false)
            A.eq(planner.shouldYield(false, false, true, false), false)
            A.eq(planner.shouldYield(false, false, false, true), false)
            A.eq(planner.shouldYield(false, false, false, false), true)
        end,
    },
    {
        name = "craft wait by mode",
        fn = function()
            local cfg = { craft_wait_red = 60, craft_wait_green = 120 }
            A.eq(planner.craftWaitSeconds(cfg, "ALARM"), 60)
            A.eq(planner.craftWaitSeconds(cfg, "WARN"), 120)
        end,
    },
})

local railgun_hw = require("railgun_hw")
local stub = T.stub

local function loaderWith(slots, size)
    local inv = stub.makeInventory(slots)
    function inv.size()
        return size
    end
    return inv
end

A.suite("moon_supply loader cargo", {
    {
        name = "universal circuits count as cargo",
        fn = function()
            local name = "tfg:hv_railgun_item_loader_in_20"
            stub.addPeripheral(name, loaderWith({
                [1] = { name = "tfg:hv_universal_circuit", count = 64 },
                [2] = { name = "gtceu:programmed_circuit", count = 1 },
            }, 2))
            local full, cargo = railgun_hw.loaderFill(name)
            A.eq(full, true)
            A.eq(cargo, 1)
            local totals = railgun_hw.cargoTotals({ name })
            A.eq(totals["tfg:hv_universal_circuit"], 64)
            A.isNil(totals["gtceu:programmed_circuit"])
            stub.removePeripheral(name)
        end,
    },
    {
        name = "programmed circuit alone does not fill a loader",
        fn = function()
            local name = "tfg:hv_railgun_item_loader_in_21"
            stub.addPeripheral(name, loaderWith({
                [1] = { name = "gtceu:programmed_circuit", count = 1 },
            }, 2))
            local full = railgun_hw.loaderFill(name)
            A.eq(full, false)
            stub.removePeripheral(name)
        end,
    },
})

local ae_bridge = require("ae_bridge")

A.suite("moon_supply ae craft cover", {
    {
        name = "isItemCrafting blocks unknown amount",
        fn = function()
            local bridge = {
                isItemCrafting = function(filter)
                    return filter and filter.name == "a"
                end,
            }
            local amount, known = ae_bridge.craftingAmount(bridge, "a")
            A.eq(amount, 0)
            A.eq(known, false)
            amount, known = ae_bridge.craftingAmount(bridge, "b")
            A.eq(amount, 0)
            A.eq(known, true)
        end,
    },
    {
        name = "getCraftingTasks sums requested counts",
        fn = function()
            local bridge = {
                getCraftingTasks = function()
                    return {
                        { name = "a", count = 10 },
                        { name = "a", amount = 5 },
                        { name = "b", count = 3 },
                    }
                end,
            }
            local amount, known = ae_bridge.craftingAmount(bridge, "a")
            A.eq(amount, 15)
            A.eq(known, true)
        end,
    },
})

local monitor_ui = require("monitor_ui")

local function cpEnd(line, token)
    local byteAt = line:find(token, 1, true)
    A.truthy(byteAt, "missing " .. token)
    local n, i = 0, 1
    local stop = byteAt + #token - 1
    while i <= stop do
        local b = line:byte(i)
        if not b or b < 128 then
            i = i + 1
        elseif b < 224 then
            i = i + 2
        elseif b < 240 then
            i = i + 3
        else
            i = i + 4
        end
        n = n + 1
    end
    return n
end

A.suite("moon_supply monitor", {
    {
        name = "stock colors and status cells",
        fn = function()
            A.truthy(colors and colors.red, "colors stub")
            A.eq(monitor_ui.stockColor(10, 100, "ALARM"), colors.red)
            A.eq(monitor_ui.stockColor(50, 100, "WARN"), colors.yellow)
            A.eq(monitor_ui.stockColor(100, 100, "OK"), colors.lime)
            local t, c = monitor_ui.statusCell({ staged = 12 })
            A.eq(t, "Загрузка (12)")
            A.eq(c, colors.yellow)
            t, c = monitor_ui.statusCell({ staged = 12 }, "cooldown")
            A.eq(t, "Отправлено (12)")
            A.eq(c, colors.yellow)
            t, c = monitor_ui.statusCell({ crafting = 7 })
            A.eq(t, "Крафт (7)")
            A.eq(c, colors.yellow)
            t, c = monitor_ui.statusCell({ ae = "no" })
            A.eq(t, "Нет в AE")
            A.eq(c, colors.red)
            t, c = monitor_ui.statusCell({})
            A.eq(t, "-")
            A.eq(c, colors.white)
            A.eq(monitor_ui.phasePulseSuffix("craft_wait", 0), "")
            A.eq(monitor_ui.phasePulseIndex("poll", 0), 1)
            A.truthy(monitor_ui.phasePulseIndex("poll", 0) ~= monitor_ui.phasePulseIndex("poll", 1))
        end,
    },
    {
        name = "russian labels and aligned columns",
        fn = function()
            local lines = {}
            local cursor = { x = 1, y = 1 }
            local mon = {
                setTextScale = function() end,
                setBackgroundColor = function() end,
                setTextColor = function() end,
                clear = function() end,
                getSize = function() return 60, 20 end,
                setCursorPos = function(cx, cy)
                    cursor.x, cursor.y = cx, cy
                end,
                write = function(text)
                    lines[cursor.y] = (lines[cursor.y] or "") .. text
                end,
            }
            monitor_ui.draw(mon, {
                phase = "craft_wait",
                mode = "ALARM",
                error = "луна не в сети",
                wait_item = "gtceu:aluminium_ingot",
                loaders_full = 1,
                loaders_total = 10,
                craft_total = 5,
                staged_total = 2,
                craft_left = 60,
                rows = {
                    {
                        name = "gtceu:aluminium_ingot",
                        moon = 0, target = 1024, zone = "?",
                        earth = 50960, crafting = 0, staged = 0, ae = nil,
                    },
                    {
                        name = "gtceu:dense_silicon_plate",
                        moon = 12, target = 128, zone = "ALARM",
                        earth = 66, crafting = 0, staged = 8, ae = nil,
                    },
                },
            })
            A.eq(monitor_ui.itemLabel("gtceu:hv_robot_arm"), "роборука HV")
            A.truthy(lines[1]:find("снабжение", 1, true))
            A.truthy(lines[1]:find("тревога", 1, true))
            A.truthy(lines[1]:find("ожидание", 1, true))
            A.truthy(not lines[1]:find("слиток алюминия", 1, true), "wait_item not in title")
            A.truthy(lines[2]:find("к запуску", 1, true))
            A.truthy(lines[3]:find("ожидание AE", 1, true) or lines[3]:find("ждём", 1, true), "status line 1")
            A.truthy(
                lines[4]:find("ждём", 1, true) or lines[4]:find("луна не в сети", 1, true),
                "status line 2 filled (fixed band)"
            )
            local head = lines[5]
            A.truthy(head:find("Луна", 1, true))
            A.truthy(head:find("Предмет", 1, true))
            local row = lines[6]
            A.eq(cpEnd(head, "Луна"), cpEnd(row, "н/д"))
            A.eq(cpEnd(head, "Цель"), cpEnd(row, "1024"))
            A.eq(cpEnd(head, "Земля"), cpEnd(row, "50960"))
            A.truthy(row:find("слиток алюминия", 1, true))
            A.truthy(lines[7]:find("Загрузка (8)", 1, true))
            A.eq(monitor_ui.itemLabel("gtceu:ram_chip"), "ОЗУ")
            A.eq(monitor_ui.itemLabel("gtceu:cpu_chip"), "процессор")
            A.eq(monitor_ui.itemLabel("minecraft:gold_ingot"), "слиток золота")
            A.eq(monitor_ui.itemLabel("gtceu:exquisite_certus_quartz_gem"), "Истин. кварц (Изыск.)")

            -- No error → same table Y (header still on line 5).
            lines = {}
            cursor.x, cursor.y = 1, 1
            mon._moonSupplyLineCache = nil
            mon._moonSupplyLayout = nil
            monitor_ui.draw(mon, {
                phase = "poll",
                mode = "OK",
                error = "",
                rows = {
                    {
                        name = "gtceu:aluminium_ingot",
                        moon = 1024, target = 1024, zone = "OK",
                        earth = 1, crafting = 0, staged = 0,
                    },
                },
            })
            A.truthy(not lines[3] or lines[3]:match("^%s*$"), "sys1 empty")
            A.truthy(not lines[4] or lines[4]:match("^%s*$"), "sys2 empty")
            A.truthy(lines[5]:find("Предмет", 1, true))
        end,
    },
    {
        name = "groups smaller to larger",
        fn = function()
            local sorted = monitor_ui.sortRows({
                { name = "tfg:iv_universal_circuit" },
                { name = "gtceu:hv_robot_arm" },
                { name = "tfg:lv_universal_circuit" },
                { name = "minecraft:gold_ingot" },
                { name = "gtceu:mv_robot_arm" },
                { name = "gtceu:aluminium_ingot" },
                { name = "minecraft:redstone" },
                { name = "gtceu:diamond_plate" },
                { name = "gtceu:silicon_plate" },
            })
            local names = {}
            for i = 1, #sorted do
                names[i] = sorted[i].name
            end
            A.eq(names[1], "tfg:lv_universal_circuit")
            A.eq(names[2], "tfg:iv_universal_circuit")
            A.eq(names[3], "gtceu:mv_robot_arm")
            A.eq(names[4], "gtceu:hv_robot_arm")
            A.eq(names[5], "minecraft:gold_ingot")
            A.eq(names[6], "gtceu:aluminium_ingot")
            A.eq(names[7], "gtceu:silicon_plate")
            A.eq(names[8], "gtceu:diamond_plate")
            A.eq(names[9], "minecraft:redstone")
        end,
    },
})
