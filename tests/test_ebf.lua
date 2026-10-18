#!/usr/bin/env lua
local boot = loadfile("tests/loader.lua")()
local T = boot()
local A = T.assert
local stub = T.stub

-- Prefer ebf/ over other projects that also ship config/discover modules.
do
    local root = T.root
    package.path = table.concat({
        root .. "/ebf/?.lua",
        root .. "/shared/?.lua",
        root .. "/tests/?.lua",
        package.path,
    }, ";")
    for _, name in ipairs({
        "config", "discover", "recipe", "furnace", "ui", "main",
    }) do
        package.loaded[name] = nil
    end
end

local discover = require("discover")
local recipe = require("recipe")
local furnace = require("furnace")
local configMod = require("config")

local function addInv(name, slots)
    stub.addPeripheral(name, stub.makeInventory(slots or {}))
end

local function addTankInv(name, slots, fluids)
    local inv = stub.makeInventory(slots or {})
    local tank = stub.makeTank(fluids or {})
    inv.tanks = tank.tanks
    inv.pushFluid = tank.pushFluid
    inv._receiveFluid = tank._receiveFluid
    inv._fluids = tank._fluids
    stub.addPeripheral(name, inv)
end

A.suite("ebf discover / recipe / furnace", {
    {
        name = "config defaults when cfg missing",
        fn = function()
            stub.reset()
            stub.install()
            stub.setRunningProgram("/ebf/ebf.lua")
            local cfg = configMod.load("/missing_ebf.cfg")
            A.eq(cfg.hot_sink, "gtceu:hv_buffer_0")
            A.eq(cfg.max_inflight, 8)
            A.eq(cfg.recipe_buffer_min, 1)
        end,
    },
    {
        name = "prefixedIndex parses hatch names",
        fn = function()
            A.eq(discover._prefixedIndex("gtceu:lv_input_bus_3", "gtceu:lv_input_bus"), 3)
            A.eq(discover._prefixedIndex("gtceu:hv_buffer_0", "gtceu:hv_buffer"), 0)
            A.isNil(discover._prefixedIndex("gtceu:lv_input_bus_3", "gtceu:lv_output_bus"))
        end,
    },
    {
        name = "scan groups furnaces by index and skips buffer_0",
        fn = function()
            stub.reset()
            stub.install()
            addInv("gtceu:hv_buffer_0", {})
            addInv("gtceu:hv_buffer_1", { [1] = { name = "gtceu:iron_dust", count = 3 } })
            addInv("gtceu:hv_buffer_2", {})
            addInv("ae2:pattern_provider_5", {})
            addInv("gtceu:lv_input_bus_0", {})
            addTankInv("gtceu:ev_input_hatch_4x_0", {}, {})
            addInv("gtceu:lv_output_bus_0", {})
            addTankInv("gtceu:lv_output_hatch_0", {}, {})
            addInv("gtceu:lv_input_bus_1", {})
            addInv("gtceu:lv_output_bus_1", {})
            -- incomplete index 2: only input bus
            addInv("gtceu:lv_input_bus_2", {})

            local net = discover.scan({
                recipe_buffer_prefix = "gtceu:hv_buffer",
                recipe_buffer_min = 1,
                hot_sink = "gtceu:hv_buffer_0",
                ae_sink = "ae2:pattern_provider_5",
                input_bus_prefix = "gtceu:lv_input_bus",
                input_hatch_prefix = "gtceu:ev_input_hatch_4x",
                output_bus_prefix = "gtceu:lv_output_bus",
                output_hatch_prefix = "gtceu:lv_output_hatch",
            })

            A.eq(#net.buffers, 2)
            A.eq(net.buffers[1], "gtceu:hv_buffer_1")
            A.eq(net.buffers[2], "gtceu:hv_buffer_2")
            A.eq(net.hotSink, "gtceu:hv_buffer_0")
            -- Each hatch index = one NL+NR pack (not merged).
            A.eq(#net.furnaces, 2)
            A.eq(net.furnaces[1].index, 0)
            A.eq(net.furnaces[1].label, "1")
            A.eq(net.furnaces[1].inputBus, "gtceu:lv_input_bus_0")
            A.eq(net.furnaces[2].index, 1)
            A.eq(net.furnaces[2].label, "2")
        end,
    },
    {
        name = "recipe snapshot and atomic push",
        fn = function()
            stub.reset()
            stub.install()
            addTankInv("gtceu:hv_buffer_1", {
                [1] = { name = "gtceu:iron_dust", count = 2 },
                [2] = { name = "minecraft:coal", count = 1 },
            }, {
                { name = "gtceu:oxygen", amount = 500 },
            })
            addInv("gtceu:lv_input_bus_0", {})
            addTankInv("gtceu:ev_input_hatch_4x_0", {}, {})

            local snap = recipe.snapshot("gtceu:hv_buffer_1")
            A.truthy(recipe.hasContent(snap))
            A.eq(snap.items["gtceu:iron_dust"], 2)
            A.eq(snap.fluids["gtceu:oxygen"], 500)

            local ok, mi, mf, err = recipe.pushAtomic(
                "gtceu:hv_buffer_1",
                "gtceu:lv_input_bus_0",
                "gtceu:ev_input_hatch_4x_0"
            )
            A.truthy(ok, err)
            A.eq(mi, 3)
            A.eq(mf, 500)
            A.truthy(recipe.isEmpty(recipe.snapshot("gtceu:hv_buffer_1")))
            A.eq(recipe.snapshot("gtceu:lv_input_bus_0").items["gtceu:iron_dust"], 2)
        end,
    },
    {
        name = "pickTarget finishes L/R pair before opening empty",
        fn = function()
            local states = {
                [0] = { index = 0, inflight = 2, paired = 2, id = "ebf_0" },
                [1] = { index = 1, inflight = 0, paired = 2, id = "ebf_1" },
                [2] = { index = 2, inflight = 1, paired = 2, id = "ebf_2" },
            }
            -- Incomplete pair (2) beats empty (1).
            local t = furnace.pickTarget(states, 3)
            A.eq(t.index, 2)
            states[2].inflight = 2
            -- All pairs at >=2 with room: empty pack opens next.
            t = furnace.pickTarget(states, 3)
            A.eq(t.index, 1)
            states[1].inflight = 3
            t = furnace.pickTarget(states, 3)
            A.eq(t.index, 0)
            states[0].inflight = 3
            states[2].inflight = 3
            A.isNil(furnace.pickTarget(states, 3))
        end,
    },
    {
        name = "feedOne bumps inflight; drain hot to sink",
        fn = function()
            stub.reset()
            stub.install()
            addInv("gtceu:hv_buffer_1", {
                [1] = { name = "gtceu:iron_dust", count = 1 },
            })
            addInv("gtceu:lv_input_bus_0", {})
            addInv("gtceu:lv_output_bus_0", {
                [1] = { name = "gtceu:hot_iron_ingot", count = 1 },
                [2] = { name = "gtceu:ash_dust", count = 2 },
            })
            addInv("gtceu:hv_buffer_0", {})
            addInv("ae2:pattern_provider_5", {})

            local states = {
                [0] = furnace.newState({
                    index = 0,
                    id = "ebf_0",
                    inputBus = "gtceu:lv_input_bus_0",
                    outputBus = "gtceu:lv_output_bus_0",
                }),
            }
            states[0].inflight = 1

            local st, err = furnace.feedOne(states, "gtceu:hv_buffer_1", 6)
            A.truthy(st, err)
            A.eq(states[0].inflight, 2)

            local hot, other, _, done = furnace.drain(
                states[0],
                "gtceu:hv_buffer_0",
                "ae2:pattern_provider_5",
                1
            )
            A.eq(hot, 1)
            A.eq(other, 2)
            A.eq(done, 1)
            A.eq(states[0].inflight, 1)
            A.eq(recipe.snapshot("gtceu:hv_buffer_0").items["gtceu:hot_iron_ingot"], 1)
            A.eq(recipe.snapshot("ae2:pattern_provider_5").items["gtceu:ash_dust"], 2)
        end,
    },
    {
        name = "estimateDone counts stacked hot ingots",
        fn = function()
            A.eq(furnace.estimateDone(5, 0, 0, 3, 1), 3)
            A.eq(furnace.estimateDone(5, 0, 0, 8, 1), 5)
            A.eq(furnace.estimateDone(0, 4, 0, 2, 1), 1)
            A.eq(furnace.estimateDone(0, 0, 1000, 2, 1), 1)
            A.eq(furnace.estimateDone(0, 0, 0, 2, 1), 0)
        end,
    },
    {
        name = "drain stacked hot ingots clears multiple inflight",
        fn = function()
            stub.reset()
            stub.install()
            addInv("gtceu:lv_output_bus_0", {
                [1] = { name = "gtceu:hot_aluminium_ingot", count = 4 },
            })
            addInv("gtceu:hv_buffer_0", {})
            addInv("ae2:pattern_provider_5", {})

            local st = furnace.newState({
                index = 0,
                id = "ebf_0",
                inputBus = "gtceu:lv_input_bus_0",
                outputBus = "gtceu:lv_output_bus_0",
            })
            st.inflight = 3

            local hot, _, _, done = furnace.drain(st, "gtceu:hv_buffer_0", "ae2:pattern_provider_5", 1)
            A.eq(hot, 4)
            A.eq(done, 3)
            A.eq(st.inflight, 0)
            A.eq(st.drained, 3)
        end,
    },
    {
        name = "isHotIngot matches gtceu hot ingots",
        fn = function()
            A.truthy(furnace.isHotIngot("gtceu:hot_steel_ingot"))
            A.truthy(furnace.isHotIngot("gtceu:hot_tungstensteel_ingot"))
            A.truthy(furnace.isHotIngot("gtceu:hot_aluminium_ingot"))
            A.falsy(furnace.isHotIngot("gtceu:steel_ingot"))
            A.falsy(furnace.isHotIngot("gtceu:ash_dust"))
        end,
    },
    {
        name = "reconcile clears sticky when bus empty past grace",
        fn = function()
            stub.reset()
            stub.install()
            addInv("gtceu:lv_input_bus_0", {})
            addInv("gtceu:lv_output_bus_0", {})
            local st = furnace.newState({
                index = 0,
                id = "ebf_0",
                inputBus = "gtceu:lv_input_bus_0",
                outputBus = "gtceu:lv_output_bus_0",
            })
            st.inflight = 5
            st.lastFeedAt = 1000
            local drop = furnace.reconcile(st, 1, 90, 1200)
            A.eq(drop, 5)
            A.eq(st.inflight, 0)
            A.eq(st.drained, 5)
        end,
    },
    {
        name = "reconcile leaves sticky untouched during craft grace",
        fn = function()
            stub.reset()
            stub.install()
            addInv("gtceu:lv_input_bus_0", {})
            addInv("gtceu:lv_output_bus_0", {})
            local st = furnace.newState({
                index = 0,
                id = "ebf_0",
                inputBus = "gtceu:lv_input_bus_0",
                outputBus = "gtceu:lv_output_bus_0",
            })
            st.inflight = 5
            st.lastFeedAt = 1000
            local drop = furnace.reconcile(st, 1, 90, 1050)
            A.eq(drop, 0)
            A.eq(st.inflight, 5)
        end,
    },
    {
        name = "reconcile clears unknown sticky with empty bus",
        fn = function()
            stub.reset()
            stub.install()
            addInv("gtceu:lv_input_bus_0", {})
            addInv("gtceu:lv_output_bus_0", {})
            local st = furnace.newState({
                index = 0,
                id = "ebf_0",
                inputBus = "gtceu:lv_input_bus_0",
                outputBus = "gtceu:lv_output_bus_0",
            })
            st.inflight = 5
            local drop = furnace.reconcile(st, 1, 90, 50)
            A.eq(drop, 5)
            A.eq(st.inflight, 0)
        end,
    },
    {
        name = "reconcile caps sticky to buffered after grace",
        fn = function()
            stub.reset()
            stub.install()
            addInv("gtceu:lv_input_bus_0", {
                [1] = { name = "gtceu:aluminium_dust", count = 3 },
            })
            addInv("gtceu:lv_output_bus_0", {})
            local st = furnace.newState({
                index = 0,
                id = "ebf_0",
                inputBus = "gtceu:lv_input_bus_0",
                outputBus = "gtceu:lv_output_bus_0",
            })
            st.inflight = 6
            st.lastFeedAt = 1000
            local drop = furnace.reconcile(st, 1, 90, 1200)
            A.eq(drop, 3)
            A.eq(st.inflight, 3)
        end,
    },
    {
        name = "pushOneRecipe splits single-item stack by unit",
        fn = function()
            stub.reset()
            stub.install()
            addInv("gtceu:hv_buffer_1", {
                [1] = { name = "gtceu:aluminium_dust", count = 4 },
            })
            addInv("gtceu:lv_input_bus_0", {})

            local ok, mi = recipe.pushOneRecipe(
                "gtceu:hv_buffer_1",
                "gtceu:lv_input_bus_0",
                nil,
                1,
                0
            )
            A.truthy(ok)
            A.eq(mi, 1)
            A.eq(recipe.snapshot("gtceu:lv_input_bus_0").items["gtceu:aluminium_dust"], 1)
            A.eq(recipe.snapshot("gtceu:hv_buffer_1").items["gtceu:aluminium_dust"], 3)
        end,
    },
    {
        name = "pickTarget completes pair then opens next empty",
        fn = function()
            local states = {
                [0] = { index = 0, inflight = 0, paired = 2 },
                [1] = { index = 1, inflight = 0, paired = 2 },
                [2] = { index = 2, inflight = 0, paired = 2 },
            }
            local list = furnace.listByIndex(states)
            local a, rr = furnace.pickTarget(states, 6, list, 1)
            A.eq(a.index, 0)
            states[0].inflight = 1
            local b, rr2 = furnace.pickTarget(states, 6, list, rr)
            A.eq(b.index, 0)
            states[0].inflight = 2
            local c = furnace.pickTarget(states, 6, list, rr2)
            A.eq(c.index, 1)
        end,
    },
    {
        name = "isNonEmpty sees dust and nitrogen",
        fn = function()
            stub.reset()
            stub.install()
            addInv("gtceu:hv_buffer_1", {})
            A.falsy(recipe.isNonEmpty("gtceu:hv_buffer_1"))
            addTankInv("gtceu:hv_buffer_2", {
                [1] = { name = "gtceu:aluminium_dust", count = 1 },
            }, {
                { name = "gtceu:nitrogen", amount = 100 },
            })
            A.truthy(recipe.isNonEmpty("gtceu:hv_buffer_2"))
        end,
    },
    {
        name = "packHatchStatus empty busy err",
        fn = function()
            stub.reset()
            stub.install()
            addInv("gtceu:lv_input_bus_0", {})
            addTankInv("gtceu:ev_input_hatch_4x_0", {}, {})
            addInv("gtceu:lv_output_bus_0", {})
            addTankInv("gtceu:lv_output_hatch_0", {}, {})
            local st = furnace.newState({
                index = 0,
                inputBus = "gtceu:lv_input_bus_0",
                inputHatch = "gtceu:ev_input_hatch_4x_0",
                outputBus = "gtceu:lv_output_bus_0",
                outputHatch = "gtceu:lv_output_hatch_0",
            })
            A.eq(furnace.packHatchStatus(st), "empty")
            A.truthy(furnace.isCompletePack(st))

            -- Item without fluid = warn_item.
            addInv("gtceu:lv_input_bus_0", {
                [1] = { name = "gtceu:aluminium_dust", count = 1 },
            })
            A.eq(furnace.packHatchStatus(st), "warn_item")

            addTankInv("gtceu:ev_input_hatch_4x_0", {}, {
                { name = "gtceu:nitrogen", amount = 500 },
            })
            A.eq(furnace.packHatchStatus(st), "busy")
        end,
    },
    {
        name = "packHatchStatus fluid without dust is warn_fluid",
        fn = function()
            stub.reset()
            stub.install()
            addInv("gtceu:lv_input_bus_0", {})
            addTankInv("gtceu:ev_input_hatch_4x_0", {}, {
                { name = "gtceu:nitrogen", amount = 10 },
            })
            addInv("gtceu:lv_output_bus_0", {})
            addTankInv("gtceu:lv_output_hatch_0", {}, {})
            local st = furnace.newState({
                index = 0,
                inputBus = "gtceu:lv_input_bus_0",
                inputHatch = "gtceu:ev_input_hatch_4x_0",
                outputBus = "gtceu:lv_output_bus_0",
                outputHatch = "gtceu:lv_output_hatch_0",
            })
            A.eq(furnace.packHatchStatus(st), "warn_fluid")
        end,
    },
    {
        name = "packHatchStatus truly empty is empty",
        fn = function()
            stub.reset()
            stub.install()
            addInv("gtceu:lv_input_bus_0", {})
            addTankInv("gtceu:ev_input_hatch_4x_0", {}, {})
            addInv("gtceu:lv_output_bus_0", {})
            addTankInv("gtceu:lv_output_hatch_0", {}, {})
            local st = furnace.newState({
                index = 0,
                inputBus = "gtceu:lv_input_bus_0",
                inputHatch = "gtceu:ev_input_hatch_4x_0",
                outputBus = "gtceu:lv_output_bus_0",
                outputHatch = "gtceu:lv_output_hatch_0",
            })
            A.eq(furnace.packHatchStatus(st), "empty")
        end,
    },
    {
        name = "packHatchStatus ignores programmable circuit in bus",
        fn = function()
            stub.reset()
            stub.install()
            addInv("gtceu:lv_input_bus_0", {
                [5] = { name = "gtceu:programmable_circuit", count = 1 },
            })
            addTankInv("gtceu:ev_input_hatch_4x_0", {}, {})
            addInv("gtceu:lv_output_bus_0", {})
            addTankInv("gtceu:lv_output_hatch_0", {}, {})
            local st = furnace.newState({
                index = 0,
                inputBus = "gtceu:lv_input_bus_0",
                inputHatch = "gtceu:ev_input_hatch_4x_0",
                outputBus = "gtceu:lv_output_bus_0",
                outputHatch = "gtceu:lv_output_hatch_0",
            })
            A.eq(furnace.packHatchStatus(st), "empty")
            A.eq(furnace.bufferedUnits(st, 1), 0)
        end,
    },
    {
        name = "packHatchStatus missing fluid in hatch is err",
        fn = function()
            stub.reset()
            stub.install()
            addInv("gtceu:lv_input_bus_0", {})
            addInv("gtceu:lv_output_bus_0", {})
            addTankInv("gtceu:lv_output_hatch_0", {}, {})
            local st = furnace.newState({
                index = 0,
                inputBus = "gtceu:lv_input_bus_0",
                inputHatch = nil,
                outputBus = "gtceu:lv_output_bus_0",
                outputHatch = "gtceu:lv_output_hatch_0",
            })
            A.eq(furnace.packHatchStatus(st), "err_no_fluid_in")
            A.falsy(furnace.isCompletePack(st))
        end,
    },
    {
        name = "packHatchStatus missing item out hatch is err",
        fn = function()
            stub.reset()
            stub.install()
            addInv("gtceu:lv_input_bus_0", {})
            addTankInv("gtceu:ev_input_hatch_4x_0", {}, {})
            addTankInv("gtceu:lv_output_hatch_0", {}, {})
            local st = furnace.newState({
                index = 0,
                inputBus = "gtceu:lv_input_bus_0",
                inputHatch = "gtceu:ev_input_hatch_4x_0",
                outputBus = nil,
                outputHatch = "gtceu:lv_output_hatch_0",
            })
            A.eq(furnace.packHatchStatus(st), "err_no_item_out")
        end,
    },
    {
        name = "hotFillPercent uses stack 16 not 64",
        fn = function()
            stub.reset()
            stub.install()
            local inv = stub.makeInventory({
                [1] = {
                    name = "gtceu:hot_aluminium_ingot",
                    count = 8,
                    detail = {
                        name = "gtceu:hot_aluminium_ingot",
                        count = 8,
                        maxCount = 16,
                    },
                },
            })
            -- 1 slot * 16 = 50% (hot ingots, not *64)
            inv.size = function()
                return 1
            end
            stub.addPeripheral("gtceu:hv_buffer_0", inv)
            A.eq(furnace.hotFillPercent("gtceu:hv_buffer_0"), 50)
            A.isNil(furnace.hotFillPercent("missing"))
        end,
    },
    {
        name = "pushRecipeUnits batches single-item stack",
        fn = function()
            stub.reset()
            stub.install()
            addInv("gtceu:hv_buffer_1", {
                [1] = { name = "gtceu:aluminium_dust", count = 5 },
            })
            addInv("gtceu:lv_input_bus_0", {})

            local ok, units, mi = recipe.pushRecipeUnits(
                "gtceu:hv_buffer_1",
                "gtceu:lv_input_bus_0",
                nil,
                1,
                0,
                4,
                true
            )
            A.truthy(ok)
            A.eq(units, 4)
            A.eq(mi, 4)
            A.eq(recipe.snapshot("gtceu:lv_input_bus_0").items["gtceu:aluminium_dust"], 4)
            A.eq(recipe.snapshot("gtceu:hv_buffer_1").items["gtceu:aluminium_dust"], 1)
        end,
    },
    {
        name = "pushRecipeUnits moves nitrogen with dust (AE one-recipe lock)",
        fn = function()
            stub.reset()
            stub.install()
            addTankInv("gtceu:hv_buffer_1", {
                [1] = { name = "gtceu:aluminium_dust", count = 1 },
            }, {
                { name = "gtceu:nitrogen", amount = 1000 },
            })
            addInv("gtceu:lv_input_bus_0", {})
            addTankInv("gtceu:ev_input_hatch_4x_0", {}, {})

            local ok, units, mi, mf, err = recipe.pushRecipeUnits(
                "gtceu:hv_buffer_1",
                "gtceu:lv_input_bus_0",
                "gtceu:ev_input_hatch_4x_0",
                1,
                0,
                8,
                true -- skip flag must not drop fluids
            )
            A.truthy(ok, err)
            A.eq(units, 1)
            A.eq(mi, 1)
            A.eq(mf, 1000)
            A.truthy(recipe.isEmpty(recipe.snapshot("gtceu:hv_buffer_1")))
            A.eq(recipe.snapshot("gtceu:lv_input_bus_0").items["gtceu:aluminium_dust"], 1)
            A.eq(recipe.snapshot("gtceu:ev_input_hatch_4x_0").fluids["gtceu:nitrogen"], 1000)
        end,
    },
    {
        name = "feed completes L/R pair on same hatch before next",
        fn = function()
            stub.reset()
            stub.install()
            addInv("gtceu:hv_buffer_1", {
                [1] = { name = "gtceu:aluminium_dust", count = 2 },
            })
            addInv("gtceu:lv_input_bus_0", {})
            addInv("gtceu:lv_output_bus_0", {})
            addInv("gtceu:lv_input_bus_1", {})
            addInv("gtceu:lv_output_bus_1", {})

            local states = {
                [0] = furnace.newState({
                    index = 0,
                    id = "ebf_0",
                    inputBus = "gtceu:lv_input_bus_0",
                    outputBus = "gtceu:lv_output_bus_0",
                }),
                [1] = furnace.newState({
                    index = 1,
                    id = "ebf_1",
                    inputBus = "gtceu:lv_input_bus_1",
                    outputBus = "gtceu:lv_output_bus_1",
                }),
            }

            local a = furnace.feedOne(states, "gtceu:hv_buffer_1", 6)
            A.truthy(a)
            A.eq(a.index, 0)
            A.eq(states[0].inflight, 1)

            local b = furnace.feedOne(states, "gtceu:hv_buffer_1", 6)
            A.truthy(b)
            A.eq(b.index, 0)
            A.eq(states[0].inflight, 2)
            A.eq(states[1].inflight, 0)
            A.eq(recipe.snapshot("gtceu:lv_input_bus_0").items["gtceu:aluminium_dust"], 2)
        end,
    },
    {
        name = "AE refill after snap push still counts success",
        fn = function()
            stub.reset()
            stub.install()
            addInv("gtceu:hv_buffer_1", {
                [1] = { name = "gtceu:aluminium_dust", count = 1 },
            })
            addInv("gtceu:lv_input_bus_0", {})
            addInv("gtceu:lv_output_bus_0", {})

            local snap = recipe.snapshot("gtceu:hv_buffer_1")
            -- Simulate AE dropping the next recipe into the buffer mid-push:
            -- after we move the snapshotted stack, refill appears.
            local buf = peripheral.wrap("gtceu:hv_buffer_1")
            local origPush = buf.pushItems
            buf.pushItems = function(toName, fromSlot, limit, toSlot)
                local moved = origPush(toName, fromSlot, limit, toSlot)
                -- Refill while transfer runs.
                buf._receive("gtceu:aluminium_dust", 1)
                return moved
            end

            local ok, mi, _, err = recipe.pushAtomic(
                "gtceu:hv_buffer_1",
                "gtceu:lv_input_bus_0",
                nil,
                snap
            )
            A.truthy(ok, err)
            A.eq(mi, 1)
            -- Leftover refill stays for the next furnace cycle.
            A.eq(recipe.snapshot("gtceu:hv_buffer_1").items["gtceu:aluminium_dust"], 1)
            A.eq(recipe.snapshot("gtceu:lv_input_bus_0").items["gtceu:aluminium_dust"], 1)
        end,
    },
    {
        name = "second feed completes pair on same pack",
        fn = function()
            stub.reset()
            stub.install()
            addInv("gtceu:hv_buffer_1", {
                [1] = { name = "gtceu:aluminium_dust", count = 1 },
            })
            addInv("gtceu:lv_input_bus_0", {})
            addInv("gtceu:lv_output_bus_0", {})
            addInv("gtceu:lv_input_bus_1", {})
            addInv("gtceu:lv_output_bus_1", {})

            local states = {
                [0] = furnace.newState({
                    index = 0,
                    id = "ebf_0",
                    inputBus = "gtceu:lv_input_bus_0",
                    outputBus = "gtceu:lv_output_bus_0",
                }),
                [1] = furnace.newState({
                    index = 1,
                    id = "ebf_1",
                    inputBus = "gtceu:lv_input_bus_1",
                    outputBus = "gtceu:lv_output_bus_1",
                }),
            }
            states[0].inflight = 1

            local st = furnace.feedOne(states, "gtceu:hv_buffer_1", 6)
            A.truthy(st)
            A.eq(st.index, 0)
            A.eq(states[0].inflight, 2)
            A.eq(states[1].inflight, 0)
            A.eq(recipe.snapshot("gtceu:lv_input_bus_0").items["gtceu:aluminium_dust"], 1)
        end,
    },
})
