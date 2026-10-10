-- Load ae2_feed.cfg into the table discover/main expect.
-- `config` is project-local (ae2_feed/); deploy one bundle per computer.

local util = require("util")
local cfg_pipe = require("cfg_pipe")

local config = {}

local function empty()
    return {
        N = 0,
        STORAGES = nil,
        MACHINES = nil,
        STORAGE_SUBSTR = nil,
        MACHINE_SUBSTR = nil,
    }
end

local function appendList(cfg, key, value)
    if not cfg[key] then
        cfg[key] = {}
    end
    cfg[key][#cfg[key] + 1] = value
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
    if key == "" then
        error(("ae2_feed.cfg line %s: empty key"):format(tostring(lineNo)))
    end

    if key == "n" then
        if #parts < 2 then
            error(("ae2_feed.cfg line %s: N | amount"):format(tostring(lineNo)))
        end
        cfg.N = tonumber(parts[2]) or 0
        return
    end

    if key == "storage" or key == "storages" then
        if #parts < 2 then
            error(("ae2_feed.cfg line %s: storage | peripheral"):format(tostring(lineNo)))
        end
        appendList(cfg, "STORAGES", parts[2])
        return
    end

    if key == "machine" or key == "machines" then
        if #parts < 2 then
            error(("ae2_feed.cfg line %s: machine | peripheral"):format(tostring(lineNo)))
        end
        appendList(cfg, "MACHINES", parts[2])
        return
    end

    if key == "storage_substr" then
        if #parts < 2 then
            error(("ae2_feed.cfg line %s: storage_substr | needle"):format(tostring(lineNo)))
        end
        appendList(cfg, "STORAGE_SUBSTR", parts[2])
        return
    end

    if key == "machine_substr" then
        if #parts < 2 then
            error(("ae2_feed.cfg line %s: machine_substr | needle"):format(tostring(lineNo)))
        end
        appendList(cfg, "MACHINE_SUBSTR", parts[2])
        return
    end

    error(("ae2_feed.cfg line %s: unknown key %q"):format(tostring(lineNo), key))
end

--- Load ae2_feed.cfg (next to the running program by default).
function config.load(path)
    local lines, resolved, ok = cfg_pipe.loadLines(path, "ae2_feed.cfg")
    if not ok then
        error("Cannot open " .. tostring(resolved), 2)
    end

    local cfg = empty()
    for n = 1, #lines do
        parseLine(cfg, lines[n], n)
    end

    -- Single needle → string (discover accepts string or list).
    if cfg.STORAGE_SUBSTR and #cfg.STORAGE_SUBSTR == 1 then
        cfg.STORAGE_SUBSTR = cfg.STORAGE_SUBSTR[1]
    end
    if cfg.MACHINE_SUBSTR and #cfg.MACHINE_SUBSTR == 1 then
        cfg.MACHINE_SUBSTR = cfg.MACHINE_SUBSTR[1]
    end

    return cfg
end

return config
