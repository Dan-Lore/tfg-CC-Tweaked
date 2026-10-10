#!/usr/bin/env lua
local boot = loadfile("tests/loader.lua")()
local T = boot()
local A = T.assert

local storage = require("storage")

local SAMPLE = [[
main | fridge_main
overflow | overflow_crate
flora | flora_chest
source | #tfc:foods/raw_meats | fridge_meat
source | tfc:food/wheat | fridge_main
route | firmalife:spice/basil_leaves | overflow
fluid_source | #tfg:clean_water | water_tank | minecraft:water
seed | tfc:food/wheat | tfc:seeds/wheat
grow_pulse | 3
]]

A.suite("storage", {
    {
        name = "parse named / source / route / fluid / seed / settings",
        fn = function()
            T.stub.writeFile("/tests/storage.cfg", SAMPLE)
            T.stub.setRunningProgram("/tests/program.lua")
            T.stub.addPeripheral("fridge_main", T.stub.makeInventory())
            T.stub.addPeripheral("overflow_crate", T.stub.makeInventory())
            T.stub.addPeripheral("fridge_meat", T.stub.makeInventory())
            T.stub.addPeripheral("water_tank", T.stub.makeTank())

            local cfg = storage.load("storage.cfg")
            A.eq(cfg.main(), "fridge_main")
            A.eq(cfg.overflow(), "overflow_crate")
            A.eq(cfg.sourceOf("#tfc:foods/raw_meats"), "fridge_meat")
            A.eq(cfg.destFor("firmalife:spice/basil_leaves"), "overflow_crate")
            A.eq(cfg.destFor("tfc:food/wheat"), "fridge_main")
            local fi = cfg.fluidSourceOf("#tfg:clean_water")
            A.eq(fi.peripheral, "water_tank")
            A.eq(fi.fluid, "minecraft:water")
            A.eq(cfg.seedForCrop("tfc:food/wheat"), "tfc:seeds/wheat")
            A.eq(cfg.getNumber("grow_pulse", 0), 3)
            A.eq(cfg.seedDest(2), "gtceu:lv_super_chest_2")
            A.eq(cfg.outputBus(5), "gtceu:mv_output_bus_5")
        end,
    },
    {
        name = "pullSources order: explicit source, dest, main; overflow only when home",
        fn = function()
            T.stub.writeFile("/tests/storage.cfg", SAMPLE)
            T.stub.setRunningProgram("/tests/program.lua")
            T.stub.addPeripheral("fridge_main", T.stub.makeInventory())
            T.stub.addPeripheral("overflow_crate", T.stub.makeInventory())
            T.stub.addPeripheral("fridge_meat", T.stub.makeInventory())

            local cfg = storage.load("storage.cfg")
            local meat = cfg.pullSources("#tfc:foods/raw_meats")
            A.eq(meat[1], "fridge_meat")
            A.contains(meat, "fridge_main")

            local basil = cfg.pullSources("firmalife:spice/basil_leaves")
            A.contains(basil, "overflow_crate")
            A.contains(basil, "fridge_main")

            local wheat = cfg.pullSources("tfc:food/wheat")
            for i = 1, #wheat do
                A.neq(wheat[i], "overflow_crate", "wheat must not pull from overflow")
            end
        end,
    },
})
