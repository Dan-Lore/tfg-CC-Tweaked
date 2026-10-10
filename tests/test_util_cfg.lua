#!/usr/bin/env lua
local boot = loadfile("tests/loader.lua")()
local T = boot()
local A = T.assert

local util = require("util")

A.suite("util_cfg", {
    {
        name = "trim and split",
        fn = function()
            A.eq(util.trim("  ab  "), "ab")
            local parts = util.split("a|b|c", "|")
            A.eq(#parts, 3)
            A.eq(parts[2], "b")
        end,
    },
    {
        name = "cfgSectionLines extracts section",
        fn = function()
            T.stub.writeFile("/tests/app.cfg", [[
# header
[storage]
main | fridge
overflow | crate

[recipes]
m_1 | a 1 | b 1 | processing
]])
            local storageLines = util.cfgSectionLines("/tests/app.cfg", "storage")
            A.truthy(storageLines)
            A.truthy(#storageLines >= 2)
            local joined = table.concat(storageLines, "\n")
            A.truthy(joined:find("main | fridge", 1, true))
            A.falsy(joined:find("processing", 1, true))

            local recipesLines = util.cfgSectionLines("/tests/app.cfg", "recipes")
            A.truthy(table.concat(recipesLines, "\n"):find("processing", 1, true))
        end,
    },
    {
        name = "openConfigLines prefers program.cfg section",
        fn = function()
            T.stub.setRunningProgram("/tests/pizza_maintain.lua")
            T.stub.writeFile("/tests/pizza_maintain.cfg", [[
[storage]
main | fridge_pm

[recipes]
m_1 | a 1 | b 1 | processing
]])
            local lines, label = util.openConfigLines(nil, "storage", "storage.cfg")
            A.truthy(label:find("pizza_maintain.cfg", 1, true))
            A.truthy(table.concat(lines, "\n"):find("fridge_pm", 1, true))
        end,
    },
    {
        name = "openConfigLines fallback file",
        fn = function()
            T.stub.setRunningProgram("/tests/unknown_prog.lua")
            T.stub.writeFile("/tests/storage.cfg", "main | fallback_main\n")
            local lines = util.openConfigLines(nil, "storage", "storage.cfg")
            A.truthy(table.concat(lines, "\n"):find("fallback_main", 1, true))
        end,
    },
    {
        name = "short and clamp",
        fn = function()
            A.eq(util.short("mod:path/leaf"), "leaf")
            A.eq(util.clamp(5, 1, 3), 3)
            A.eq(util.clamp(0, 1, 3), 1)
        end,
    },
})
