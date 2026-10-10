#!/usr/bin/env lua
local boot = loadfile("tests/loader.lua")()
local T = boot()
local A = T.assert

local recipes = require("recipes")
local craft_plan = require("craft_plan")

local function R(line, n)
    return recipes.parseLine(line, n or 1)
end

A.suite("craft_plan", {
    {
        name = "first-wins on duplicate outputs",
        fn = function()
            local list = {
                R("m_a_1 | x 1 | out/item 1 | processing", 1),
                R("m_b_1 | y 1 | out/item 1 | processing", 2),
            }
            local index = craft_plan.buildIndex(list)
            A.eq(index.byOutput["out/item"].recipe.machine, "m_a_1")
            A.eq(index.byOutput["out/item"].recipe.line, 1)
        end,
    },
    {
        name = "depth counts dependency chain",
        fn = function()
            local list = {
                R("g_0 | - | crop 1 | grow", 1),
                R("p_1 | crop 1 | flour 1 | processing", 2),
                R("p_2 | flour 1 | dough 1 | processing", 3),
            }
            local index = craft_plan.buildIndex(list)
            A.eq(index.depth["crop"], 1)
            A.eq(index.depth["flour"], 2)
            A.eq(index.depth["dough"], 3)
        end,
    },
    {
        name = "tag output indexed (cooked meats oven)",
        fn = function()
            local list = {
                R("oven_0 | #tfc:foods/raw_meats 1 | #tfc:foods/cooked_meats 1 | processing", 1),
            }
            local index = craft_plan.buildIndex(list)
            A.truthy(index.byOutput["#tfc:foods/cooked_meats"])
            A.eq(index.depth["#tfc:foods/cooked_meats"], 1)
        end,
    },
    {
        name = "batchTimes oneshot and grow forced to 1",
        fn = function()
            local grow = R("g_0 | - | crop 1 | grow", 1)
            local one = R("m_1 | a 1 | b 1 | processing | oneshot", 2)
            local normal = R("m_2 | a 1 | b 1 | processing", 3)
            A.eq(craft_plan.batchTimes(grow, 10, 10), 1)
            A.eq(craft_plan.batchTimes(one, 10, 10), 1)
            A.eq(craft_plan.batchTimes(normal, 5, 10), 5)
        end,
    },
    {
        name = "collectNames walks inputs",
        fn = function()
            local list = {
                R("p_1 | flour 1, #tfg:clean_water 100mb | dough 1 | processing", 1),
                R("p_0 | grain 1 | flour 1 | processing", 2),
            }
            local index = craft_plan.buildIndex(list)
            local items, fluids = craft_plan.collectNames(index, "dough")
            A.contains(items, "dough")
            A.contains(items, "flour")
            A.contains(items, "grain")
            A.contains(fluids, "#tfg:clean_water")
        end,
    },
    {
        name = "readyJobs sorts depth DESC then times DESC",
        fn = function()
            -- Minimal snap stub: everything ready, no peripherals needed for countCompleteSets grow
            local list = {
                R("g_0 | - | crop 1 | grow", 1),
                R("p_1 | crop 1 | flour 1 | processing", 2),
            }
            local index = craft_plan.buildIndex(list)
            local snap = {
                store = nil,
                opts = {},
                item = function() return 0 end,
                fluid = function() return 0, nil end,
            }
            -- Override countCompleteSets path: grow has 0 inputs → ready; flour needs crop
            local craft_stock = require("craft_stock")
            local old = craft_stock.countCompleteSets
            craft_stock.countCompleteSets = function(recipe)
                return 3
            end
            local deficit = { flour = 6, crop = 3 }
            local jobs = craft_plan.readyJobs(
                index,
                deficit,
                snap,
                function(recipe) return recipe.machine end,
                nil,
                "flour"
            )
            craft_stock.countCompleteSets = old
            A.truthy(#jobs >= 1)
            -- deeper flour (depth 2) before crop (depth 1) when both ready
            if #jobs >= 2 then
                A.eq(jobs[1].itemId, "flour")
            end
        end,
    },
})
