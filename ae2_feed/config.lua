-- Even N-per-machine feed from storages.
-- Auto-detect storages (crate/barrel/chest/…) and machines, or pin names explicitly.

return {
    -- Items pushed into each free machine per cycle.
    N = 16,

    -- Explicit names replace auto for that role when non-empty.
    -- STORAGES = { "gtceu:stainless_steel_crate_1" },
    -- MACHINES = { "gtceu:hv_extruder_4", "gtceu:hv_extruder_5" },

    -- Auto needles when explicit list is unset.
    -- nil = built-in storage keywords; string or { "crate", "barrel" } = custom.
    STORAGE_SUBSTR = nil,

    -- Optional machine filter; nil = every non-storage inventory.
    -- MACHINE_SUBSTR = "extruder",
}
