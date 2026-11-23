-- Bounded fan-out for main-thread peripheral calls (getItem, inventory list).
-- Each such call costs ~1 server tick when issued alone; N coroutines issuing
-- them together share the same tick (within CC's main-thread time budget).

local par = {}

par.DEFAULT_WIDTH = 8

--- Run fn(i) for i = 1..n on up to `width` coroutines. width < 2 → sequential.
-- Errors inside fn are re-raised after every worker stops.
function par.each(n, fn, width)
    n = math.floor(tonumber(n) or 0)
    if n < 1 then
        return
    end
    width = math.floor(tonumber(width) or par.DEFAULT_WIDTH)
    if width < 2 or n < 2 or type(parallel) ~= "table" or type(parallel.waitForAll) ~= "function" then
        for i = 1, n do
            fn(i)
        end
        return
    end
    if width > n then
        width = n
    end
    local nextI = 0
    local firstErr = nil
    local function worker()
        while firstErr == nil do
            nextI = nextI + 1
            local i = nextI
            if i > n then
                return
            end
            local ok, err = pcall(fn, i)
            if not ok and firstErr == nil then
                firstErr = err
            end
        end
    end
    local workers = {}
    for w = 1, width do
        workers[w] = worker
    end
    local unpack = table.unpack or unpack
    parallel.waitForAll(unpack(workers))
    if firstErr ~= nil then
        error(firstErr, 0)
    end
end

return par
