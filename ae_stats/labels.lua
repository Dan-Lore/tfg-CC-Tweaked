-- Optional display-name translations from labels.cfg.

local util = require("util")
local config_common = require("config_common")

local labels = {
    byKey = {}, -- lowercased registry or english name -> shown label
}

local function add(key, shown)
    key = util.trim(tostring(key or "")):lower()
    shown = util.trim(tostring(shown or ""))
    if key ~= "" and shown ~= "" then
        labels.byKey[key] = shown
    end
end

function labels.load(path)
    labels.byKey = {}
    path = util.resolvePath(path, "labels.cfg")
    local lines, _, ok = config_common.loadLines(path, "labels.cfg")
    if not ok or not lines then
        return false, path
    end
    for n = 1, #lines do
        local key, val, parts = config_common.splitLine(lines[n])
        if key == "label" and val then
            local shown = parts[3]
            if shown and shown ~= "" then
                add(val, shown)
            end
        end
    end
    return true, path
end

local function lookup(key)
    key = util.trim(tostring(key or "")):lower()
    if key == "" then
        return nil
    end
    local hit = labels.byKey[key]
    if hit then
        return hit
    end
    -- last path segment: gtceu:foo_dust / material.tfg.foo
    local seg = key:match("([^:/]+)$")
    if seg and seg ~= key then
        hit = labels.byKey[seg]
        if hit then
            return hit
        end
    end
    return nil
end

--- Prefer registry name, then English displayName, else short fallback.
function labels.resolve(name, displayName)
    name = tostring(name or "")
    displayName = tostring(displayName or "")
    local hit = lookup(name)
    if hit then
        return hit
    end
    hit = lookup(displayName)
    if hit then
        return hit
    end
    -- avoid showing raw translation keys like material.tfg.*
    if displayName:find("^material%.", 1) then
        return util.short(name ~= "" and name or displayName)
    end
    return util.short(displayName ~= "" and displayName or name)
end

return labels
