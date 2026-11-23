-- Rednet protocol: Earth controller <-> Moon stock probe (ender modem).

local protocol = {}

protocol.NAME = "tfg_moon_supply"
protocol.HOST = "moon_supply_probe"

-- Message kinds:
--   stock_req { kind, items = { id, ... } }  -- Earth owns the watchlist
--   stock_res { kind, stocks = { [id] = amount } }
--   hello     { kind, role }

function protocol.encode(msg)
    return textutils.serialize(msg)
end

function protocol.decode(payload)
    if type(payload) ~= "string" then
        return nil
    end
    local ok, msg = pcall(textutils.unserialize, payload)
    if not ok or type(msg) ~= "table" or type(msg.kind) ~= "string" then
        return nil
    end
    return msg
end

function protocol.send(id, msg)
    return rednet.send(id, protocol.encode(msg), protocol.NAME)
end

function protocol.broadcast(msg)
    return rednet.broadcast(protocol.encode(msg), protocol.NAME)
end

--- Wait for a message matching kind (and optional from id). Timeout in seconds.
function protocol.receive(timeout, wantKind, fromId)
    local deadline = timeout and (os.clock() + timeout) or nil
    while true do
        local left = nil
        if deadline then
            left = deadline - os.clock()
            if left <= 0 then
                return nil
            end
        end
        local id, payload = rednet.receive(protocol.NAME, left)
        if not id then
            return nil
        end
        if fromId and id ~= fromId then
            -- keep waiting
        else
            local msg = protocol.decode(payload)
            if msg and (not wantKind or msg.kind == wantKind) then
                return id, msg
            end
        end
    end
end

--- Request stocks for item ids from moon host. Returns stocks table or nil, err.
function protocol.requestStocks(itemIds, opts)
    opts = opts or {}
    local timeout = tonumber(opts.timeout) or 5
    local hostId = opts.host_id
    if not hostId then
        hostId = rednet.lookup(protocol.NAME, protocol.HOST)
    end
    if not hostId then
        return nil, "луна не в сети"
    end
    protocol.send(hostId, { kind = "stock_req", items = itemIds or {} })
    local id, msg = protocol.receive(timeout, "stock_res", hostId)
    if not msg or type(msg.stocks) ~= "table" then
        return nil, "луна не ответила"
    end
    return msg.stocks, nil, hostId
end

return protocol
