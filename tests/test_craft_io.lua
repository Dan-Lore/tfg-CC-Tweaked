#!/usr/bin/env lua
local boot = loadfile("tests/loader.lua")()
local T = boot()
local A = T.assert

local recipes = require("recipes")
local storage = require("storage")
local transfer = require("transfer")
local craft_io = require("craft_io")

local STORAGE_CFG = [[
main | fridge
overflow | overflow
fluid_source | #tfg:clean_water | water_tank | minecraft:water
]]

local function loadStore()
    T.stub.writeFile("/tests/storage.cfg", STORAGE_CFG)
    T.stub.setRunningProgram("/tests/program.lua")
    T.stub.addPeripheral("fridge", T.stub.makeInventory({
        [1] = { name = "tfc:food/wheat_flour", count = 10 },
    }))
    T.stub.addPeripheral("overflow", T.stub.makeInventory({}))
    T.stub.addPeripheral("water_tank", T.stub.makeTank({
        { name = "minecraft:water", amount = 1000 },
    }))
    local machInv = T.stub.makeInventory({})
    local machTank = T.stub.makeTank({})
    for k, v in pairs(machTank) do
        if k ~= "_type" then
            machInv[k] = v
        end
    end
    T.stub.addPeripheral("machine", machInv)
    return storage.load("storage.cfg")
end

A.suite("craft_io", {
    {
        name = "buildNeedMap counts item and fluid outputs",
        fn = function()
            local need, anyItem, fluidKeys, anyFluid = craft_io.buildNeedMap({
                { name = "item/a", count = 2, fluid = false },
                { name = "fluid/b", count = 100, fluid = true },
            }, 3)
            A.truthy(anyItem)
            A.truthy(anyFluid)
            A.eq(need["item/a"], 6)
            A.eq(need["fluid/b"], 300)
            A.truthy(fluidKeys["fluid/b"])
            A.falsy(fluidKeys["item/a"])
        end,
    },
    {
        name = "rollbackFluids returns fluid to source tank",
        fn = function()
            local store = loadStore()
            local machine = peripheral.wrap("machine")
            machine._receiveFluid("minecraft:water", 100)
            craft_io.rollbackFluids("machine", { ["#tfg:clean_water"] = 100 }, store)
            A.eq(transfer.countFluid("water_tank", "minecraft:water"), 1100)
            A.eq(transfer.countFluid("machine", "minecraft:water"), 0)
        end,
    },
    {
        name = "setAvailable detects missing fluid source",
        fn = function()
            local store = loadStore()
            local recipe = recipes.parseLine(
                "machine | #missing_fluid 50mb | out 1 | processing",
                1
            )
            local ok, missing = craft_io.setAvailable(recipe, store, {})
            A.falsy(ok)
            A.eq(missing.error, "no_fluid_source")
        end,
    },
    {
        name = "pushOneSet refuses when stock short (no move)",
        fn = function()
            local store = loadStore()
            local recipe = recipes.parseLine(
                "machine | tfc:food/wheat_flour 5, #tfg:clean_water 100mb | tfc:food/wheat_dough 4 | processing",
                1
            )
            -- only 10 flour but wait - 5 is available. Use 50.
            recipe = recipes.parseLine(
                "machine | tfc:food/wheat_flour 50 | tfc:food/wheat_dough 4 | processing",
                1
            )
            local ok, _moved, missing = craft_io.pushOneSet(recipe, "machine", store, {
                from = "fridge",
                out = "fridge",
            })
            A.falsy(ok)
            A.eq(missing.name, "tfc:food/wheat_flour")
            A.eq(transfer.countItem("fridge", "tfc:food/wheat_flour"), 10)
        end,
    },
    {
        name = "pushOneSet success drains flour and water",
        fn = function()
            local store = loadStore()
            local recipe = recipes.parseLine(
                "machine | tfc:food/wheat_flour 2, #tfg:clean_water 100mb | tfc:food/wheat_dough 4 | processing",
                1
            )
            local ok, moved, missing = craft_io.pushOneSet(recipe, "machine", store, {
                from = "fridge",
                out = "fridge",
            })
            A.truthy(ok, missing and (missing.error or missing.name))
            A.isNil(missing)
            A.eq(moved["tfc:food/wheat_flour"], 2)
            A.eq(moved["#tfg:clean_water"], 100)
            A.eq(transfer.countItem("fridge", "tfc:food/wheat_flour"), 8)
            A.eq(transfer.countFluid("water_tank", "minecraft:water"), 900)
        end,
    },
})
