-- Per-item time series: ring buffer + optional disk persist.

local util = require("util")

local history = {}

local DEFAULT_RETAIN = 2.5 * 3600 -- seconds
local DEFAULT_MAX_SERIES = 512

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

--- Drop oldest-touched series keys when over max_series.
local function pruneSeriesKeys(self)
    local max = self.max_series
    if not max or max <= 0 then
        return
    end
    local count = 0
    for _ in pairs(self.series) do
        count = count + 1
    end
    if count <= max then
        return
    end
    local keys = {}
    for k in pairs(self.series) do
        keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b)
        local ta = self.touched[a] or 0
        local tb = self.touched[b] or 0
        if ta ~= tb then
            return ta < tb
        end
        return tostring(a) < tostring(b)
    end)
    local remove = count - max
    for i = 1, remove do
        local k = keys[i]
        self.series[k] = nil
        self.touched[k] = nil
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
    self.touched[item] = t
    self.dirty = true
    prune(self, item)
    pruneSeriesKeys(self)
end

function methods:get(item, since)
    local pts = self.series[item] or {}
    if item then
        self.touched[item] = now()
    end
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
    if not self.dirty and fs.exists(self.path) then
        return true
    end
    pruneSeriesKeys(self)
    local file = fs.open(self.path, "w")
    if not file then
        return false
    end
    file.write(textutils.serialize({
        retain = self.retain,
        max_series = self.max_series,
        series = self.series,
    }))
    file.close()
    self.dirty = false
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
    if data.max_series then
        self.max_series = data.max_series
    end
    self.touched = {}
    for item, pts in pairs(self.series) do
        local lastT = 0
        if type(pts) == "table" and #pts > 0 then
            lastT = pts[#pts].t or 0
        end
        self.touched[item] = lastT
        prune(self, item)
    end
    pruneSeriesKeys(self)
    self.dirty = false
    return true
end

function history.new(opts)
    opts = opts or {}
    local self = {
        retain = opts.retain or DEFAULT_RETAIN,
        max_series = opts.max_series or DEFAULT_MAX_SERIES,
        path = opts.path,
        series = {},
        touched = {},
        dirty = false,
    }
    for k, v in pairs(methods) do
        self[k] = v
    end
    return self
end

return history
