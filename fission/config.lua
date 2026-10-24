-- Load fission.cfg. Project-local; deploy one bundle per computer.

local util = require("util")
local cfg_pipe = require("cfg_pipe")

local config = {}

local function empty()
    return {
        monitor = "right",
        ae = "ae2:interface_0",
        poll = 1,
        rod_cap = 5,
        text_scale = 0.5,
        fuels = {}, -- item id -> heat number
        reactors = {}, -- list of reactor rows
    }
end

local function setNumber(cfg, key, raw, lineNo, label)
    local n = tonumber(raw)
    if not n then
        error(("%s line %s: %s needs a number"):format(label, tostring(lineNo), key))
    end
    cfg[key] = n
end

local function parseAllow(raw)
    local list = {}
    local set = {}
    for part in tostring(raw or ""):gmatch("[^,]+") do
        local id = util.trim(part)
        if id ~= "" and not set[id] then
            set[id] = true
            list[#list + 1] = id
        end
    end
    return list, set
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
    local label = "fission.cfg"
    if key == "" then
        error(("%s line %s: empty key"):format(label, tostring(lineNo)))
    end

    if key == "monitor" then
        if not parts[2] or parts[2] == "" then
            error(("%s line %s: monitor | side"):format(label, tostring(lineNo)))
        end
        cfg.monitor = parts[2]
        return
    end

    if key == "ae" or key == "ae2" or key == "interface" then
        if not parts[2] or parts[2] == "" then
            error(("%s line %s: ae | peripheral"):format(label, tostring(lineNo)))
        end
        cfg.ae = parts[2]
        return
    end

    if key == "poll" or key == "interval" then
        setNumber(cfg, "poll", parts[2], lineNo, label)
        return
    end

    if key == "rod_cap" or key == "max_rods" or key == "cap" then
        setNumber(cfg, "rod_cap", parts[2], lineNo, label)
        return
    end

    if key == "text_scale" or key == "scale" or key == "font" or key == "font_scale" then
        setNumber(cfg, "text_scale", parts[2], lineNo, label)
        return
    end

    if key == "fuel" then
        if not parts[2] or parts[2] == "" or not parts[3] or parts[3] == "" then
            error(("%s line %s: fuel | item_id | heat"):format(label, tostring(lineNo)))
        end
        local heat = tonumber(parts[3])
        if not heat then
            error(("%s line %s: fuel heat must be a number"):format(label, tostring(lineNo)))
        end
        cfg.fuels[parts[2]] = heat
        return
    end

    if key == "reactor" then
        -- reactor | label | controller | input | output | stock | allow...
        if #parts < 7 then
            error(("%s line %s: reactor | label | controller | input | output | stock | allow"):format(
                label, tostring(lineNo)))
        end
        local allowList, allowSet = parseAllow(parts[7])
        if #allowList == 0 then
            error(("%s line %s: reactor needs at least one allow item"):format(label, tostring(lineNo)))
        end
        cfg.reactors[#cfg.reactors + 1] = {
            label = parts[2],
            controller = parts[3],
            input = parts[4],
            output = parts[5],
            stock = parts[6],
            allow = allowList,
            allowSet = allowSet,
            primary = allowList[1],
        }
        return
    end

    error(("%s line %s: unknown key %q"):format(label, tostring(lineNo), key))
end

function config.load(path)
    local lines, resolved, ok = cfg_pipe.loadLines(path, "fission.cfg")
    local cfg = empty()
    if not ok then
        print("fission: no fission.cfg at " .. tostring(resolved) .. " — using defaults")
    else
        for n = 1, #lines do
            parseLine(cfg, lines[n], n)
        end
    end

    if cfg.poll < 0.05 then
        cfg.poll = 0.05
    end
    if cfg.rod_cap < 0 then
        cfg.rod_cap = 0
    end
    if cfg.rod_cap > 64 then
        cfg.rod_cap = 64
    end
    -- CC monitors accept 0.5 .. 5.0 in 0.5 steps.
    local ts = tonumber(cfg.text_scale) or 0.5
    if ts < 0.5 then
        ts = 0.5
    elseif ts > 5 then
        ts = 5
    else
        ts = math.floor(ts * 2 + 0.5) / 2
        if ts < 0.5 then
            ts = 0.5
        end
    end
    cfg.text_scale = ts

    if #cfg.reactors == 0 then
        -- built-in layout if cfg missing reactors
        local th, u = "tfg:thorium_rod", "tfg:uranium_rod"
        if not cfg.fuels[th] then
            cfg.fuels[th] = 0.7
        end
        if not cfg.fuels[u] then
            cfg.fuels[u] = 2.2
        end
        cfg.reactors[1] = {
            label = "Торий",
            controller = "fission_reactor_0",
            input = "gtceu:hv_input_bus_0",
            output = "gtceu:hv_output_bus_0",
            stock = "gtceu:wood_crate_2",
            allow = { th },
            allowSet = { [th] = true },
            primary = th,
        }
        cfg.reactors[2] = {
            label = "Уран",
            controller = "fission_reactor_1",
            input = "gtceu:hv_input_bus_1",
            output = "gtceu:hv_output_bus_1",
            stock = "gtceu:wood_crate_3",
            allow = { u },
            allowSet = { [u] = true },
            primary = u,
        }
    end

    return cfg
end

return config
