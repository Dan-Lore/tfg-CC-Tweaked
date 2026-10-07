-- Autonomous cooked pizza stock maintainer for bg / dedicated computer.
-- Keeps firmalife:food/cooked_pizza at a target count via craft.request
-- (full pizza chain: grow/mill/dough/sauce/cheese/any meat-fish/oven).
--
-- Requires on this computer: pizza_maintain.cfg (or storage.cfg + recipes.cfg) + craft modules.
-- Shares machine_lock with craft_ui / wheat_grain if on the same multishell.
--
-- [storage] optional keys:
--   pizza_target   | 16   -- desired cooked pizza count in pullSources
--   pizza_interval | 10   -- seconds between polls when stock is full / on error
--
-- Bundle:  python tools/bundle_project.py craft pizza_maintain
-- Deploy:  dist/pizza_maintain.lua + pizza_maintain.cfg

package.path = package.path
    .. ";/shared/?.lua;shared/?.lua;/craft/?.lua;craft/?.lua"

local craft = require("craft")
local storage = require("storage")
local craft_stock = require("craft_stock")
local craft_log = require("craft_log")
local util = require("util")

local PIZZA = "firmalife:food/cooked_pizza"

local function log(msg)
    craft_log.write(msg)
end

local function formatErr(detail)
    if type(detail) ~= "table" then
        return tostring(detail)
    end
    local err = detail.error or detail
    if type(err) == "table" then
        if err.missing and err.missing.name then
            local raw = tostring(err.missing.name)
            -- Exceptions / planning errors include "/file.lua:line: …" — don't show as NEED item.
            if raw:find("planning:", 1, true) or raw:find("Too long", 1, true) or raw:find("%.lua:") then
                return "BUSY " .. raw:sub(1, 36)
            end
            local name = util.short(raw:gsub("^#", ""))
            local n = err.missing.count
            if err.fluid or err.missing.fluid then
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

local function isTransient(detail)
    if type(detail) ~= "table" then
        return false
    end
    local miss = detail.missing or (type(detail.error) == "table" and detail.error.missing)
    local name = miss and tostring(miss.name or "") or ""
    return name:find("planning:", 1, true)
        or name:find("Too long", 1, true)
        or name:find("%.lua:")
        or detail.error == "exception"
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
    craft_log.open(store.get("log_monitor", "left"), store.getNumber("log_text_scale", 0.5))

    local opts = {
        store = store,
        from = store.main(),
        out = store.main(),
        craftWaitTimeout = store.getNumber("craft_wait_timeout", 300),
        waitTicks = store.getNumber("wait_ticks", nil),
        growPulse = store.getNumber("grow_pulse", 3),
        growWaitTimeout = store.getNumber("grow_wait_timeout", 600),
    }

    log(("pizza keep %s @%s /%ss"):format(
        util.short(PIZZA),
        tostring(target),
        tostring(interval)
    ))

    while true do
        local have = craft_stock.countAvailable(store, PIZZA, opts)
        local need = target - have
        if need <= 0 then
            sleep(interval)
        else
            log(("pizza %s/%s +%s"):format(
                tostring(have), tostring(target), tostring(need)
            ))
            local ok, detail = craft.request(PIZZA, need, opts)
            if ok then
                local produced = detail and detail.produced or need
                local after = craft_stock.countAvailable(store, PIZZA, opts)
                log(("pizza OK +%s now %s/%s"):format(
                    tostring(produced), tostring(after), tostring(target)
                ))
            else
                log("pizza " .. formatErr(detail))
                -- Hard missing (no ingredient) → full interval; Lua/TLYW → quick retry.
                sleep(isTransient(detail) and 1 or interval)
            end
        end
    end
end

main()
