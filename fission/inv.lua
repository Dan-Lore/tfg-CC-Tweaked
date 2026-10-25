-- Inventory moves: stock → input (allow only), buses → AE. Never into crates.

local transfer = require("transfer")
local fuels = require("fuels")
local net_watch = require("net_watch")

local M = {}

local function wrapInv(name)
    if not name or not peripheral.isPresent(name) then
        return nil
    end
    local p = peripheral.wrap(name)
    if not p or type(p.list) ~= "function" or type(p.pushItems) ~= "function" then
        return nil
    end
    return p
end

local function listSlots(p)
    local ok, listed = pcall(p.list)
    if not ok or type(listed) ~= "table" then
        return {}
    end
    return listed
end

--- Push every item from `fromName` into AE (or any sink). Returns moved count.
function M.drainAll(fromName, toName)
    if not fromName or not toName or fromName == toName then
        return 0
    end
    local p = wrapInv(fromName)
    if not p or not peripheral.isPresent(toName) then
        return 0
    end
    local moved = 0
    local listed = listSlots(p)
    local n = 0
    for slot, item in pairs(listed) do
        if item and item.count and item.count > 0 then
            local ok, got = pcall(p.pushItems, toName, slot)
            if ok and type(got) == "number" then
                moved = moved + got
            end
        end
        n = n + 1
        if n % 8 == 0 then
            net_watch.yieldWatch()
        end
    end
    return moved
end

--- Move disallowed items from input bus → AE. Allowed stay (will be eaten).
function M.scrubInput(busName, allowSet, aeName)
    if not busName or not aeName or not allowSet then
        return 0
    end
    local p = wrapInv(busName)
    if not p or not peripheral.isPresent(aeName) then
        return 0
    end
    local moved = 0
    local listed = listSlots(p)
    local n = 0
    for slot, item in pairs(listed) do
        if item and item.name and not allowSet[item.name] then
            local ok, got = pcall(p.pushItems, aeName, slot)
            if ok and type(got) == "number" then
                moved = moved + got
            end
        end
        n = n + 1
        if n % 8 == 0 then
            net_watch.yieldWatch()
        end
    end
    return moved
end

--- Count a single item id in an inventory.
function M.countItem(invName, itemId)
    if not invName or not itemId then
        return 0
    end
    return transfer.countItem(invName, itemId)
end

--- Pellets available: AE source + already on pellet bus.
function M.countPellets(cfg, reactorCfg)
    local item = cfg.pellet
    local n = 0
    if cfg.ae then
        n = n + M.countItem(cfg.ae, item)
    end
    if reactorCfg.pellet_bus then
        n = n + M.countItem(reactorCfg.pellet_bus, item)
    end
    return n
end

--- Keep pellet bus topped up from AE while a cycle needs cooling.
function M.feedPellets(cfg, reactorCfg, wantOnBus)
    wantOnBus = tonumber(wantOnBus) or 8
    local item = cfg.pellet
    local bus = reactorCfg.pellet_bus
    local ae = cfg.ae
    if not bus or not ae or not item then
        return 0
    end
    if not peripheral.isPresent(bus) or not peripheral.isPresent(ae) then
        return 0
    end
    local onBus = M.countItem(bus, item)
    local need = wantOnBus - onBus
    if need <= 0 then
        return 0
    end
    return transfer(ae, bus, item, need)
end

--- Count stock items matching any allow-list id.
function M.countStock(stockName, allowList)
    if not stockName or not allowList then
        return 0
    end
    local total = 0
    for i = 1, #allowList do
        total = total + transfer.countItem(stockName, allowList[i])
    end
    return total
end

--- Count allow-listed items already sitting on the input bus (not yet eaten).
function M.countPending(busName, allowSet)
    if not busName or not allowSet or not peripheral.isPresent(busName) then
        return 0
    end
    local p = wrapInv(busName)
    if not p then
        return 0
    end
    local total = 0
    for _, item in pairs(listSlots(p)) do
        if item and item.name and allowSet[item.name] then
            total = total + (item.count or 0)
        end
    end
    return total
end

--- Push up to `limit` allow-listed rods stock → input, only if each fits heat budget.
-- Re-reads reactor between pushes. Returns rods pushed.
function M.feedRods(cfg, reactorCfg, state)
    local stock = reactorCfg.stock
    local input = reactorCfg.input
    local controller = reactorCfg.controller
    local allowSet = reactorCfg.allowSet
    local rodCap = cfg.rod_cap or 5

    if not stock or not input or not controller then
        return 0
    end
    if not peripheral.isPresent(stock) or not peripheral.isPresent(input) then
        return 0
    end
    if not peripheral.isPresent(controller) then
        return 0
    end

    local p = wrapInv(stock)
    if not p then
        return 0
    end

    local pushed = 0
    local temperatureMax = state.temperatureMax or 0
    local rodsTotal = state.rods or 0
    local heatSum = state.heatSum or 0
    local limit = state.needed or 0
    if limit <= 0 then
        return 0
    end

    local listed = listSlots(p)
    local slots = {}
    for slot in pairs(listed) do
        slots[#slots + 1] = slot
    end
    table.sort(slots)

    for si = 1, #slots do
        if pushed >= limit or rodsTotal >= rodCap then
            break
        end

        local slot = slots[si]
        local item = listed[slot]
        if item and item.name and allowSet[item.name] then
            local h = fuels.heatOf(cfg, item.name)
            if h and fuels.canAddRod(temperatureMax, heatSum, rodsTotal, h, rodCap) then
                local ok, got = pcall(p.pushItems, input, slot, 1)
                if ok and type(got) == "number" and got > 0 then
                    pushed = pushed + got
                    local okF, fuelList = pcall(peripheral.call, controller, "getFuels")
                    if okF then
                        rodsTotal, heatSum = fuels.summarizeInstalled(fuelList)
                    else
                        rodsTotal = rodsTotal + got
                        heatSum = heatSum + h * got
                    end
                    local okM, metrics = pcall(peripheral.call, controller, "getMetrics")
                    if okM and type(metrics) == "table" and metrics.temperatureMax ~= nil then
                        temperatureMax = tonumber(metrics.temperatureMax) or temperatureMax
                    end
                end
            end
        end
        if si % 4 == 0 then
            net_watch.yieldWatch()
        end
    end

    state.rods = rodsTotal
    state.heatSum = heatSum
    state.temperatureMax = temperatureMax
    return pushed
end

return M
