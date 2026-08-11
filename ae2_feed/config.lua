-- AE2 feed balancer settings.
-- Only N is required: items pushed into each machine per craft cycle.
-- AE2 must supply exact multiples of N across the provider→machine farm.

return {
    N = 16,

    -- Substring match against peripheral name or type (case-insensitive).
    PROVIDER_SUBSTR = "pattern_provider",

    -- Optional: if set, only peripherals whose name/type contain this count as machines.
    -- Leave nil when the wired network has only machines + pattern providers.
    -- MACHINE_SUBSTR = nil,
}
