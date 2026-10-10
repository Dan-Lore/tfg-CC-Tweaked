-- Uniform craft error shape: always `false, { error = code, ... }`.

local craft_err = {}

--- @param code string
--- @param fields table|nil extra fields merged into the error table
function craft_err.fail(code, fields)
    local t = {}
    if type(fields) == "table" then
        for k, v in pairs(fields) do
            t[k] = v
        end
    end
    t.error = code or "error"
    return false, t
end

--- Normalize string-or-table detail into a table with .error.
function craft_err.asTable(detail)
    if type(detail) == "table" then
        if detail.error == nil and type(detail[1]) == "string" then
            detail.error = detail[1]
        end
        return detail
    end
    return { error = tostring(detail or "error") }
end

return craft_err
