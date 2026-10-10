#!/usr/bin/env lua
local boot = loadfile("tests/loader.lua")()
local T = boot()
local A = T.assert

local history = require("history")

A.suite("history", {
    {
        name = "add get latest",
        fn = function()
            -- now() = epoch_ms/1000; keep sample times near "now" so retain prune keeps them
            T.stub.setEpochMs(10000 * 1000) -- now = 10000s
            local h = history.new({ retain = 1000 })
            h:add("item:a", 10, 9900)
            h:add("item:a", 20, 9950)
            local pts = h:get("item:a")
            A.eq(#pts, 2)
            A.eq(pts[2].amount, 20)
            A.eq(h:latest("item:a").amount, 20)
        end,
    },
    {
        name = "near-duplicate timestamps overwrite",
        fn = function()
            T.stub.setEpochMs(10000 * 1000)
            local h = history.new({ retain = 1000 })
            h:add("item:b", 1, 9900)
            h:add("item:b", 2, 9900.2)
            A.eq(#h:get("item:b"), 1)
            A.eq(h:latest("item:b").amount, 2)
        end,
    },
    {
        name = "retain prunes old points",
        fn = function()
            T.stub.setEpochMs(2000 * 1000) -- now = 2000s
            local h = history.new({ retain = 100 })
            h:add("item:c", 1, 1000) -- too old (cutoff 1900)
            h:add("item:c", 2, 1950)
            local pts = h:get("item:c")
            A.eq(#pts, 1)
            A.eq(pts[1].amount, 2)
        end,
    },
    {
        name = "save and load roundtrip",
        fn = function()
            T.stub.setEpochMs(5000 * 1000)
            local h = history.new({ retain = 10000, path = "/tests/ae_hist" })
            h:add("item:x", 7, 4900)
            A.truthy(h:save())
            local h2 = history.new({ retain = 10000, path = "/tests/ae_hist" })
            A.truthy(h2:load())
            A.eq(h2:latest("item:x").amount, 7)
        end,
    },
    {
        name = "items sorted",
        fn = function()
            T.stub.setEpochMs(10000 * 1000)
            local h = history.new({ retain = 1000 })
            h:add("z", 1, 9900)
            h:add("a", 1, 9900)
            local keys = h:items()
            A.eq(keys[1], "a")
            A.eq(keys[2], "z")
        end,
    },
    {
        name = "max_series prunes oldest-touched keys",
        fn = function()
            T.stub.setEpochMs(10000 * 1000)
            local h = history.new({ retain = 10000, max_series = 2 })
            h:add("old", 1, 9000)
            h:add("mid", 1, 9500)
            h:add("new", 1, 9900)
            local keys = h:items()
            A.eq(#keys, 2)
            A.falsy((function()
                for i = 1, #keys do
                    if keys[i] == "old" then
                        return true
                    end
                end
                return false
            end)(), "oldest key dropped")
            A.contains(keys, "new")
            A.contains(keys, "mid")
        end,
    },
})
