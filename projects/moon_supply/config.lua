-- Load moon_supply_E_ctrl.cfg / moon_supply_M_probe.cfg. One bundle per computer.

local EARTH_CFG = "moon_supply_E_ctrl.cfg"
local MOON_CFG = "moon_supply_M_probe.cfg"

local util = require("util")
local cfg_pipe = require("cfg_pipe")

local config = {}

local DEFAULT_ITEMS = {
    { name = "gtceu:mv_conveyor_module", target = 128 },
    { name = "gtceu:aluminium_ingot", target = 1024 },
    { name = "gtceu:hv_robot_arm", target = 64 },
    { name = "gtceu:central_processing_unit", target = 256 },
    { name = "gtceu:stainless_steel_ingot", target = 1024 },
    { name = "gtceu:polyethylene_foil", target = 2048 },
    { name = "minecraft:redstone", target = 2048 },
    { name = "tfg:hv_universal_circuit", target = 512 },
    { name = "tfg:lv_universal_circuit", target = 1024 },
    { name = "gtceu:mv_robot_arm", target = 128 },
    { name = "gtceu:random_access_memory", target = 256 },
    { name = "gtceu:polyvinyl_chloride_foil", target = 2048 },
    { name = "tfg:ev_universal_circuit", target = 256 },
    { name = "tfg:iv_universal_circuit", target = 128 },
    { name = "gtceu:exquisite_quartzite_gem", target = 512 },
    { name = "gtceu:exquisite_nether_quartz_gem", target = 512 },
    { name = "gtceu:exquisite_certus_quartz_gem", target = 512 },
    { name = "gtceu:diamond_plate", target = 1024 },
    { name = "gtceu:silicon_plate", target = 1024 },
    { name = "gtceu:gold_ingot", target = 1024 },
    { name = "gtceu:dense_silicon_plate", target = 128 },
    { name = "tfg:silica_aerogel", target = 1024 },
}

local function copyDefaults()
    local items = {}
    for i = 1, #DEFAULT_ITEMS do
        local it = DEFAULT_ITEMS[i]
        items[i] = { name = it.name, target = it.target }
    end
    return items
end

local function emptyEarth()
    return {
        bridge = "meBridge_2",
        monitor = "monitor_1",
        modem = "bottom",
        buffer = "",
        export_side = "up",
        loader_prefix = "tfg:hv_railgun_item_loader_in",
        expected = 10,
        relay = "top",
        relay_side = "back",
        pulse = 3,
        settle = 2,
        poll = 10,
        cooldown = 70,
        red_frac = 0.25,
        craft_wait_red = 60,
        craft_wait_green = 120,
        stock_timeout = 5,
        moon_id = nil,
        items = copyDefaults(),
        _itemsFromCfg = false,
    }
end

local function emptyMoon()
    return {
        bridge = "right",
        modem = "top",
    }
end

local function setNumber(cfg, key, raw, lineNo, label)
    local n = tonumber(raw)
    if not n then
        error(("%s line %s: %s needs a number"):format(label, tostring(lineNo), key))
    end
    cfg[key] = n
end

local function addItem(cfg, name, target, lineNo, label)
    if not name or name == "" then
        error(("%s line %s: item | id | target"):format(label, tostring(lineNo)))
    end
    local t = tonumber(target)
    if not t or t < 0 then
        error(("%s line %s: item target must be >= 0"):format(label, tostring(lineNo)))
    end
    if not cfg._itemsFromCfg then
        cfg.items = {}
        cfg._itemsFromCfg = true
    end
    cfg.items[#cfg.items + 1] = { name = name, target = math.floor(t) }
end

local function parseEarthLine(cfg, line, lineNo)
    local key, val, parts = cfg_pipe.splitLine(line)
    if not key then
        if val then
            error(("%s line %s: %s"):format(EARTH_CFG, tostring(lineNo), tostring(val)))
        end
        return
    end
    local label = EARTH_CFG

    if key == "bridge" then
        cfg.bridge = val
    elseif key == "monitor" then
        cfg.monitor = val
    elseif key == "modem" then
        cfg.modem = val
    elseif key == "buffer" then
        cfg.buffer = val
    elseif key == "export_side" or key == "export" then
        cfg.export_side = val:lower()
    elseif key == "loader_prefix" or key == "prefix" then
        cfg.loader_prefix = val
    elseif key == "expected" or key == "loaders" then
        setNumber(cfg, "expected", val, lineNo, label)
    elseif key == "relay" then
        cfg.relay = val
    elseif key == "relay_side" or key == "side" then
        cfg.relay_side = val:lower()
    elseif key == "pulse" or key == "pulse_s" then
        setNumber(cfg, "pulse", val, lineNo, label)
    elseif key == "settle" or key == "settle_s" then
        setNumber(cfg, "settle", val, lineNo, label)
    elseif key == "poll" or key == "interval" then
        setNumber(cfg, "poll", val, lineNo, label)
    elseif key == "cooldown" then
        setNumber(cfg, "cooldown", val, lineNo, label)
    elseif key == "red_frac" or key == "red" then
        setNumber(cfg, "red_frac", val, lineNo, label)
    elseif key == "craft_wait_red" then
        setNumber(cfg, "craft_wait_red", val, lineNo, label)
    elseif key == "craft_wait_green" then
        setNumber(cfg, "craft_wait_green", val, lineNo, label)
    elseif key == "stock_timeout" then
        setNumber(cfg, "stock_timeout", val, lineNo, label)
    elseif key == "moon_id" or key == "host_id" then
        local n = tonumber(val)
        cfg.moon_id = n and math.floor(n) or nil
    elseif key == "item" then
        local name = val
        local target = parts[3]
        addItem(cfg, name, target, lineNo, label)
    else
        error(("%s line %s: unknown key %q"):format(label, tostring(lineNo), key))
    end
end

local function parseMoonLine(cfg, line, lineNo)
    local key, val = cfg_pipe.splitLine(line)
    if not key then
        if val then
            error(("%s line %s: %s"):format(MOON_CFG, tostring(lineNo), tostring(val)))
        end
        return
    end
    local label = MOON_CFG
    if key == "bridge" then
        cfg.bridge = val
    elseif key == "modem" then
        cfg.modem = val
    elseif key == "item" then
        error(("%s line %s: watchlist only on Earth (%s), remove item here"):format(
            label, tostring(lineNo), EARTH_CFG))
    else
        error(("%s line %s: unknown key %q"):format(label, tostring(lineNo), key))
    end
end

local function clampEarth(cfg)
    if cfg.pulse < 0.05 then
        cfg.pulse = 0.05
    end
    if cfg.poll < 0.5 then
        cfg.poll = 0.5
    end
    if cfg.settle < 0 then
        cfg.settle = 0
    end
    -- Flight is 60s. 70s keeps the next poll free of in-flight items.
    if cfg.cooldown < 70 then
        cfg.cooldown = 70
    end
    if cfg.red_frac < 0 then
        cfg.red_frac = 0
    end
    if cfg.red_frac > 1 then
        cfg.red_frac = 1
    end
    if cfg.craft_wait_red < 0 then
        cfg.craft_wait_red = 0
    end
    if cfg.craft_wait_green < 0 then
        cfg.craft_wait_green = 0
    end
    if cfg.expected < 0 then
        cfg.expected = 0
    end
    cfg._itemsFromCfg = nil
    return cfg
end

function config.defaultItems()
    return copyDefaults()
end

function config.loadEarth(path)
    local lines, resolved, ok = cfg_pipe.loadLines(path, EARTH_CFG)
    local cfg = emptyEarth()
    if not ok then
        print("moon_supply: no " .. EARTH_CFG .. " at " .. tostring(resolved) .. " — using defaults")
        return clampEarth(cfg)
    end
    for n = 1, #lines do
        parseEarthLine(cfg, lines[n], n)
    end
    return clampEarth(cfg)
end

function config.loadMoon(path)
    local lines, resolved, ok = cfg_pipe.loadLines(path, MOON_CFG)
    local cfg = emptyMoon()
    if not ok then
        print("moon_supply: no " .. MOON_CFG .. " at " .. tostring(resolved) .. " — using defaults")
        return cfg
    end
    for n = 1, #lines do
        parseMoonLine(cfg, lines[n], n)
    end
    return cfg
end

function config.itemIds(cfg)
    local ids = {}
    local items = cfg and cfg.items or {}
    for i = 1, #items do
        ids[i] = items[i].name
    end
    return ids
end

return config
