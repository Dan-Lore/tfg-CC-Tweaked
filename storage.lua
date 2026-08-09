-- Parse storage.cfg into named inventories, sources, seeds, routes, settings.

local storage = {}

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function split(s, sep)
    local out = {}
    for part in (s .. sep):gmatch("(.-)" .. sep) do
        out[#out + 1] = part
    end
    return out
end

local function resolvePath(path)
    path = path or "storage.cfg"
    if path:sub(1, 1) == "/" then
        return path
    end
    local base = ""
    if shell and shell.getRunningProgram then
        local prog = shell.getRunningProgram()
        if prog then
            base = fs.getDir(prog)
        end
    end
    return fs.combine(base, path)
end

local function emptyConfig()
    return {
        named = {},
        sources = {},
        seeds = {},
        routes = {},
        settings = {},
    }
end

local NAMED_KEYS = {
    main = true,
    flora = true,
    overflow = true,
    seed_chest_prefix = true,
    output_bus_prefix = true,
}

local function parseLine(cfg, line, lineNo)
    line = trim(line or "")
    if line == "" or line:sub(1, 1) == "#" then
        return
    end

    local parts = split(line, "|")
    for i = 1, #parts do
        parts[i] = trim(parts[i])
    end

    local key = parts[1]
    if not key or key == "" then
        error(("storage.cfg line %s: empty key"):format(tostring(lineNo)))
    end

    if key == "source" then
        if #parts < 3 then
            error(("storage.cfg line %s: source | item | peripheral"):format(tostring(lineNo)))
        end
        cfg.sources[parts[2]] = parts[3]
        return
    end

    if key == "seed" then
        if #parts < 3 then
            error(("storage.cfg line %s: seed | crop | seedItem"):format(tostring(lineNo)))
        end
        cfg.seeds[parts[2]] = parts[3]
        return
    end

    if key == "route" then
        if #parts < 3 then
            error(("storage.cfg line %s: route | item | dest"):format(tostring(lineNo)))
        end
        cfg.routes[parts[2]] = parts[3]
        return
    end

    if NAMED_KEYS[key] then
        if #parts < 2 then
            error(("storage.cfg line %s: %s | value"):format(tostring(lineNo), key))
        end
        cfg.named[key] = parts[2]
        return
    end

    -- scalar setting: key | value
    if #parts >= 2 then
        cfg.settings[key] = parts[2]
        return
    end

    error(("storage.cfg line %s: bad directive %q"):format(tostring(lineNo), key))
end

local function resolveAlias(cfg, dest)
    if not dest then
        return nil
    end
    if dest == "main" or dest == "flora" or dest == "overflow" then
        return cfg.named[dest]
    end
    return dest
end

--- Load storage.cfg. Returns a config table with helper methods.
function storage.load(path)
    path = resolvePath(path)
    local file = fs.open(path, "r")
    if not file then
        error("Cannot open " .. path, 2)
    end

    local cfg = emptyConfig()
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

    function cfg.main()
        return cfg.named.main
    end

    function cfg.flora()
        return cfg.named.flora
    end

    function cfg.overflow()
        return cfg.named.overflow
    end

    function cfg.seedChestPrefix()
        return cfg.named.seed_chest_prefix or "gtceu:lv_super_chest_"
    end

    function cfg.outputBusPrefix()
        return cfg.named.output_bus_prefix or "gtceu:mv_output_bus_"
    end

    function cfg.sourceOf(itemId)
        return cfg.sources[itemId] or cfg.named.main
    end

    function cfg.destFor(itemId)
        local route = cfg.routes[itemId]
        if route then
            return resolveAlias(cfg, route) or cfg.named.main
        end
        return cfg.named.main
    end

    function cfg.seedDest(index)
        index = tonumber(index) or 0
        return cfg.seedChestPrefix() .. tostring(index)
    end

    --- Output bus for greenhouse index / circuit (e.g. gtceu:mv_output_bus_0).
    function cfg.outputBus(index)
        index = tonumber(index) or 0
        return cfg.outputBusPrefix() .. tostring(index)
    end

    function cfg.seedForCrop(cropId)
        return cfg.seeds[cropId]
    end

    function cfg.get(key, default)
        local v = cfg.settings[key]
        if v == nil then
            return default
        end
        return v
    end

    function cfg.getNumber(key, default)
        local v = tonumber(cfg.settings[key])
        if v == nil then
            return default
        end
        return v
    end

    return cfg
end

return storage
