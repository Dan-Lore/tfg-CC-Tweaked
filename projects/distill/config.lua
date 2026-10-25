-- Load distill.cfg (defaults if file missing).
-- `config` is project-local (distill/); deploy one bundle per computer.

local util = require("util")
local cfg_pipe = require("cfg_pipe")

local config = {}

local function defaults()
    return {
        tower = "gtceu:distillation_tower_0",
        tower_substr = "distillation_tower",
        tank_substr = "super_tank",
        tank_also = "quantum_tank",
        monitor = "top",

        threshold_low = 0.12,
        threshold_high = 0.18,

        smart_maintain = true,
        cycles_low = 100,
        cycles_high = 160,
        min_ratio = 0.08,
        max_ratio = 0.30,
        hyst_min = 0.05,

        cooldown = 90,
        min_run = 110,
        emergency_frac = 0.40,

        recipe_output = {
            carbon_dioxide = 80000,
            nitrogen = 7000,
            argon = 5000,
            oxygen = 3000,
            krypton = 1000,
            neon = 1000,
            xenon = 1000,
        },
        fluid_ratio = {
            krypton = { low = 0.015, high = 0.02 },
            neon = { low = 0.015, high = 0.02 },
            xenon = { low = 0.015, high = 0.02 },
        },
        tank_index_ratio = {},

        poll = 2,
        boot_wait = 120,
        boot_poll = 2,

        -- GT Super/Quantum tank: 4000 * 1000 * 2^(tier-1) mB (GTCEu Modern)
        tier_base_mb = 4000 * 1000,
        tier_from_name = {
            ulv = 0, lv = 1, mv = 2, hv = 3, ev = 4, iv = 5,
            luv = 6, zpm = 7, uv = 8, uhv = 9, uev = 10, uiv = 11,
            uxv = 12, opv = 13, max = 14,
        },
    }
end

local function setNumber(cfg, key, raw, lineNo)
    local n = tonumber(raw)
    if not n then
        error(("distill.cfg line %s: %s needs a number"):format(tostring(lineNo), key))
    end
    cfg[key] = n
end

local function parseBool(raw, lineNo, key)
    raw = util.trim(tostring(raw or "")):lower()
    if raw == "true" or raw == "1" or raw == "yes" or raw == "on" then
        return true
    end
    if raw == "false" or raw == "0" or raw == "no" or raw == "off" then
        return false
    end
    error(("distill.cfg line %s: %s needs true/false"):format(tostring(lineNo), key))
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
        error(("distill.cfg line %s: empty key"):format(tostring(lineNo)))
    end

    if key == "recipe_output" or key == "recipe" then
        local fluid = util.trim(parts[2] or "")
        local mb = tonumber(parts[3])
        if fluid == "" or not mb then
            error(("distill.cfg line %s: recipe_output | <fluid> | <mB>"):format(tostring(lineNo)))
        end
        cfg.recipe_output[fluid] = mb
        return
    end

    if key == "fluid_ratio" or key == "fluid_ratio_override" then
        local fluid = util.trim(parts[2] or "")
        local low = tonumber(parts[3])
        local high = tonumber(parts[4])
        if fluid == "" or not low or not high then
            error(("distill.cfg line %s: fluid_ratio | <fluid> | <low> | <high>"):format(tostring(lineNo)))
        end
        cfg.fluid_ratio[fluid] = { low = low, high = high }
        return
    end

    if key == "tank_index_ratio" then
        local idx = tonumber(parts[2])
        local low = tonumber(parts[3])
        local high = tonumber(parts[4])
        if not idx or not low or not high then
            error(("distill.cfg line %s: tank_index_ratio | <index> | <low> | <high>"):format(tostring(lineNo)))
        end
        cfg.tank_index_ratio[idx] = { low = low, high = high }
        return
    end

    if val == nil or val == "" then
        error(("distill.cfg line %s: %s | value"):format(tostring(lineNo), key))
    end

    if key == "tower" or key == "tower_name" then
        cfg.tower = val
    elseif key == "tower_substr" then
        cfg.tower_substr = val
    elseif key == "tank_substr" then
        cfg.tank_substr = val
    elseif key == "tank_also" then
        cfg.tank_also = val
    elseif key == "monitor" then
        cfg.monitor = val
    elseif key == "threshold_low" then
        setNumber(cfg, "threshold_low", val, lineNo)
    elseif key == "threshold_high" then
        setNumber(cfg, "threshold_high", val, lineNo)
    elseif key == "smart_maintain" then
        cfg.smart_maintain = parseBool(val, lineNo, key)
    elseif key == "cycles_low" then
        setNumber(cfg, "cycles_low", val, lineNo)
    elseif key == "cycles_high" then
        setNumber(cfg, "cycles_high", val, lineNo)
    elseif key == "min_ratio" then
        setNumber(cfg, "min_ratio", val, lineNo)
    elseif key == "max_ratio" then
        setNumber(cfg, "max_ratio", val, lineNo)
    elseif key == "hyst_min" then
        setNumber(cfg, "hyst_min", val, lineNo)
    elseif key == "cooldown" or key == "cooldown_sec" then
        setNumber(cfg, "cooldown", val, lineNo)
    elseif key == "min_run" or key == "min_run_sec" then
        setNumber(cfg, "min_run", val, lineNo)
    elseif key == "emergency_frac" then
        setNumber(cfg, "emergency_frac", val, lineNo)
    elseif key == "poll" or key == "poll_sec" then
        setNumber(cfg, "poll", val, lineNo)
    elseif key == "boot_wait" or key == "boot_wait_sec" then
        setNumber(cfg, "boot_wait", val, lineNo)
    elseif key == "boot_poll" or key == "boot_poll_sec" then
        setNumber(cfg, "boot_poll", val, lineNo)
    elseif key == "tier_base_mb" then
        setNumber(cfg, "tier_base_mb", val, lineNo)
    else
        error(("distill.cfg line %s: unknown key %q"):format(tostring(lineNo), key))
    end
end

--- Load distill.cfg next to the program; missing file → defaults.
function config.load(path)
    local cfg = defaults()
    local lines, resolved, ok = cfg_pipe.loadLines(path, "distill.cfg")
    if not ok then
        return cfg, resolved, false
    end
    for n = 1, #lines do
        parseLine(cfg, lines[n], n)
    end
    return cfg, resolved, true
end

return config
