-- Shared pipe-delimited cfg helpers (key | value [| ...]).

local util = require("util")

local cfg_pipe = {}

cfg_pipe.trim = util.trim
cfg_pipe.split = util.split
cfg_pipe.resolvePath = util.resolvePath

function cfg_pipe.parseScale(raw)
    raw = util.trim(tostring(raw or "")):lower()
    if raw == "" or raw == "auto" then
        return "auto"
    end
    local n = tonumber(raw)
    if not n then
        return "auto"
    end
    n = math.floor(n * 2 + 0.5) / 2
    return util.clamp(n, 0.5, 5)
end

--- Split a cfg line into key, value, parts (or nil, errHint).
function cfg_pipe.splitLine(line)
    line = util.trim(line or "")
    if line == "" or line:sub(1, 1) == "#" then
        return nil
    end
    local parts = util.split(line, "|")
    for i = 1, #parts do
        parts[i] = util.trim(parts[i])
    end
    local key = (parts[1] or ""):lower()
    if key == "" then
        return nil, "empty key"
    end
    if parts[2] == nil or parts[2] == "" then
        return nil, key .. " | value"
    end
    return key, parts[2], parts
end

local function linesFromText(text)
    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = line
    end
    return lines
end

--- Load all lines from a cfg file.
-- @return lines, path, ok
function cfg_pipe.loadLines(path, defaultName)
    path = util.resolvePath(path, defaultName)
    if not fs.exists(path) then
        return nil, path, false
    end
    local text = util.readAll(path)
    if not text then
        error("Cannot open " .. path, 2)
    end
    return linesFromText(text), path, true
end

return cfg_pipe
