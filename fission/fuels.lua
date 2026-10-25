-- Fuel heat ratings and rod-target math (Dea's Fission / TFG).

local fuels = {}

local SS_FACTOR = 200 / 1.01 -- heat_ss per 1.0 fuel-heat unit

function fuels.heatOf(cfg, itemId)
    if not itemId or not cfg or not cfg.fuels then
        return nil
    end
    return cfg.fuels[itemId]
end

function fuels.ssPerRod(rodHeat)
    rodHeat = tonumber(rodHeat) or 0
    if rodHeat <= 0 then
        return 0
    end
    return rodHeat * SS_FACTOR
end

--- Max rods of a given heat that fit under temperatureMax (strict, no margin).
function fuels.targetN(temperatureMax, rodHeat, rodCap)
    temperatureMax = tonumber(temperatureMax) or 0
    rodHeat = tonumber(rodHeat) or 0
    rodCap = tonumber(rodCap) or 5
    if rodCap < 0 then
        rodCap = 0
    end
    local ss1 = fuels.ssPerRod(rodHeat)
    if ss1 <= 0 or temperatureMax <= 0 then
        return 0
    end
    local n = math.floor(temperatureMax / ss1)
    if n < 0 then
        n = 0
    end
    if n > rodCap then
        n = rodCap
    end
    return n
end

--- Iterate getFuels() entries (1-based, 0-based, or sparse keys).
local function eachFuel(fuelList, fn)
    if type(fuelList) ~= "table" then
        return
    end
    for k, e in pairs(fuelList) do
        if type(e) == "table" and (type(k) == "number" or tonumber(e.rods)) then
            fn(e)
        end
    end
end

--- Sum rods + total fuel-heat from getFuels() table.
function fuels.summarizeInstalled(fuelList)
    local rods = 0
    local heatSum = 0
    eachFuel(fuelList, function(e)
        local r = tonumber(e.rods) or 0
        local h = tonumber(e.heat) or 0
        rods = rods + r
        heatSum = heatSum + h * r
    end)
    return rods, heatSum
end

--- Remaining and max durability points across installed fuels.
-- Group with rods=N shares one damage value → count N times.
function fuels.durabilityTotals(fuelList)
    local remain, maxTotal = 0, 0
    eachFuel(fuelList, function(e)
        local r = tonumber(e.rods) or 0
        local dmg = tonumber(e.damage) or 0
        local maxD = tonumber(e.maxDamage) or 0
        if r > 0 and maxD > 0 then
            local left = maxD - dmg
            if left < 0 then
                left = 0
            end
            remain = remain + left * r
            maxTotal = maxTotal + maxD * r
        end
    end)
    return remain, maxTotal
end

--- Steady-state reactor heat from installed fuel-heat (full coolant, no pellets).
-- heat_ss ≈ heatSum * 200 / 1.01
function fuels.heatSs(heatSum)
    heatSum = tonumber(heatSum) or 0
    if heatSum <= 0 then
        return 0
    end
    return heatSum * SS_FACTOR
end

--- Dea's Fission: fuelDamage ≈ rods * Heat / 500 per game tick.
function fuels.fuelDamageAtHeat(rods, heat)
    rods = tonumber(rods) or 0
    heat = tonumber(heat) or 0
    if rods <= 0 or heat <= 0 then
        return 0
    end
    return rods * heat / 500
end

--- Burn rate for ETA: use steady-state heat so the timer does not look
-- "long" while the core is still climbing, then crash as heat rises.
-- If live heat is already above ss, use live heat (faster wear).
function fuels.etaDamageRate(rods, heatSum, heat, fuelDamageLive)
    local ss = fuels.heatSs(heatSum)
    local rateHeat = ss
    heat = tonumber(heat) or 0
    if heat > rateHeat then
        rateHeat = heat
    end
    local fromFormula = fuels.fuelDamageAtHeat(rods, rateHeat)
    if fromFormula > 0 then
        return fromFormula
    end
    return tonumber(fuelDamageLive) or 0
end

--- ETA seconds from remaining durability / fuelDamage per game tick.
function fuels.etaSeconds(remain, fuelDamagePerTick)
    remain = tonumber(remain) or 0
    fuelDamagePerTick = tonumber(fuelDamagePerTick) or 0
    if remain <= 0 or fuelDamagePerTick <= 0 then
        return nil
    end
    local ticks = remain / fuelDamagePerTick
    return ticks / 20
end

--- One entry per rod for UI (same-NBT group expands to rods lines, shared damage).
-- Each: { index, damage, maxDamage, pct } where pct is wear 0..100.
function fuels.wearEntries(fuelList)
    local out = {}
    local idx = 0
    eachFuel(fuelList, function(e)
        local r = tonumber(e.rods) or 0
        local dmg = tonumber(e.damage) or 0
        local maxD = tonumber(e.maxDamage) or 0
        local pct = 0
        if maxD > 0 then
            pct = (100 * dmg) / maxD
        end
        if r < 1 then
            r = 0
        end
        for _ = 1, r do
            idx = idx + 1
            out[#out + 1] = {
                index = idx,
                damage = dmg,
                maxDamage = maxD,
                pct = pct,
            }
        end
    end)
    return out
end

--- Max total fuel-heat allowed for temperatureMax (strict).
function fuels.maxFuelHeat(temperatureMax)
    temperatureMax = tonumber(temperatureMax) or 0
    if temperatureMax <= 0 then
        return 0
    end
    return temperatureMax * 1.01 / 200
end

--- True if adding one rod of rodHeat stays under max heat and rod cap.
function fuels.canAddRod(temperatureMax, heatSum, rodsTotal, rodHeat, rodCap)
    rodCap = tonumber(rodCap) or 5
    rodsTotal = tonumber(rodsTotal) or 0
    heatSum = tonumber(heatSum) or 0
    rodHeat = tonumber(rodHeat) or 0
    if rodsTotal >= rodCap then
        return false
    end
    if rodHeat <= 0 then
        return false
    end
    local maxH = fuels.maxFuelHeat(temperatureMax)
    return (heatSum + rodHeat) <= maxH + 1e-9
end

return fuels
