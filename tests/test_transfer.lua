#!/usr/bin/env lua
local boot = loadfile("tests/loader.lua")()
local T = boot()
local A = T.assert

local transfer = require("transfer")
require("food") -- register craft food tag/spoil helpers

A.suite("transfer", {
    {
        name = "exact id match",
        fn = function()
            A.truthy(transfer.matches("tfc:food/wheat", nil, "tfc:food/wheat"))
            A.falsy(transfer.matches("tfc:food/wheat", nil, "tfc:food/tomato"))
        end,
    },
    {
        name = "tag match via detail tags list",
        fn = function()
            A.truthy(transfer.matches(
                "tfc:food/cooked_beef",
                { "tfc:foods/cooked_meats" },
                "#tfc:foods/cooked_meats"
            ))
        end,
    },
    {
        name = "tag fallback raw/cooked meats",
        fn = function()
            A.truthy(transfer.matches("tfc:food/beef", nil, "#tfc:foods/raw_meats"))
            A.truthy(transfer.matches("tfc:food/cooked_beef", nil, "#tfc:foods/cooked_meats"))
            A.falsy(transfer.matches("tfc:food/cooked_egg", nil, "#tfc:foods/cooked_meats"))
            A.truthy(transfer.matches("tfg:food/magmango", nil, "#firmalife:foods/pizza_ingredients"))
        end,
    },
    {
        name = "isFoodItem namespaces",
        fn = function()
            A.truthy(transfer.isFoodItem("firmalife:food/cooked_pizza"))
            A.truthy(transfer.isFoodItem("firmalife:spice/basil_leaves"))
            A.falsy(transfer.isFoodItem("minecraft:stone"))
        end,
    },
    {
        name = "isSpoiled detects rotten/decay",
        fn = function()
            A.truthy(transfer.isSpoiled({ rotten = true }))
            A.truthy(transfer.isSpoiled({ decay = 1 }))
            A.truthy(transfer.isSpoiled({ food = { spoiled = true } }))
            A.truthy(transfer.isSpoiled({ displayName = "Rotten Pizza" }))
            A.falsy(transfer.isSpoiled({ name = "firmalife:food/cooked_pizza" }))
        end,
    },
    {
        name = "countItem tag skips spoiled via getItemDetail",
        fn = function()
            local inv = T.stub.makeInventory({
                [1] = {
                    name = "tfc:food/cooked_beef",
                    count = 5,
                    detail = { name = "tfc:food/cooked_beef", rotten = true },
                },
                [2] = {
                    name = "tfc:food/cooked_beef",
                    count = 3,
                    detail = {
                        name = "tfc:food/cooked_beef",
                        tags = { "tfc:foods/cooked_meats" },
                    },
                },
            })
            T.stub.addPeripheral("fridge", inv)
            local n = transfer.countItem("fridge", "#tfc:foods/cooked_meats")
            A.eq(n, 3)
        end,
    },
    {
        name = "exact food id skips spoiled stacks",
        fn = function()
            local inv = T.stub.makeInventory({
                [1] = {
                    name = "firmalife:food/cooked_pizza",
                    count = 4,
                    detail = { name = "firmalife:food/cooked_pizza", rotten = true },
                },
                [2] = {
                    name = "firmalife:food/cooked_pizza",
                    count = 2,
                    detail = { name = "firmalife:food/cooked_pizza" },
                },
            })
            T.stub.addPeripheral("fridge2", inv)
            local n = transfer.countItem("fridge2", "firmalife:food/cooked_pizza")
            A.eq(n, 2, "rotten pizza excluded when food module registered")
        end,
    },
    {
        name = "pushItems moves matching stacks",
        fn = function()
            local src = T.stub.makeInventory({
                [1] = { name = "tfc:food/wheat", count = 10 },
            })
            local dst = T.stub.makeInventory({})
            T.stub.addPeripheral("src", src)
            T.stub.addPeripheral("dst", dst)
            local n = transfer("src", "dst", "tfc:food/wheat", 7)
            A.eq(n, 7)
            A.eq(src._slots[1].count, 3)
        end,
    },
    {
        name = "fluid count and push",
        fn = function()
            local tank = T.stub.makeTank({ { name = "minecraft:water", amount = 500 } })
            local machine = T.stub.makeTank({})
            T.stub.addPeripheral("tank", tank)
            T.stub.addPeripheral("machine", machine)
            A.eq(transfer.countFluid("tank", "minecraft:water"), 500)
            local n = transfer.fluid("tank", "machine", "minecraft:water", 100)
            A.eq(n, 100)
            A.eq(transfer.countFluid("tank", "minecraft:water"), 400)
            A.eq(transfer.countFluid("machine", "minecraft:water"), 100)
        end,
    },
})
