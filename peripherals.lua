-- Resolve GT / TFG machine peripherals from recipe machine ids.

local peripherals = {}

local function peripheralTypes(name)
    local ok, ptype = pcall(peripheral.getType, name)
    if not ok or not ptype then
        return {}
    end
    if type(ptype) == "table" then
        return ptype
    end
    return { ptype }
end

local function typeMatchesRecipe(ptype, recipe)
    if not ptype then
        return false
    end
    ptype = tostring(ptype)
    if ptype == recipe.machine or ptype == recipe.base then
        return true
    end
    local shortBase = recipe.base:match("([^:]+)$") or recipe.base
    if ptype:find(shortBase, 1, true) then
        return true
    end
    if recipe.flag == "grow" and ptype:lower():find("electric_greenhouse", 1, true) then
        return true
    end
    return false
end

local function nameMatchesRecipe(name, recipe)
    if name == recipe.machine or name == recipe.base then
        return true
    end
    local prefix = recipe.base .. "_"
    if name:sub(1, #prefix) == prefix then
        return true
    end
    local shortBase = recipe.base:match("([^:]+)$") or recipe.base
    if name:find(shortBase, 1, true) then
        return true
    end
    if recipe.flag == "grow" and name:lower():find("greenhouse", 1, true) then
        return true
    end
    return false
end

local function collectMatches(recipe)
    local names = peripheral.getNames()
    local matches = {}
    local seen = {}

    for i = 1, #names do
        local name = names[i]
        local matched = nameMatchesRecipe(name, recipe)
        if not matched then
            local types = peripheralTypes(name)
            for j = 1, #types do
                if typeMatchesRecipe(types[j], recipe) then
                    matched = true
                    break
                end
            end
        end
        if matched and not seen[name] then
            seen[name] = true
            matches[#matches + 1] = name
        end
    end
    return matches
end

--- Resolve a physical machine peripheral for a recipe.
-- Priority: exact recipe.machine → matching _circuit suffix → first sorted fuzzy.
function peripherals.resolveMachine(recipe)
    local matches = collectMatches(recipe)
    if #matches == 0 then
        return nil
    end

    for i = 1, #matches do
        if matches[i] == recipe.machine then
            return matches[i]
        end
    end

    if recipe.circuit ~= nil then
        local suffix = "_" .. tostring(recipe.circuit)
        for i = 1, #matches do
            if matches[i]:sub(-#suffix) == suffix then
                return matches[i]
            end
        end
    end

    table.sort(matches)
    return matches[1]
end

return peripherals
