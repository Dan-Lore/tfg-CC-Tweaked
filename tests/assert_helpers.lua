-- Tiny assert helpers for Lua tests.

local A = {}

local function fail(msg)
    error(msg, 3)
end

function A.eq(actual, expected, msg)
    if actual ~= expected then
        fail(string.format(
            "%s\n  expected: %s\n  actual:   %s",
            msg or "values not equal",
            tostring(expected),
            tostring(actual)
        ))
    end
end

function A.neq(actual, unexpected, msg)
    if actual == unexpected then
        fail(string.format("%s\n  did not expect: %s", msg or "values equal", tostring(unexpected)))
    end
end

function A.truthy(v, msg)
    if not v then
        fail(msg or "expected truthy")
    end
end

function A.falsy(v, msg)
    if v then
        fail(msg or "expected falsy")
    end
end

function A.isNil(v, msg)
    if v ~= nil then
        fail(msg or ("expected nil, got " .. tostring(v)))
    end
end

function A.tblEq(actual, expected, msg)
    if type(actual) ~= "table" or type(expected) ~= "table" then
        fail(msg or "tblEq needs tables")
    end
    for k, v in pairs(expected) do
        if actual[k] ~= v then
            fail(string.format(
                "%s\n  key %s expected %s got %s",
                msg or "table mismatch",
                tostring(k),
                tostring(v),
                tostring(actual[k])
            ))
        end
    end
    for k in pairs(actual) do
        if expected[k] == nil and actual[k] ~= nil then
            -- allow extra keys only if expected is a partial? require exact for arrays
        end
    end
end

function A.contains(list, value, msg)
    for i = 1, #list do
        if list[i] == value then
            return
        end
    end
    fail(msg or ("list missing " .. tostring(value)))
end

function A.throws(fn, needle, msg)
    local ok, err = pcall(fn)
    if ok then
        fail(msg or "expected error")
    end
    if needle and not tostring(err):find(needle, 1, true) then
        fail(string.format("%s\n  error %q missing %q", msg or "wrong error", tostring(err), needle))
    end
end

function A.run(name, fn)
    local ok, err = pcall(fn)
    if ok then
        print("  PASS  " .. name)
        return true
    end
    print("  FAIL  " .. name)
    print("        " .. tostring(err))
    return false
end

function A.suite(title, tests)
    print("== " .. title)
    local failed = 0
    for i = 1, #tests do
        local t = tests[i]
        if not A.run(t.name, t.fn) then
            failed = failed + 1
        end
    end
    if failed > 0 then
        print(string.format("== %s: %d failed", title, failed))
        error("SUITE_FAILED:" .. tostring(failed), 0)
    end
    print(string.format("== %s: ok (%d)", title, #tests))
end

return A
