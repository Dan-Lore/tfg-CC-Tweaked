-- Load railgun.cfg. Project-local; deploy one bundle per computer.

local util = require("util")
local cfg_pipe = require("cfg_pipe")

local config = {}

local function empty()
    return {
        loader_prefix = "tfg:hv_railgun_item_loader_in",
        expected = 10,
        relay = "top",
        relay_side = "back",
        settle = 15,
        pulse = 3,
        poll = 2,
        cooldown = 120,
    }
end

local function setNumber(cfg, key, raw, lineNo, label)
    local n = tonumber(raw)
    if not n then
        error(("%s line %s: %s needs a number"):format(label, tostring(lineNo), key))
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

    local key = parts[1] and parts[1]:lower() or ""
    local val = parts[2]
    local label = "railgun.cfg"
    if key == "" then
        error(("%s line %s: empty key"):format(label, tostring(lineNo)))
    end
    if val == nil or val == "" then
        error(("%s line %s: %s | value"):format(label, tostring(lineNo), key))
    end

    if key == "loader_prefix" or key == "prefix" then
        cfg.loader_prefix = val
    elseif key == "expected" or key == "loaders" then
        setNumber(cfg, "expected", val, lineNo, label)
    elseif key == "relay" then
        cfg.relay = val
    elseif key == "relay_side" or key == "side" then
        cfg.relay_side = val:lower()
    elseif key == "settle" or key == "settle_s" then
        setNumber(cfg, "settle", val, lineNo, label)
    elseif key == "pulse" or key == "pulse_s" then
        setNumber(cfg, "pulse", val, lineNo, label)
    elseif key == "poll" or key == "interval" then
        setNumber(cfg, "poll", val, lineNo, label)
    elseif key == "cooldown" then
        setNumber(cfg, "cooldown", val, lineNo, label)
    else
        error(("%s line %s: unknown key %q"):format(label, tostring(lineNo), key))
    end
end

function config.load(path)
    local lines, resolved, ok = cfg_pipe.loadLines(path, "railgun.cfg")
    local cfg = empty()
    if not ok then
        print("railgun: no railgun.cfg at " .. tostring(resolved) .. " — using defaults")
        return cfg
    end

    for n = 1, #lines do
        parseLine(cfg, lines[n], n)
    end

    if cfg.pulse < 0.05 then
        cfg.pulse = 0.05
    end
    if cfg.poll < 0.05 then
        cfg.poll = 0.05
    end
    if cfg.settle < 0 then
        cfg.settle = 0
    end
    if cfg.cooldown < 0 then
        cfg.cooldown = 0
    end
    if cfg.expected < 0 then
        cfg.expected = 0
    end

    return cfg
end

return config
