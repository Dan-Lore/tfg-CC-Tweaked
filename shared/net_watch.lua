-- Shared peripheral hotplug / sleep helpers for long-running controllers.

local net_watch = {}

function net_watch.flushEvents(tag)
    tag = tag or "net_watch_flush"
    os.queueEvent(tag)
    while true do
        local ev = os.pullEvent()
        if ev == tag then
            return
        end
    end
end

--- Sleep seconds; return true if a peripheral attach/detach arrived (wakes early).
function net_watch.sleepWatch(seconds)
    local timer = os.startTimer(seconds)
    while true do
        local ev, p1 = os.pullEvent()
        if ev == "timer" and p1 == timer then
            return false
        elseif ev == "peripheral" or ev == "peripheral_detach" then
            return true
        end
    end
end

--- Sleep full duration; call onHotplug() on attach/detach but do not wake early.
function net_watch.sleepDrain(seconds, onHotplug)
    local timer = os.startTimer(seconds)
    while true do
        local ev, p1 = os.pullEvent()
        if ev == "timer" and p1 == timer then
            return
        elseif ev == "peripheral" or ev == "peripheral_detach" then
            if type(onHotplug) == "function" then
                onHotplug()
            end
        end
    end
end

function net_watch.safeCall(name, method, ...)
    local ok, a, b, c = pcall(peripheral.call, name, method, ...)
    if not ok then
        return nil
    end
    return a, b, c
end

function net_watch.safeMethod(obj, method, ...)
    if not obj or type(obj[method]) ~= "function" then
        return nil
    end
    local ok, a, b, c = pcall(obj[method], obj, ...)
    if not ok then
        return nil
    end
    return a, b, c
end

return net_watch
