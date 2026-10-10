-- Bootstrap CC stubs + package.path for unit tests.
-- Usage from a test file:
--   local load_tests = loadfile("tests/loader.lua")
--   local T = load_tests({ projects = { "craft", "shared", "ae_stats" } })

local ROOT = (arg and arg[0] and arg[0]:match("(.*/)")) or "./"
-- Prefer CWD-based absolute-ish paths via debug
local function repoRoot()
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) == "@" then
        local path = src:sub(2):gsub("\\", "/")
        local dir = path:match("^(.*)/tests/loader%.lua$")
        if dir and dir ~= "" then
            return dir
        end
    end
    return "."
end

return function(opts)
    opts = opts or {}
    local root = opts.root or repoRoot()
    package.path = table.concat({
        root .. "/tests/?.lua",
        root .. "/shared/?.lua",
        root .. "/craft/?.lua",
        root .. "/ae_stats/?.lua",
        root .. "/power/?.lua",
        root .. "/ae2_feed/?.lua",
        root .. "/crystals/?.lua",
        root .. "/distill/?.lua",
        package.path,
    }, ";")

    -- Clear cached project modules so each test file starts clean.
    local purge = {
        "util", "transfer", "cfg_pipe", "net_watch", "food",
        "recipes", "storage", "craft_io", "craft_stock", "craft_plan",
        "machine_lock", "craft_err", "greenhouse", "peripherals",
        "history", "config_common", "protocol", "config",
        "craft", "craft_monitor", "craft_grow", "craft_log",
    }
    for i = 1, #purge do
        package.loaded[purge[i]] = nil
    end

    local stub = require("cc_stub")
    stub.reset()
    stub.install()

    local assert_mod = require("assert_helpers")

    -- Default program dir so resolvePath finds test fixtures under /tests/
    stub.setRunningProgram("/tests/program.lua")

    return {
        root = root,
        stub = stub,
        assert = assert_mod,
        require = require,
    }
end
