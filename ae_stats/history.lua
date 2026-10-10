-- Per-item time series: ring buffer + optional disk persist.

local util = require("util")

local history = {}

local DEFAULT_RETAIN = 2.5 * 3600 -- seconds

local function now()
    return os.epoch("utc") / 1000
end

local function prune(self, item)
    local pts = self.series[item]
    if not pts then
        return
    end
    local cutoff = now() - self.retain
    local i = 1
    while i <= #pts and pts[i].t < cutoff do
        i = i + 1
    end
    if i > 1 then
        local trimmed = {}
        for j = i, #pts do
            trimmed[#trimmed + 1] = pts[j]
        end
        self.series[item] = trimmed
    end
end

local methods = {}

function methods:add(item, amount, t)
    if not item then
        return
    end
    t = t or now()
    amount = tonumber(amount) or 0
    local pts = self.series[item]
    if not pts then
        pts = {}
        self.series[item] = pts
    end
    local last = pts[#pts]
    if last and math.abs(last.t - t) < 0.5 then
        last.amount = amount
        last.t = t
    else
        pts[#pts + 1] = { t = t, amount = amount }
    end
    prune(self, item)
end

function methods:get(item, since)
    local pts = self.series[item] or {}
    if not since then
        return pts
    end
    local out = {}
    for i = 1, #pts do
        if pts[i].t >= since then
            out[#out + 1] = pts[i]
        end
    end
    return out
end

function methods:latest(item)
    local pts = self.series[item]
    if not pts or #pts == 0 then
        return nil
    end
    return pts[#pts]
end

function methods:items()
    local keys = {}
    for k in pairs(self.series) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    return keys
end

function methods:save()
    if not self.path then
        return false
    end
    local file = fs.open(self.path, "w")
    if not file then
        return false
    end
    file.write(textutils.serialize({
        retain = self.retain,
        series = self.series,
    }))
    file.close()
    return true
end

function methods:load()
    if not self.path or not fs.exists(self.path) then
        return false
    end
    local text = util.readAll(self.path)
    if not text then
        return false
    end
    local ok, data = pcall(textutils.unserialize, text)
    if not ok or type(data) ~= "table" or type(data.series) ~= "table" then
        return false
    end
    self.series = data.series
    if data.retain then
        self.retain = data.retain
    end
    for item in pairs(self.series) do
        prune(self, item)
    end
    return true
end

function history.new(opts)
    opts = opts or {}
    local self = {
        retain = opts.retain or DEFAULT_RETAIN,
        path = opts.path,
        series = {},
    }
    for k, v in pairs(methods) do
        self[k] = v
    end
    return self
end

return history
