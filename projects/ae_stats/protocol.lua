-- Rednet protocol for ae_stats sampler <-> display <-> graphview.

local protocol = {}

protocol.NAME = "tfg_ae_stats"
protocol.HOST = "ae_stats_sampler"
protocol.GRAPH_HOST = "ae_stats_graph"

-- Message kinds:
--   hello      { kind, role }                    sampler announce / display ping
--   list_req   { kind, q, offset, limit, reply }
--   list_res   { kind, items, total, q }
--   track_set  { kind, items }                   legacy no-op on sampler
--   track_ack  { kind, items }
--   history_req{ kind, item, since, reply }
--   history_res{ kind, item, points, amount }
--   sample     { kind, item, t, amount }         broadcast from sampler
--   focus_set  { kind, item, window?, step?, interp? }  display → graphview


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
        local id, payload, proto = rednet.receive(protocol.NAME, left)
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

return protocol
