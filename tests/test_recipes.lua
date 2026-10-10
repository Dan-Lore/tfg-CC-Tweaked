#!/usr/bin/env lua
local boot = loadfile("tests/loader.lua")()
local T = boot()
local A = T.assert

local recipes = require("recipes")

A.suite("recipes", {
    {
        name = "parse item stack and oneshot field",
        fn = function()
            local r = recipes.parseLine(
                "tfg:hv_food_processor_3 | firmalife:food/pizza_dough 1, #tfc:foods/cooked_meats 1 | firmalife:food/raw_pizza 1 | processing | oneshot",
                1
            )
            A.eq(r.machine, "tfg:hv_food_processor_3")
            A.eq(r.circuit, 3)
            A.eq(r.flag, "processing")
            A.truthy(r.oneshot)
            A.eq(#r.inputs, 2)
            A.eq(r.inputs[1].name, "firmalife:food/pizza_dough")
            A.eq(r.inputs[1].count, 1)
            A.falsy(r.inputs[1].fluid)
            A.eq(r.inputs[2].name, "#tfc:foods/cooked_meats")
            A.eq(r.outputs[1].name, "firmalife:food/raw_pizza")
        end,
    },
    {
        name = "parse fluid mb input",
        fn = function()
            local r = recipes.parseLine(
                "tfg:hv_food_processor_1 | tfc:food/wheat_flour 1, #tfg:clean_water 100mb | tfc:food/wheat_dough 4 | processing",
                2
            )
            A.eq(#r.inputs, 2)
            A.truthy(r.inputs[2].fluid)
            A.eq(r.inputs[2].count, 100)
            A.eq(r.inputs[2].name, "#tfg:clean_water")
            A.eq(r.outputs[1].count, 4)
            A.falsy(r.oneshot)
        end,
    },
    {
        name = "parse grow with empty inputs",
        fn = function()
            local r = recipes.parseLine(
                "tfg:hv_electric_greenhouse_0 | - | tfc:food/wheat 20 | grow",
                3
            )
            A.eq(r.flag, "grow")
            A.eq(#r.inputs, 0)
            A.eq(r.outputs[1].name, "tfc:food/wheat")
            A.eq(r.outputs[1].count, 20)
        end,
    },
    {
        name = "oneshot in flag field",
        fn = function()
            local r = recipes.parseLine(
                "m_1 | a 1 | b 1 | processing oneshot",
                4
            )
            A.truthy(r.oneshot)
        end,
    },
    {
        name = "comments and blanks skipped",
        fn = function()
            A.isNil(recipes.parseLine("# comment", 1))
            A.isNil(recipes.parseLine("", 2))
            A.isNil(recipes.parseLine("   ", 3))
        end,
    },
    {
        name = "load recipes.cfg from craft/",
        fn = function()
            T.stub.setRunningProgram("/craft/program.lua")
            -- map real file into stub fs via reading from disk
            local f = io.open(T.root .. "/craft/recipes.cfg", "r")
            A.truthy(f, "open craft/recipes.cfg")
            local text = f:read("*a")
            f:close()
            T.stub.writeFile("/craft/recipes.cfg", text)
            local list = recipes.load()
            A.truthy(#list > 5, "expected many recipes")
            local pizza = nil
            for i = 1, #list do
                for j = 1, #list[i].outputs do
                    if list[i].outputs[j].name == "firmalife:food/cooked_pizza" then
                        pizza = list[i]
                    end
                end
            end
            A.truthy(pizza, "cooked_pizza recipe present")
        end,
    },
    {
        name = "recipeKey uses machine and primary output",
        fn = function()
            local r = recipes.parseLine("m_2 | a 1 | out/item 3 | processing", 1)
            A.eq(recipes.recipeKey(r), "m_2|out/item")
        end,
    },
    {
        name = "findDuplicateOutputs and warn on load",
        fn = function()
            local warnings = {}
            recipes.warn = function(msg)
                warnings[#warnings + 1] = msg
            end
            T.stub.setRunningProgram("/tests/program.lua")
            T.stub.writeFile("/tests/recipes.cfg", [[
m_a_1 | x 1 | shared/out 1 | processing
m_b_1 | y 1 | shared/out 1 | processing
m_c_1 | z 1 | unique/out 1 | processing
]])
            local list = recipes.load("recipes.cfg")
            A.eq(#list, 3)
            local dups = recipes.findDuplicateOutputs(list)
            A.eq(#dups["shared/out"], 2)
            A.isNil(dups["unique/out"])
            A.eq(#warnings, 1)
            A.truthy(warnings[1]:find("shared/out", 1, true))
        end,
    },
})
