-- Moon stock probe: ME bridge + ender modem; answer Earth's stock_req.
-- Watchlist and targets live only on Earth (moon_supply_E_ctrl.cfg).
--
-- Bundle:  python tools/bundle_project.py moon_supply moon_supply_M_probe
-- Deploy:  dist/moon_supply_M_probe.lua + moon_supply_M_probe.cfg

package.path = package.path
    .. ";/projects/moon_supply/?.lua;projects/moon_supply/?.lua"
    .. ";/projects/shared/?.lua;projects/shared/?.lua"

local configMod = require("config")
local protocol = require("protocol")
local ae_bridge = require("ae_bridge")
local discover = require("discover")

local cfg = configMod.loadMoon()
local bridgeName = nil
local bridge = nil
local lastReqCount = 0

local function openModem()
    local side = discover.modem(cfg)
    if not side or not peripheral.isPresent(side) then
        error("moon_supply moon: no modem on " .. tostring(cfg.modem))
    end
    rednet.open(side)
    rednet.host(protocol.NAME, protocol.HOST)
    print("moon_supply moon: rednet host " .. protocol.HOST .. " on " .. tostring(side))
end

local function refreshBridge()
    bridgeName = discover.bridge(cfg)
    bridge = nil
    if bridgeName then
        bridge = peripheral.wrap(bridgeName)
    end
    if not bridge then
        local p, n = ae_bridge.wrap(cfg.bridge)
        bridge, bridgeName = p, n
    end
    return bridge ~= nil
end

local function stocksFor(ids)
    local stocks = {}
    if not bridge then
        refreshBridge()
    end
    for i = 1, #(ids or {}) do
        local id = ids[i]
        if type(id) == "string" then
            stocks[id] = ae_bridge.getItemAmount(bridge, id)
        end
        if i % 8 == 0 then
            sleep(0)
        end
    end
    return stocks
end

local function handle(sender, msg)
    if msg.kind == "hello" then
        protocol.send(sender, { kind = "hello", role = "moon" })
    elseif msg.kind == "stock_req" then
        local ids = msg.items
        if type(ids) ~= "table" then
            ids = {}
        end
        lastReqCount = #ids
        local stocks = stocksFor(ids)
        protocol.send(sender, { kind = "stock_res", stocks = stocks })
    end
end

openModem()
if refreshBridge() then
    print("moon_supply moon: bridge " .. tostring(bridgeName))
else
    print("moon_supply moon: waiting for meBridge...")
end
print("moon_supply moon: watchlist from Earth stock_req")

while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "rednet_message" and c == protocol.NAME then
        local msg = protocol.decode(b)
        if msg then
            if not bridge then
                refreshBridge()
            end
            local ok, err = pcall(handle, a, msg)
            if not ok then
                print("moon_supply moon: " .. tostring(err))
            elseif msg.kind == "stock_req" then
                print("moon_supply moon: replied " .. tostring(lastReqCount) .. " id(s)")
            end
        end
    elseif ev == "peripheral" or ev == "peripheral_detach" then
        refreshBridge()
    end
end
