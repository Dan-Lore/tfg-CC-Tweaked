-- Load crystals.cfg from disk (next to the running program).
-- `config` is project-local (crystals/); deploy one bundle per computer.

local util = require("util")
local cfg_pipe = require("cfg_pipe")

local config = {}

local function empty()
    return {
        MONITOR = "left",
        BUFFER = "top",
        OVERFLOW = nil, -- extra crates when the main buffer fills
        MACHINES = nil,
        MACHINE_SUBSTR = nil, -- filled via appendList or default in finalize
        MAX_STACK = 64,
        BATCH = 2,
        POLL = 0.5,
        KEEP_FREE = 8, -- leave this many empty slots in the main buffer
        ALIASES = {}, -- { { item, material, tier }, ... }
    }
end

local function appendList(cfg, key, value)
    local cur = cfg[key]
    if type(cur) ~= "table" then
        local list = {}
        if type(cur) == "string" and cur ~= "" then
            list[1] = cur
        end
        cfg[key] = list
    end
    cfg[key][#cfg[key] + 1] = value
end

local function parseLine(cfg, line, lineNo, label)
    label = label or "crystals.cfg"
    line = util.trim(line or "")
    if line == "" or line:sub(1, 1) == "#" then
        return
    end

    local parts = util.split(line, "|")
    for i = 1, #parts do
        parts[i] = util.trim(parts[i])
    end

    local key = parts[1] and parts[1]:lower() or ""
    if key == "" then
        error(("%s line %s: empty key"):format(label, tostring(lineNo)))
    end

    if key == "monitor" then
        if #parts < 2 then
            error(("%s line %s: monitor | side"):format(label, tostring(lineNo)))
        end
        cfg.MONITOR = parts[2]
        return
    end

    if key == "buffer" or key == "chest" or key == "storage" then
        if #parts < 2 then
            error(("%s line %s: buffer | peripheral"):format(label, tostring(lineNo)))
        end
        cfg.BUFFER = parts[2]
        return
    end

    if key == "overflow" or key == "extra" or key == "overflow_buffer" then
        if #parts < 2 then
            error(("%s line %s: overflow | peripheral"):format(label, tostring(lineNo)))
        end
        appendList(cfg, "OVERFLOW", parts[2])
        return
    end

    if key == "machine" or key == "machines" or key == "engraver" then
        if #parts < 2 then
            error(("%s line %s: machine | peripheral"):format(label, tostring(lineNo)))
        end
        appendList(cfg, "MACHINES", parts[2])
        return
    end

    if key == "machine_substr" then
        if #parts < 2 then
            error(("%s line %s: machine_substr | needle"):format(label, tostring(lineNo)))
        end
        appendList(cfg, "MACHINE_SUBSTR", parts[2])
        return
    end

    if key == "max_stack" then
        cfg.MAX_STACK = tonumber(parts[2]) or cfg.MAX_STACK
        return
    end

    if key == "batch" or key == "n" then
        cfg.BATCH = tonumber(parts[2]) or cfg.BATCH
        return
    end

    if key == "poll" then
        cfg.POLL = tonumber(parts[2]) or cfg.POLL
        return
    end

    if key == "keep_free" or key == "keepfree" then
        cfg.KEEP_FREE = tonumber(parts[2]) or cfg.KEEP_FREE
        return
    end

    -- alias | item_id | material | tier(optional, default 3)
    if key == "alias" or key == "gem_alias" then
        if #parts < 3 then
            error(("%s line %s: alias | item | material [| tier]"):format(label, tostring(lineNo)))
        end
        cfg.ALIASES[#cfg.ALIASES + 1] = {
            item = parts[2],
            material = parts[3],
            tier = tonumber(parts[4]) or 3,
        }
        return
    end

    error(("%s line %s: unknown key %q"):format(label, tostring(lineNo), key))
end

local function finalize(cfg)
    if type(cfg.MACHINE_SUBSTR) == "table" then
        if #cfg.MACHINE_SUBSTR == 0 then
            cfg.MACHINE_SUBSTR = "laser_engraver"
        elseif #cfg.MACHINE_SUBSTR == 1 then
            cfg.MACHINE_SUBSTR = cfg.MACHINE_SUBSTR[1]
        end
    elseif cfg.MACHINE_SUBSTR == nil or cfg.MACHINE_SUBSTR == "" then
        cfg.MACHINE_SUBSTR = "laser_engraver"
    end

    if cfg.BATCH < 2 then
        cfg.BATCH = 2
    end
    if cfg.BATCH % 2 == 1 then
        cfg.BATCH = cfg.BATCH + 1
    end
    if cfg.MAX_STACK < cfg.BATCH then
        cfg.MAX_STACK = 64
    end
    if cfg.POLL < 0 then
        cfg.POLL = 0
    end
    if not cfg.KEEP_FREE or cfg.KEEP_FREE < 1 then
        cfg.KEEP_FREE = 8
    end
    return cfg
end

local function parseText(text, label)
    local cfg = empty()
    local n = 0
    for line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
        n = n + 1
        parseLine(cfg, line, n, label)
    end
    return finalize(cfg)
end

--- crystals.cfg is required next to the program (not embedded).
function config.load(path)
    local lines, resolved, ok = cfg_pipe.loadLines(path, "crystals.cfg")
    if not ok then
        error("Cannot open " .. tostring(resolved) .. " (copy crystals.cfg next to crystals.lua)", 2)
    end
    return parseText(table.concat(lines, "\n"), resolved)
end

return config
