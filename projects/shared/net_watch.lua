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

--- Sleep seconds; return true, lastName if a peripheral attach/detach arrived.
-- Optional onHotplug(name) runs for every attach/detach in the window (burst-safe).
-- Unlike os.sleep / sleep(), does NOT discard peripheral events (pullEvent filter).
function net_watch.sleepWatch(seconds, onHotplug)
    local timer = os.startTimer(tonumber(seconds) or 0)
    local hotplug = false
    local hotName = nil
    while true do
        local ev, p1 = os.pullEvent()
        if ev == "peripheral" or ev == "peripheral_detach" then
            hotplug = true
            hotName = p1
            if type(onHotplug) == "function" then
                onHotplug(p1)
            end
            -- Keep waiting for our timer so a burst of attaches still yields once,
            -- but report hotplug so callers can rescan.
        elseif ev == "timer" and p1 == timer then
            return hotplug, hotName
        end
    end
end

--- Zero-tick yield that preserves peripheral events (use instead of sleep(0)).
function net_watch.yieldWatch(onHotplug)
    return net_watch.sleepWatch(0, onHotplug)
end

--- Sleep full duration; call onHotplug(name) on attach/detach but do not wake early.
function net_watch.sleepDrain(seconds, onHotplug)
    local timer = os.startTimer(seconds)
    while true do
        local ev, p1 = os.pullEvent()
        if ev == "timer" and p1 == timer then
            return
        elseif ev == "peripheral" or ev == "peripheral_detach" then
            if type(onHotplug) == "function" then
                onHotplug(p1)
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
