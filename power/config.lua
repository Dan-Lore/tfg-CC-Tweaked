-- Load power.cfg (defaults if file missing).

local util = require("util")

local config = {}

local function defaults()
    return {
        monitor = "left",
        text_scale = "auto", -- "auto" or number 0.5..5
        substation = nil,
        turbine_substr = "gas_large_turbine",
        engine_substr = "extreme_combustion_engine",
        substation_substr = "power_substation",
        threshold_low = 0.60,
        threshold_high = 0.90,
        threshold_critical = 0.95,
        threshold_warn = 0.75,
        threshold_emergency = 0.40,
        ramp_speed_pct = 60,
        drain_override_eut = -4000,
        cooldown = 20,
        measure_interval = 5,
        boot_wait = 120,
        boot_poll = 2,
        rotor_warn_pct = 20,
        max_history = 4,
    }
end

local function parseScale(raw)
    raw = util.trim(tostring(raw or "")):lower()
    if raw == "" or raw == "auto" then
        return "auto"
    end
    local n = tonumber(raw)
    if not n then
        return "auto"
    end
    -- CC monitors accept 0.5 .. 5.0 in 0.5 steps
    n = math.floor(n * 2 + 0.5) / 2
    return util.clamp(n, 0.5, 5)
end

local function setNumber(cfg, key, raw, lineNo)
    local n = tonumber(raw)
    if not n then
        error(("power.cfg line %s: %s needs a number"):format(tostring(lineNo), key))
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
        error(("power.cfg line %s: empty key"):format(tostring(lineNo)))
    end
    if val == nil or val == "" then
        error(("power.cfg line %s: %s | value"):format(tostring(lineNo), key))
    end

    if key == "monitor" then
        cfg.monitor = val
    elseif key == "text_scale" or key == "monitor_scale" then
        cfg.text_scale = parseScale(val)
    elseif key == "substation" then
        cfg.substation = val
    elseif key == "turbine_substr" then
        cfg.turbine_substr = val
    elseif key == "engine_substr" then
        cfg.engine_substr = val
    elseif key == "substation_substr" then
        cfg.substation_substr = val
    elseif key == "threshold_low" then
        setNumber(cfg, "threshold_low", val, lineNo)
    elseif key == "threshold_high" then
        setNumber(cfg, "threshold_high", val, lineNo)
    elseif key == "threshold_critical" then
        setNumber(cfg, "threshold_critical", val, lineNo)
    elseif key == "threshold_warn" then
        setNumber(cfg, "threshold_warn", val, lineNo)
    elseif key == "threshold_emergency" then
        setNumber(cfg, "threshold_emergency", val, lineNo)
    elseif key == "ramp_speed_pct" then
        setNumber(cfg, "ramp_speed_pct", val, lineNo)
    elseif key == "drain_override_eut" or key == "drain_override" then
        setNumber(cfg, "drain_override_eut", val, lineNo)
    elseif key == "cooldown" then
        setNumber(cfg, "cooldown", val, lineNo)
    elseif key == "measure_interval" then
        setNumber(cfg, "measure_interval", val, lineNo)
    elseif key == "boot_wait" then
        setNumber(cfg, "boot_wait", val, lineNo)
    elseif key == "boot_poll" then
        setNumber(cfg, "boot_poll", val, lineNo)
    elseif key == "rotor_warn_pct" then
        setNumber(cfg, "rotor_warn_pct", val, lineNo)
    else
        error(("power.cfg line %s: unknown key %q"):format(tostring(lineNo), key))
    end
end

--- Load power.cfg next to the program; missing file → defaults.
function config.load(path)
    local cfg = defaults()
    path = util.resolvePath(path, "power.cfg")
    if not fs.exists(path) then
        return cfg, path, false
    end

    local file = fs.open(path, "r")
    if not file then
        error("Cannot open " .. path, 2)
    end
    local n = 0
    while true do
        local line = file.readLine()
        if not line then
            break
        end
        n = n + 1
        parseLine(cfg, line, n)
    end
    file.close()
    return cfg, path, true
end

return config
