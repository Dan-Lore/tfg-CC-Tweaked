-- Parse recipes.cfg into structured recipe tables.
--
-- Recipe fields:
--   machine  string   e.g. "tfg:hv_food_processor_3"
--   base     string   machine without circuit suffix
--   circuit  number   trailing _N from machine id
--   inputs   { { name, count, fluid? }, ... }
--   outputs  { { name, count, fluid? }, ... }
--   flag     "grow" | "craft" | "processing"

local recipes = {}

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

--- Parse "mod:id 4" or "mod:fluid 100mb" or "#tag:path 1"
local function parseStack(token)
    token = trim(token)
    if token == "" or token == "-" or token:lower() == "null" then
        return nil
    end

    local name, amount, unit = token:match("^(%S+)%s+(%d+)(mb?)$")
    if name then
        return {
            name = name,
            count = tonumber(amount),
            fluid = true,
        }
    end

    name, amount = token:match("^(%S+)%s+(%-?%d+)$")
    if not name then
        error("Bad stack token: " .. token)
    end

    return {
        name = name,
        count = tonumber(amount),
        fluid = false,
    }
end

local function parseStackList(field)
    field = trim(field)
    if field == "" or field == "-" or field:lower() == "null" then
        return {}
    end

    -- Allow optional surrounding parentheses: (a 1, b 2)
    field = field:gsub("^%(", ""):gsub("%)$", "")

    local stacks = {}
    for _, token in ipairs(split(field, ",")) do
        local stack = parseStack(token)
        if stack then
            stacks[#stacks + 1] = stack
        end
    end
    return stacks
end

local function parseMachine(machine)
    machine = trim(machine)
    local base, circuit = machine:match("^(.-)_(%d+)$")
    if base and circuit then
        return machine, base, tonumber(circuit)
    end
    return machine, machine, nil
end

function recipes.parseLine(line, lineNo)
    line = trim(line or "")
    if line == "" or line:sub(1, 1) == "#" then
        return nil
    end

    local parts = split(line, "|")
    if #parts < 4 then
        error(("Recipe line %s: expected 4 fields machine|inputs|outputs|flag"):format(tostring(lineNo)))
    end

    local machineRaw = trim(parts[1])
    local machine, base, circuit = parseMachine(machineRaw)
    local flag = trim(parts[4]):lower()

    if flag ~= "grow" and flag ~= "craft" and flag ~= "processing" then
        error(("Recipe line %s: unknown flag %q"):format(tostring(lineNo), flag))
    end

    return {
        machine = machine,
        base = base,
        circuit = circuit,
        inputs = parseStackList(parts[2]),
        outputs = parseStackList(parts[3]),
        flag = flag,
        line = lineNo,
    }
end

local function resolvePath(path)
    path = path or "recipes.cfg"
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

function recipes.load(path)
    path = resolvePath(path)
    local file = fs.open(path, "r")
    if not file then
        error("Cannot open " .. path, 2)
    end
    local list = {}
    local n = 0

    while true do
        local line = file.readLine()
        if not line then
            break
        end
        n = n + 1
        local recipe = recipes.parseLine(line, n)
        if recipe then
            list[#list + 1] = recipe
        end
    end

    file.close()
    return list
end

function recipes.filter(list, pred)
    local out = {}
    for i = 1, #list do
        if pred(list[i]) then
            out[#out + 1] = list[i]
        end
    end
    return out
end

function recipes.byFlag(list, flag)
    return recipes.filter(list, function(r) return r.flag == flag end)
end

function recipes.byMachine(list, machine)
    return recipes.filter(list, function(r) return r.machine == machine end)
end

return recipes
