#!/usr/bin/env lua
local boot = loadfile("tests/loader.lua")()
local T = boot()
local A = T.assert

local machine_lock = require("machine_lock")

A.suite("machine_lock", {
    {
        name = "tryLock runs and releases",
        fn = function()
            local ran = false
            local ok, val = machine_lock.tryLock("m_free", "k1", function()
                ran = true
                A.truthy(machine_lock.isBusy("m_free"))
                A.eq(machine_lock.keyOf("m_free"), "k1")
                return true, 42
            end)
            A.truthy(ok)
            A.eq(val, 42)
            A.truthy(ran)
            A.falsy(machine_lock.isBusy("m_free"))
        end,
    },
    {
        name = "tryLock busy when held",
        fn = function()
            local nested = nil
            machine_lock.tryLock("m_busy", "k1", function()
                local ok, err = machine_lock.tryLock("m_busy", "k2", function() end)
                nested = { ok = ok, err = err }
            end)
            A.falsy(nested.ok)
            A.eq(nested.err.error, "busy")
        end,
    },
    {
        name = "canStack same key while held",
        fn = function()
            machine_lock.tryLock("m_stack", "same", function()
                A.truthy(machine_lock.canStack("m_stack", "same"))
                A.falsy(machine_lock.canStack("m_stack", "other"))
            end)
        end,
    },
    {
        name = "runOrStack rejects different key",
        fn = function()
            local result = nil
            machine_lock.tryLock("m_rs", "k1", function()
                local ok, err = machine_lock.runOrStack("m_rs", "k2", function() end)
                result = { ok = ok, err = err }
            end)
            A.falsy(result.ok)
            A.eq(result.err.error, "busy")
        end,
    },
    {
        name = "no_machine",
        fn = function()
            local ok, err = machine_lock.tryLock(nil, "k", function() end)
            A.falsy(ok)
            A.eq(err.error, "no_machine")
        end,
    },
})
