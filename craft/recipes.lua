-- Parse recipes.cfg into structured recipe tables.
--
-- Recipe fields:
--   machine  string   e.g. "tfg:hv_food_processor_3"
--   base     string   machine without circuit suffix
--   circuit  number   trailing _N from machine id
--   inputs   { { name, count, fluid? }, ... }
--   outputs  { { name, count, fluid? }, ... }
--   flag     "grow" | "craft" | "processing"
--   oneshot  bool   if true, feed one craft then wait for outputs before next

local util = require("util")

local recipes = {}

--- Parse "mod:id 4" or "mod:fluid 100mb" or "#tag:path 1"
local function parseStack(token)
    token = util.trim(token)
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
    field = util.trim(field)
    if field == "" or field == "-" or field:lower() == "null" then
        return {}
    end

    field = field:gsub("^%(", ""):gsub("%)$", "")

    local stacks = {}
    for _, token in ipairs(util.split(field, ",")) do
        local stack = parseStack(token)
        if stack then
            stacks[#stacks + 1] = stack
        end
    end
    return stacks
end

local function parseMachine(machine)
    machine = util.trim(machine)
    local base, circuit = machine:match("^(.-)_(%d+)$")
    if base and circuit then
        return machine, base, tonumber(circuit)
    end
    return machine, machine, nil
end

local function parseFlagField(field, lineNo)
    field = util.trim(field or ""):lower()
    local tokens = {}
    for token in field:gmatch("%S+") do
        tokens[#tokens + 1] = token
    end
    if #tokens == 0 then
        error(("Recipe line %s: empty flag"):format(tostring(lineNo)))
    end

    local flag = tokens[1]
    if flag ~= "grow" and flag ~= "craft" and flag ~= "processing" then
        error(("Recipe line %s: unknown flag %q"):format(tostring(lineNo), flag))
    end

    local oneshot = false
    for i = 2, #tokens do
        local t = tokens[i]
        if t == "oneshot" or t == "one" or t == "serial" then
            oneshot = true
        else
            error(("Recipe line %s: unknown flag option %q"):format(tostring(lineNo), t))
        end
    end

    -- Optional 5th field: oneshot / serial (also accepted in flag field as "processing oneshot")
    return flag, oneshot
end

function recipes.parseLine(line, lineNo)
    line = util.trim(line or "")
    if line == "" or line:sub(1, 1) == "#" then
        return nil
    end

    local parts = util.split(line, "|")
    if #parts < 4 then
        error(("Recipe line %s: expected machine|inputs|outputs|flag[|oneshot]"):format(tostring(lineNo)))
    end

    local machineRaw = util.trim(parts[1])
    local machine, base, circuit = parseMachine(machineRaw)
    local flag, oneshot = parseFlagField(parts[4], lineNo)

    if #parts >= 5 then
        local extra = util.trim(parts[5]):lower()
        if extra == "oneshot" or extra == "one" or extra == "serial" then
            oneshot = true
        elseif extra ~= "" then
            error(("Recipe line %s: unknown option %q (use oneshot)"):format(tostring(lineNo), extra))
        end
    end

    return {
        machine = machine,
        base = base,
        circuit = circuit,
        inputs = parseStackList(parts[2]),
        outputs = parseStackList(parts[3]),
        flag = flag,
        oneshot = oneshot,
        line = lineNo,
    }
end

function recipes.load(path)
    path = util.resolvePath(path, "recipes.cfg")
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

--- Primary non-fluid output stack, or nil.
function recipes.primaryOutput(recipe)
    if not recipe or not recipe.outputs then
        return nil
    end
    for i = 1, #recipe.outputs do
        if not recipe.outputs[i].fluid then
            return recipe.outputs[i]
        end
    end
    return nil
end

--- Stable key for machine locking: same recipe identity, different from siblings on same machine.
function recipes.recipeKey(recipe)
    if not recipe then
        return "unknown"
    end
    local out = recipes.primaryOutput(recipe)
    local outName = out and out.name or "-"
    return tostring(recipe.machine) .. "|" .. outName
end

return recipes
