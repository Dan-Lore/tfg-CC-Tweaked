-- Buffer → empty hatch fluid distribution (round-robin).

local transfer = require("transfer")

local move = {}

--- Total mb across all tanks on a peripheral.
function move.totalFluid(name)
    if not name or not peripheral.isPresent(name) then
        return 0
    end
    local tank = peripheral.wrap(name)
    if not tank or type(tank.tanks) ~= "function" then
        return 0
    end
    local ok, tanks = pcall(tank.tanks)
    if not ok or type(tanks) ~= "table" then
        return 0
    end
    local total = 0
    for _, t in pairs(tanks) do
        if t and t.amount then
            total = total + (tonumber(t.amount) or 0)
        end
    end
    return total
end

function move.isEmpty(name)
    return move.totalFluid(name) == 0
end

--- Hatches with zero fluid (ready for a fresh amount push).
function move.emptyHatches(hatches)
    local free = {}
    if not hatches then
        return free
    end
    for i = 1, #hatches do
        local h = hatches[i]
        if peripheral.isPresent(h) and move.isEmpty(h) then
            free[#free + 1] = h
        end
    end
    return free
end

--- Sorted unique fluid names in buffer with amount >= minAmount.
function move.eligibleFluids(bufferName, minAmount)
    local out = {}
    minAmount = tonumber(minAmount) or 0
    if not bufferName or not peripheral.isPresent(bufferName) or minAmount <= 0 then
        return out
    end
    local tank = peripheral.wrap(bufferName)
    if not tank or type(tank.tanks) ~= "function" then
        return out
    end
    local ok, tanks = pcall(tank.tanks)
    if not ok or type(tanks) ~= "table" then
        return out
    end

    local totals = {}
    for _, t in pairs(tanks) do
        if t and t.name then
            local n = tostring(t.name)
            totals[n] = (totals[n] or 0) + (tonumber(t.amount) or 0)
        end
    end

    for name, amt in pairs(totals) do
        if amt >= minAmount then
            out[#out + 1] = name
        end
    end
    table.sort(out)
    return out
end

--- Hatch health: ok (exactly want mb), empty (0), bad (other).
function move.hatchStats(hatches, want)
    want = tonumber(want) or 0
    local okN, emptyN, badN = 0, 0, 0
    if not hatches then
        return okN, emptyN, badN
    end
    for i = 1, #hatches do
        local h = hatches[i]
        if peripheral.isPresent(h) then
            local total = move.totalFluid(h)
            if total == want then
                okN = okN + 1
            elseif total == 0 then
                emptyN = emptyN + 1
            else
                badN = badN + 1
            end
        else
            badN = badN + 1
        end
    end
    return okN, emptyN, badN
end

local function shortFluid(name, maxLen)
    name = tostring(name or "")
    local short = name:match("([^:/]+)$") or name
    maxLen = maxLen or 16
    if #short <= maxLen then
        return short
    end
    return short:sub(1, maxLen - 1) .. "."
end

--- Round-robin push: one exact `amount` into each empty hatch while stock lasts.
-- state: { fluidRR=, hatchRR= } mutated. Returns pushed count, lastFluid.
function move.distribute(bufferName, hatches, amount, state, onYield)
    amount = tonumber(amount) or 0
    state = state or {}
    state.fluidRR = tonumber(state.fluidRR) or 0
    state.hatchRR = tonumber(state.hatchRR) or 0

    if amount <= 0 or not bufferName or not hatches then
        return 0, nil
    end

    local empty = move.emptyHatches(hatches)
    local fluids = move.eligibleFluids(bufferName, amount)
    if #empty == 0 or #fluids == 0 then
        return 0, nil
    end

    local pushed = 0
    local lastFluid = nil
    local nEmpty = #empty
    local startH = state.hatchRR

    for i = 0, nEmpty - 1 do
        fluids = move.eligibleFluids(bufferName, amount)
        if #fluids == 0 then
            break
        end

        local hi = ((startH + i) % nEmpty) + 1
        local hatch = empty[hi]

        -- Still empty? (another process / race)
        if not move.isEmpty(hatch) then
            if onYield then
                onYield()
            else
                sleep(0)
            end
        else
            local fi = ((state.fluidRR) % #fluids) + 1
            local fluid = fluids[fi]
            -- If this fluid somehow dipped below amount, walk RR for a viable one.
            if transfer.countFluid(bufferName, fluid) < amount then
                fluid = nil
                for j = 0, #fluids - 1 do
                    local cand = fluids[((state.fluidRR + j) % #fluids) + 1]
                    if transfer.countFluid(bufferName, cand) >= amount then
                        fluid = cand
                        state.fluidRR = state.fluidRR + j
                        break
                    end
                end
            end

            if not fluid then
                break
            end

            local got = transfer.fluid(bufferName, hatch, fluid, amount) or 0
            if got == amount then
                pushed = pushed + 1
                lastFluid = fluid
                state.fluidRR = state.fluidRR + 1
            end

            if onYield then
                onYield()
            else
                sleep(0)
            end
        end
    end

    state.hatchRR = startH + nEmpty
    return pushed, lastFluid and shortFluid(lastFluid, 18) or nil
end

move.shortFluid = shortFluid

return move
