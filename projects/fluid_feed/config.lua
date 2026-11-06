-- Load fluid_feed.cfg into the table discover/main expect.
-- `config` is project-local (fluid_feed/); deploy one bundle per computer.

local util = require("util")
local cfg_pipe = require("cfg_pipe")

local config = {}

local function empty()
    return {
        BUFFER = "expatternprovider:ingredient_buffer_0",
        MONITOR = "left",
        AMOUNT = 144,
        HATCHES = nil,
        HATCH_SUBSTR = nil,
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
        error(("fluid_feed.cfg line %s: empty key"):format(tostring(lineNo)))
    end

    if key == "buffer" then
        if #parts < 2 then
            error(("fluid_feed.cfg line %s: buffer | peripheral"):format(tostring(lineNo)))
        end
        cfg.BUFFER = parts[2]
        return
    end

    if key == "monitor" then
        if #parts < 2 then
            error(("fluid_feed.cfg line %s: monitor | side"):format(tostring(lineNo)))
        end
        cfg.MONITOR = parts[2]
        return
    end

    if key == "amount" or key == "n" then
        if #parts < 2 then
            error(("fluid_feed.cfg line %s: amount | mb"):format(tostring(lineNo)))
        end
        cfg.AMOUNT = tonumber(parts[2]) or 0
        return
    end

    if key == "hatch" or key == "hatches" then
        if #parts < 2 then
            error(("fluid_feed.cfg line %s: hatch | peripheral"):format(tostring(lineNo)))
        end
        appendList(cfg, "HATCHES", parts[2])
        return
    end

    if key == "hatch_substr" then
        if #parts < 2 then
            error(("fluid_feed.cfg line %s: hatch_substr | needle"):format(tostring(lineNo)))
        end
        appendList(cfg, "HATCH_SUBSTR", parts[2])
        return
    end

    error(("fluid_feed.cfg line %s: unknown key %q"):format(tostring(lineNo), key))
end

function config.load(path)
    local lines, resolved, ok = cfg_pipe.loadLines(path, "fluid_feed.cfg")
    if not ok then
        error("Cannot open " .. tostring(resolved), 2)
    end

    local cfg = empty()
    for n = 1, #lines do
        parseLine(cfg, lines[n], n)
    end

    if cfg.HATCH_SUBSTR == nil then
        cfg.HATCH_SUBSTR = "gtceu:ev_input_hatch_4x"
    elseif #cfg.HATCH_SUBSTR == 1 then
        cfg.HATCH_SUBSTR = cfg.HATCH_SUBSTR[1]
    end

    return cfg
end

return config
