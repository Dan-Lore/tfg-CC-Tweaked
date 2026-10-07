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

--- Read entire file as string, or nil if missing.
function util.readAll(path)
    if not path or not fs.exists(path) then
        return nil
    end
    local file = fs.open(path, "r")
    if not file then
        return nil
    end
    local text = file.readAll()
    file.close()
    return text
end

--- Basename of the running program without .lua (e.g. pizza_maintain).
function util.programStem()
    if not (shell and shell.getRunningProgram) then
        return nil
    end
    local prog = shell.getRunningProgram()
    if not prog then
        return nil
    end
    local name = fs.getName(prog)
    return (name:gsub("%.lua$", ""))
end

--- Lines of `[section]` from a sectioned cfg. Nil if file/section missing.
function util.cfgSectionLines(path, section)
    local text = util.readAll(path)
    if not text or not section then
        return nil
    end
    local current = nil
    local buf = {}
    local found = false
    for line in (text .. "\n"):gmatch("(.-)\n") do
        local sec = line:match("^%s*%[([%w_]+)%]%s*$")
        if sec then
            if found then
                break
            end
            if sec == section then
                found = true
                current = sec
                buf = {}
            else
                current = nil
            end
        elseif found and current == section then
            buf[#buf + 1] = line
        end
    end
    if not found then
        return nil
    end
    return buf
end

local function linesFromText(text)
    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = line
    end
    return lines
end

--- Try sectioned cfg at path; return lines, label or nil.
local function trySectioned(path, section)
    if not path or not fs.exists(path) then
        return nil
    end
    local sectionLines = util.cfgSectionLines(path, section)
    if not sectionLines then
        return nil
    end
    return sectionLines, path .. "[" .. section .. "]"
end

--- Config lines for a logical section.
-- Order: explicit path → <program>.cfg [section] → craft.cfg [section] → fallbackName.
-- Returns lines, label (for errors).
function util.openConfigLines(explicitPath, section, fallbackName)
    if explicitPath then
        local path = util.resolvePath(explicitPath)
        local text = util.readAll(path)
        if not text then
            error("Cannot open " .. path, 2)
        end
        return linesFromText(text), path
    end

    local stem = util.programStem()
    if stem then
        local lines, label = trySectioned(util.resolvePath(nil, stem .. ".cfg"), section)
        if lines then
            return lines, label
        end
    end

    local lines, label = trySectioned(util.resolvePath(nil, "craft.cfg"), section)
    if lines then
        return lines, label
    end

    local path = util.resolvePath(nil, fallbackName)
    local text = util.readAll(path)
    if not text then
        local hint = stem and (stem .. ".cfg") or "program.cfg"
        error(
            "Cannot open " .. path
                .. " (deploy "
                .. hint
                .. " next to the program, or "
                .. tostring(fallbackName)
                .. ")",
            2
        )
    end
    return linesFromText(text), path
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
