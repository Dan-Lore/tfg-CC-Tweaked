-- Autonomous cooked pizza stock maintainer for bg / dedicated computer.
-- Keeps firmalife:food/cooked_pizza at a target count via craft.request
-- (full pizza chain: grow/mill/dough/sauce/cheese/salmon/oven).
--
-- Requires on this computer: storage.cfg, recipes.cfg, and craft modules.
-- Shares machine_lock with craft_ui / wheat_grain if on the same multishell.
--
-- storage.cfg optional keys:
--   pizza_target   | 16   -- desired cooked pizza count in pullSources
--   pizza_interval | 10   -- seconds between polls when stock is full / on error
--
-- Bundle:  python tools/bundle_project.py craft pizza_maintain
-- Deploy:  dist/pizza_maintain.lua + recipes.cfg + storage.cfg

package.path = package.path
    .. ";/shared/?.lua;shared/?.lua;/craft/?.lua;craft/?.lua"

local craft = require("craft")
local storage = require("storage")
local craft_stock = require("craft_stock")
local util = require("util")

local PIZZA = "firmalife:food/cooked_pizza"

local function formatErr(detail)
    if type(detail) ~= "table" then
        return tostring(detail)
    end
    local err = detail.error or detail
    if type(err) == "table" then
        if err.missing and err.missing.name then
            local name = util.short(err.missing.name:gsub("^#", ""))
            local n = err.missing.count
            if err.fluid or (err.missing.fluid) then
                return ("NEED %s %smb"):format(name, tostring(n or "?"))
            end
            if n and n > 1 then
                return ("NEED %s x%s"):format(name, tostring(n))
            end
            return "NEED " .. name
        end
        return tostring(err.error or err.hint or "failed")
    end
    return tostring(err)
end

local function main()
    local store = storage.load()
    local list = craft.loadRequest()
    local recipe = craft.findByOutput(list, PIZZA)
    if not recipe then
        error("no cooked_pizza recipe in recipes.cfg")
    end

    local target = math.max(1, math.floor(store.getNumber("pizza_target", 16)))
    local interval = math.max(1, store.getNumber("pizza_interval", 10))
    local opts = {
        store = store,
        from = store.main(),
        out = store.main(),
        craftWaitTimeout = store.getNumber("craft_wait_timeout", 300),
        waitTicks = store.getNumber("wait_ticks", nil),
        growPulse = store.getNumber("grow_pulse", 3),
        growWaitTimeout = store.getNumber("grow_wait_timeout", 600),
    }

    print(("pizza_maintain: keep %s at %s, interval %ss"):format(
        util.short(PIZZA),
        tostring(target),
        tostring(interval)
    ))
    print("run in bg: bg pizza_maintain.lua")

    while true do
        local have = craft_stock.countAvailable(store, PIZZA, opts)
        local need = target - have
        if need <= 0 then
            sleep(interval)
        else
            print(("pizza: have %s / %s, craft +%s"):format(
                tostring(have), tostring(target), tostring(need)
            ))
            local ok, detail = craft.request(PIZZA, need, opts)
            if ok then
                local produced = detail and detail.produced or need
                local after = craft_stock.countAvailable(store, PIZZA, opts)
                print(("pizza: OK +%s (now %s / %s)"):format(
                    tostring(produced), tostring(after), tostring(target)
                ))
            else
                print("pizza: " .. formatErr(detail))
                sleep(interval)
            end
        end
    end
end

main()
