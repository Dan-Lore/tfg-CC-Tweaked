-- Parse GTCEu gem item ids into material + tier (1..5).

local gems = {}

-- Tier order: each next costs 2 of previous (laser engraver upgrade).
gems.TIER_CHIPPED = 1
gems.TIER_FLAWED = 2
gems.TIER_GEM = 3
gems.TIER_FLAWLESS = 4
gems.TIER_EXQUISITE = 5

gems.TIER_NAME = {
    [1] = "chipped",
    [2] = "flawed",
    [3] = "gem",
    [4] = "flawless",
    [5] = "exquisite",
}

gems.MAX_PROCESS_TIER = gems.TIER_FLAWLESS -- exquisite is sink / leaves buffer

-- GT maps these vanilla items as the normal (tier-3) gem for the material.
-- Quality variants stay gtceu:chipped_<mat>_gem / flawless_<mat>_gem / …
local VANILLA_GEMS = {
    ["minecraft:diamond"] = { material = "diamond", tier = 3 },
    ["minecraft:emerald"] = { material = "emerald", tier = 3 },
    ["minecraft:lapis_lazuli"] = { material = "lapis", tier = 3 },
    ["minecraft:quartz"] = { material = "nether_quartz", tier = 3 },
    ["minecraft:amethyst_shard"] = { material = "amethyst", tier = 3 },
    ["minecraft:echo_shard"] = { material = "echo_shard", tier = 3 },
    ["minecraft:coal"] = { material = "coal", tier = 3 },
}

-- Extra crystals common in TFG that should ride the same pipeline / sort.
local EXTRA_GEMS = {
    ["ae2:certus_quartz_crystal"] = { material = "certus_quartz", tier = 3 },
    ["ae2:charged_certus_quartz_crystal"] = { material = "certus_quartz", tier = 3 },
    ["ae2:fluix_crystal"] = { material = "fluix", tier = 3 },
}

local PATTERNS = {
    { tier = 1, re = "^gtceu:chipped_(.+)_gem$" },
    { tier = 2, re = "^gtceu:flawed_(.+)_gem$" },
    { tier = 4, re = "^gtceu:flawless_(.+)_gem$" },
    { tier = 5, re = "^gtceu:exquisite_(.+)_gem$" },
    { tier = 3, re = "^gtceu:(.+)_gem$" },
}

local function makeInfo(itemName, material, tier)
    return {
        name = itemName,
        material = material,
        tier = tier,
        processable = tier <= gems.MAX_PROCESS_TIER,
    }
end

--- Optional runtime aliases from config: gems.addAlias(itemId, material, tier)
local runtimeAliases = {}

function gems.addAlias(itemName, material, tier)
    if not itemName or not material then
        return
    end
    tier = tonumber(tier) or gems.TIER_GEM
    runtimeAliases[itemName] = { material = material, tier = tier }
end

--- @return { name, material, tier, processable } | nil
function gems.parse(itemName)
    if not itemName or type(itemName) ~= "string" then
        return nil
    end

    local alias = runtimeAliases[itemName] or VANILLA_GEMS[itemName] or EXTRA_GEMS[itemName]
    if alias then
        return makeInfo(itemName, alias.material, alias.tier)
    end

    for i = 1, #PATTERNS do
        local p = PATTERNS[i]
        local mat = itemName:match(p.re)
        if mat then
            return makeInfo(itemName, mat, p.tier)
        end
    end
    return nil
end

function gems.isGem(itemName)
    return gems.parse(itemName) ~= nil
end

function gems.short(itemName, maxLen)
    maxLen = maxLen or 18
    local info = gems.parse(itemName)
    local text
    if info then
        text = gems.TIER_NAME[info.tier] .. " " .. info.material
    else
        text = tostring(itemName or "?"):match("([^:/]+)$") or tostring(itemName)
    end
    text = text:gsub("_", " ")
    if #text > maxLen then
        return text:sub(1, maxLen - 1) .. "."
    end
    return text
end

--- Even amount we may take from stock, leaving a single remainder in the buffer.
function gems.evenStock(count)
    count = tonumber(count) or 0
    if count < 2 then
        return 0
    end
    return count - (count % 2)
end

--- How many items we can add so the final stack count stays even (and ≤ maxStack).
function gems.evenRoom(current, maxStack)
    current = tonumber(current) or 0
    maxStack = tonumber(maxStack) or 64
    local room = maxStack - current
    if room <= 0 then
        return 0
    end
    if current % 2 == 1 then
        local rest = room - 1
        return 1 + (rest - (rest % 2))
    end
    return room - (room % 2)
end

return gems
