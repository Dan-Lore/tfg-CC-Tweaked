-- Bootstrap CC stubs + package.path for unit tests.
-- Usage from a test file:
--   local load_tests = loadfile("tests/loader.lua")
--   local T = load_tests({ projects = { "craft", "ae_stats" } })

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
    local parts = {
        root .. "/tests/?.lua",
        root .. "/projects/shared/?.lua",
    }
    local projList = opts.projects or {
        "craft", "shared", "ae_stats", "power", "ae2_feed",
        "crystals", "distill", "ebf", "fission", "railgun",
    }
    for i = 1, #projList do
        local name = projList[i]
        if name ~= "shared" then
            parts[#parts + 1] = root .. "/projects/" .. name .. "/?.lua"
            parts[#parts + 1] = root .. "/projects/" .. name .. "/entries/?.lua"
        end
    end
    parts[#parts + 1] = package.path
    package.path = table.concat(parts, ";")

    -- Clear cached project modules so each test file starts clean.
    local purge = {
        "util", "transfer", "cfg_pipe", "net_watch", "food",
        "recipes", "storage", "craft_io", "craft_stock", "craft_plan",
        "machine_lock", "craft_err", "greenhouse", "peripherals",
        "history", "config_common", "protocol", "config",
        "craft", "craft_monitor", "craft_grow", "craft_log",
        "discover", "recipe", "furnace", "ui", "move", "feed", "sort",
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
