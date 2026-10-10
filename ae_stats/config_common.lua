-- Shared key|value cfg helpers for ae_stats (thin wrap over shared/cfg_pipe).

local util = require("util")
local cfg_pipe = require("cfg_pipe")

local config_common = {}

config_common.parseScale = cfg_pipe.parseScale
config_common.splitLine = cfg_pipe.splitLine
config_common.loadLines = cfg_pipe.loadLines

--- Track id: "item|<name>" or "fluid|<name>"
function config_common.trackId(kind, name)
    kind = (kind == "fluid") and "fluid" or "item"
    return kind .. "|" .. tostring(name)
end

function config_common.parseTrackId(id)
    id = tostring(id or "")
    local kind, name = id:match("^(%w+)|(.+)$")
    if kind == "item" or kind == "fluid" then
        return kind, name
    end
    return "item", id
end

function config_common.writeWatchlist(path, items)
    path = util.resolvePath(path)
    local file = fs.open(path, "w")
    if not file then
        return false
    end
    file.writeLine("# auto-saved watchlist (track | item|fluid | name)")
    for i = 1, #items do
        local kind, name = config_common.parseTrackId(items[i])
        file.writeLine("track | " .. kind .. " | " .. name)
    end
    file.close()
    return true
end

function config_common.readWatchlist(path)
    path = util.resolvePath(path)
    if not fs.exists(path) then
        return {}
    end
    local file = fs.open(path, "r")
    if not file then
        return {}
    end
    local items = {}
    local seen = {}
    while true do
        local line = file.readLine()
        if not line then
            break
        end
        local key, val, parts = config_common.splitLine(line)
        if key == "track" and val then
            local kind, name
            if parts[3] and parts[3] ~= "" then
                kind = val:lower()
                name = parts[3]
                if kind ~= "fluid" then
                    kind = "item"
                end
            else
                kind, name = "item", val
            end
            local id = config_common.trackId(kind, name)
            if not seen[id] then
                seen[id] = true
                items[#items + 1] = id
            end
        end
    end
    file.close()
    return items
end

return config_common
