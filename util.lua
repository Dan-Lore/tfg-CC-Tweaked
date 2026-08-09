-- Shared string / path helpers for CC:Tweaked scripts.

local util = {}

function util.trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function util.split(s, sep)
    local out = {}
    s = tostring(s or "")
    for part in (s .. sep):gmatch("(.-)" .. sep) do
        out[#out + 1] = part
    end
    return out
end

--- Resolve a config path relative to the running program directory.
function util.resolvePath(path, defaultName)
    path = path or defaultName
    if not path then
        error("resolvePath: path required", 2)
    end
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

--- Short display name: last path segment after `/`.
function util.short(id)
    id = tostring(id or "")
    return id:match("([^/]+)$") or id
end

function util.clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

return util
