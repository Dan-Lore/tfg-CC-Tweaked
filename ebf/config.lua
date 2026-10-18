-- Load ebf.cfg into the table main/discover expect.
-- `config` is project-local (ebf/); deploy one bundle per computer.

local util = require("util")
local cfg_pipe = require("cfg_pipe")

local config = {}

local function defaults()
    return {
        recipe_buffer_prefix = "gtceu:hv_buffer",
        recipe_buffer_min = 1,
        hot_sink = "gtceu:hv_buffer_0",
        ae_sink = "ae2:pattern_provider_5",
        monitor = "top",

        input_bus_prefix = "gtceu:lv_input_bus",
        input_hatch_prefix = "gtceu:ev_input_hatch_4x",
        output_bus_prefix = "gtceu:lv_output_bus",
        output_hatch_prefix = "gtceu:lv_output_hatch",

        -- Per hatch pack (furnaces NL+NR sharing hatches): 2 craft + buffer.
        max_inflight = 8,
        -- Item units per recipe when buffer holds a single item type (Al dust = 1).
        items_per_recipe = 1,
        -- Fluid mB per recipe (0 = scale with items_per_recipe / stack size).
        fluid_per_recipe = 0,
        poll = 0,
        max_furnaces = 0,
        -- Hot ingots pulled per finished recipe (EBF dust→ingot is usually 1).
        hot_per_recipe = 1,
        -- After input+output empty, keep up to `paired` sticky feeds this many
        -- seconds (L+R still crafting); then clear so missed drains do not stick.
        craft_grace = 8,
        -- Kept for cfg compat; pushes always read tanks (N2 with AE one-recipe lock).
        skip_fluids = false,
    }
end

local function setNumber(cfg, key, raw, lineNo)
    local n = tonumber(raw)
    if not n then
        error(("ebf.cfg line %s: %s needs a number"):format(tostring(lineNo), key))
    end
    cfg[key] = n
end

local function parseLine(cfg, line, lineNo)
    line = util.trim(line or "")
    if line == "" or line:sub(1, 1) == "#" then
        return
    end

    local parts = util.split(line, "|")
    for i = 1, #parts do
        parts[i] = util.trim(parts[i])
    end

    local key = (parts[1] or ""):lower()
    local val = parts[2]
    if key == "" then
        error(("ebf.cfg line %s: empty key"):format(tostring(lineNo)))
    end
    if val == nil or val == "" then
        error(("ebf.cfg line %s: %s | value"):format(tostring(lineNo), key))
    end

    if key == "recipe_buffer_prefix" then
        cfg.recipe_buffer_prefix = val
        return
    end
    if key == "recipe_buffer_min" then
        setNumber(cfg, "recipe_buffer_min", val, lineNo)
        return
    end
    if key == "hot_sink" then
        cfg.hot_sink = val
        return
    end
    if key == "ae_sink" then
        cfg.ae_sink = val
        return
    end
    if key == "monitor" then
        cfg.monitor = val
        return
    end
    if key == "input_bus_prefix" then
        cfg.input_bus_prefix = val
        return
    end
    if key == "input_hatch_prefix" then
        cfg.input_hatch_prefix = val
        return
    end
    if key == "output_bus_prefix" then
        cfg.output_bus_prefix = val
        return
    end
    if key == "output_hatch_prefix" then
        cfg.output_hatch_prefix = val
        return
    end
    if key == "max_inflight" then
        setNumber(cfg, "max_inflight", val, lineNo)
        return
    end
    if key == "poll" then
        setNumber(cfg, "poll", val, lineNo)
        return
    end
    if key == "max_furnaces" then
        setNumber(cfg, "max_furnaces", val, lineNo)
        return
    end
    if key == "hot_per_recipe" then
        setNumber(cfg, "hot_per_recipe", val, lineNo)
        return
    end
    if key == "items_per_recipe" then
        setNumber(cfg, "items_per_recipe", val, lineNo)
        return
    end
    if key == "fluid_per_recipe" then
        setNumber(cfg, "fluid_per_recipe", val, lineNo)
        return
    end
    if key == "craft_grace" then
        setNumber(cfg, "craft_grace", val, lineNo)
        return
    end
    if key == "skip_fluids" then
        local v = tostring(val):lower()
        cfg.skip_fluids = (v == "1" or v == "true" or v == "yes" or v == "on")
        return
    end
    error(("ebf.cfg line %s: unknown key %q"):format(tostring(lineNo), key))
end

--- Load ebf.cfg (next to the running program by default).
function config.load(path)
    local lines, resolved, ok = cfg_pipe.loadLines(path, "ebf.cfg")
    local cfg = defaults()
    if not ok then
        print("ebf: no ebf.cfg at " .. tostring(resolved) .. " — using defaults")
        return cfg, resolved, false
    end

    for n = 1, #lines do
        parseLine(cfg, lines[n], n)
    end
    return cfg, resolved, true
end

return config
