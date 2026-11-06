#!/usr/bin/env lua
local boot = loadfile("tests/loader.lua")()
local T = boot({ projects = { "fluid_feed", "shared" } })
local A = T.assert
local stub = T.stub

-- Prefer fluid_feed/ over other projects that also ship config/discover/move.
do
    local root = T.root
    package.path = table.concat({
        root .. "/projects/fluid_feed/?.lua",
        root .. "/projects/shared/?.lua",
        root .. "/tests/?.lua",
        package.path,
    }, ";")
    for _, name in ipairs({ "config", "discover", "move", "ui", "main" }) do
        package.loaded[name] = nil
    end
end

local move = require("move")

local function addTank(name, fluids)
    stub.addPeripheral(name, stub.makeTank(fluids or {}))
end

A.suite("fluid_feed.move", {
    {
        name = "empty hatch gets exactly amount; non-empty skipped",
        fn = function()
            stub.reset()
            stub.install()
            addTank("buf", {
                { name = "gtceu:iron", amount = 500 },
                { name = "gtceu:copper", amount = 500 },
            })
            addTank("h0", {})
            addTank("h1", { { name = "gtceu:tin", amount = 50 } })
            addTank("h2", {})

            local state = { fluidRR = 0, hatchRR = 0 }
            local pushed = move.distribute("buf", { "h0", "h1", "h2" }, 144, state)
            A.eq(pushed, 2)
            A.eq(move.totalFluid("h0"), 144)
            A.eq(move.totalFluid("h1"), 50)
            A.eq(move.totalFluid("h2"), 144)
            local t0 = peripheral.wrap("h0").tanks()
            local t2 = peripheral.wrap("h2").tanks()
            A.truthy(t0[1] and t0[1].name)
            A.truthy(t2[1] and t2[1].name)
            A.truthy(t0[1].name ~= t2[1].name)
        end,
    },
    {
        name = "hatchStats ok/empty/bad",
        fn = function()
            stub.reset()
            stub.install()
            addTank("ok", { { name = "gtceu:iron", amount = 144 } })
            addTank("empty", {})
            addTank("bad", { { name = "gtceu:iron", amount = 50 } })
            local okN, emptyN, badN = move.hatchStats({ "ok", "empty", "bad" }, 144)
            A.eq(okN, 1)
            A.eq(emptyN, 1)
            A.eq(badN, 1)
        end,
    },
    {
        name = "eligibleFluids requires min amount",
        fn = function()
            stub.reset()
            stub.install()
            addTank("buf", {
                { name = "gtceu:iron", amount = 143 },
                { name = "gtceu:copper", amount = 144 },
            })
            local fluids = move.eligibleFluids("buf", 144)
            A.eq(#fluids, 1)
            A.eq(fluids[1], "gtceu:copper")
        end,
    },
})

print("ok")
