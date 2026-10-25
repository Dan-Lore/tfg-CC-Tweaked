-- Runtime dump: control mode + one-cycle arm. Survives reboot; overrides cfg defaults.

local util = require("util")

local state = {}

local DEFAULT_NAME = "fission_state.txt"

local function pathOf(cfg)
    local name = (cfg and cfg.state_file) or DEFAULT_NAME
    return util.resolvePath(name, DEFAULT_NAME)
end

--- Build default runtime rows from cfg reactors.
function state.defaultsFromCfg(cfg)
    local rows = {}
    for i = 1, #(cfg.reactors or {}) do
        local r = cfg.reactors[i]
        rows[r.controller] = {
            controller = r.controller,
            label = r.label,
            control = r.control or "auto", -- auto | manual
            cycle = false, -- armed one-cycle (manual semi-auto)
        }
    end
    return rows
end

function state.load(cfg)
    local rows = state.defaultsFromCfg(cfg)
    local path = pathOf(cfg)
    if not fs.exists(path) then
        return rows, path, false
    end
    local f = fs.open(path, "r")
    if not f then
        return rows, path, false
    end
    while true do
        local line = f.readLine()
        if not line then
            break
        end
        line = util.trim(line)
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local parts = util.split(line, "|")
            for i = 1, #parts do
                parts[i] = util.trim(parts[i])
            end
            local key = (parts[1] or ""):lower()
            if key == "reactor" and parts[2] and parts[3] then
                -- reactor | <controller> | auto|manual | cycle(0|1)
                local ctrl = parts[2]
                local control = (parts[3] or "auto"):lower()
                if control ~= "manual" then
                    control = "auto"
                end
                local cycle = parts[4] == "1" or parts[4] == "true"
                if rows[ctrl] then
                    rows[ctrl].control = control
                    rows[ctrl].cycle = cycle and control == "manual"
                end
            end
        end
    end
    f.close()
    return rows, path, true
end

function state.save(cfg, rows)
    local path = pathOf(cfg)
    local f = fs.open(path, "w")
    if not f then
        return false, path
    end
    f.writeLine("# fission_state.txt — runtime dump (overrides fission.cfg modes)")
    f.writeLine("# reactor | <controller> | auto|manual | cycle(0|1)")
    f.writeLine("version | 1")
    local order = {}
    for ctrl, row in pairs(rows) do
        order[#order + 1] = ctrl
    end
    table.sort(order)
    for i = 1, #order do
        local row = rows[order[i]]
        f.writeLine(string.format(
            "reactor | %s | %s | %d",
            row.controller,
            row.control or "auto",
            (row.cycle and 1) or 0
        ))
    end
    f.close()
    return true, path
end

return state
