# fission — exploration notes (Dea's Fission / TFG)

Mod in pack: **Dea's Fission** (`deafission`), not fusion. GT multiblock heat-battery reactor.

Temporary probe layout: one computer, monitor **right** (4×3), `fission_reactor_0`, test crate `gtceu:steel_crate_1`.  
Probe script: `fission/probe.lua` → dump also in `fission_probe.txt` on the computer.

Target: one computer, **two** reactors. **Spec confirmed** → `.cursor/rules/fission.mdc`.

## Layout (confirmed)

| Role | Peripheral |
|---|---|
| Reactor 1 (thorium **only**) | `fission_reactor_0` |
| R1 input bus | `gtceu:hv_input_bus_0` |
| R1 output bus | `gtceu:hv_output_bus_0` |
| Reactor 2 (uranium; later Pu / hybrid OK) | `fission_reactor_1` |
| R2 input bus | `gtceu:hv_input_bus_1` |
| R2 output bus | `gtceu:hv_output_bus_1` |
| Depleted → AE | `ae2:interface_0` |
| Thorium stock | `gtceu:wood_crate_2` |
| Uranium stock | `gtceu:wood_crate_3` |

Hard rule: never feed anything but thorium into reactor 0 / its input bus.

## Behaviour (confirmed) — see also `fission.mdc`

1. `N = min(5, floor(temperatureMax / ss_1))`, `ss_1 = rodHeat * 200 / 1.01`, **no margin**.
2. Recalc when `temperatureMax` / fuels change.
3. Drain all HV output bus items → `ae2:interface_0` (no live-rod extract from core).
4. Script owns all item moves; no redstone locks.
5. Never push disallowed fuel; if already on input bus → **`ae2:interface_0` only**. Never deposit into stock crates (pull-only). Implemented in `inv.scrubInput` / `inv.drainAll`.
6. Soft alert: stock &lt; N; hard: stock &lt; needed now. Wait; no fuel substitution.
7. Monitor right, Russian, both reactors.
8. `temperatureMax` dynamic from holders.

### Check @ temperatureMax = 420 (strict, no margin)

| Fuel | heat | ss @ 1 | N = floor(Tmax/ss_1)≤5 | ss @ N |
|---|---|---|---|---|
| thorium 0.7 | 0.7 | ~138.6 | **3** | ~416 ≤ 420 |
| uranium 2.2 | 2.2 | ~435.6 | **0** | 1 rod ~436 > 420 |

Observed: 2× thorium → `heating=280` = 2×0.7×200; `heatPost≈277` ≈ 280/1.01. Formula OK.

Uranium needs `temperatureMax ≥ ss_1` (~436) before the script will insert 1 rod.

### Pellet cooling draft (user, 2026-10-24 / corrected)

- Stock Pu rods: `gtceu:wood_crate_4`
- R1 coolant bus: `gtceu:mv_input_bus_1` — `tfg:terrafirmaguard_pa6`
- AE interface orders pellets ×64
- **Cooling:** −40 HU/t **per 100 reactor heat** per active pellet  
  → `pelletCool = 40 × (heat/100) × P = 0.4 × P × heat` (still ~30 s each, pending confirm)

Steady (full fluid coolant + P pellets), 1× Pu heating = 600 HU/t:

`600 = heat × (1.01 + 0.4·P)` → `heat = 600 / (1.01 + 0.4·P)`

**1× plutonium @ temperatureMax 440:**

| P | ~ss heat | vs 440 |
|---|---|---|
| 0 | ~594 | over |
| 1 | ~426 | OK |
| 2 | ~331 | OK |

→ **1 гранула одновременно** достаточно (ss ~426 ≤ 440).

### Empirical Pu cycle (user test, 2026-10-25)

- 19× glacian wool casings → `temperatureMax` **438**
- 1× material holder; recipe `plutonium_coolant`
- Observed: heat **426/438**, heating 600, fuelDamage **0.85**, cooling ~430, processing **-170**
- **One full work cycle burned 253 pellets** → cfg uses **256** with margin

### R2 layout

- `fission_reactor_2` + `hv_input_bus_2` / `hv_output_bus_2` + stock `wood_crate_4`
- Pellet bus: `gtceu:mv_input_bus_2` (cfg; confirm in-world name)
- Default **manual**; Th/U **auto**. Dump `fission_state.txt` overrides modes.
- Pellet items: `tfg:terrafirmaguard_pa6` (heat_per_tick 40, ~30s) and `tfg:refrigerant_pellet` (heat 5, ~10s). Count both; cfg may list several `pellet |` lines.
- Count pellets on `pellet_bus` **and** AE interface **local buffer** (stored slots). Do not use an ME Bridge / full-network peripheral for counting.

### Fuel lifetime (default ReactorCurve)

`getFuelWear = Heat/500` per cell/tick. JEI 1250s for Pu assumes heat≈600; real ss≈426 burns slower.

## CC peripheral

- Name: `fission_reactor_N` (e.g. `fission_reactor_0`)
- Type: `fission_reactor`
- Methods only:
  - `getVersion()` → `1`
  - `getMetrics()` → table (see below)
  - `getFuels()` → list of fuel groups
- **No** activate / scram / set via CC. Reactor **auto-starts** when a fuel rod is put into the input item hatch (item vanishes into the reactor). Control = careful rod feeding, not redstone on/off (unless redstone_port used separately).

Source reference: `FissionCcReactorPeripheral` in Vazde/minecraft-fission (Bitbucket).

## getMetrics (observed)

| Key | Example | Meaning |
|---|---|---|
| `heatPre` / `heatPost` | ~277 | Reactor heat before/after tick |
| `temperatureMax` | 420 | Overheat ceiling |
| `components.heat` | 420 | Component contribution to max heat (not current temp) |
| `components.throttle` / `.efficiency` | 0 / 0 | Installed component stats |
| `heating` / `cooling` | 280 / ~280 | Heat delta contributions this tick |
| `coolantUse` | ~3.54 | Wanted coolant mB |
| `coolantPercent` | 1 | Fraction of coolant actually extracted (1 = full) |
| `fuelDamage` | ~1.11 | Total fuel durability lost this tick |
| `thermalMass` | 1000 | Divisor for net heat delta |
| `throttle` | 1 | Effective throttle |
| `minHeat` | 0 | Curve min |
| `processing` | 0 | Heat used for processing recipes (EBF-style) |
| `mode` | `"DEFAULT"` | Operating mode |
| `recipe` | `tfg:fission_reactor_coolant/thorium_coolant` | Active coolant recipe id |

## getFuels

Each entry (same-NBT rods merge into one entry):

| Key | Meaning |
|---|---|
| `rods` | Count of rods in this NBT group |
| `damage` / `maxDamage` | Durability of that group |
| `heat` | **Fuel rating**, not reactor temp. `1.0` = 100%, `0.7` = 70% (`FuelCellItem.Heat`) |
| `id` | Item id in source API; may be absent/nil in CC dump |

**Rod count** = sum of `rods` over entries (not `#fuels`).  
Same NBT inserted together → one entry with `rods=2`. Different damage → separate entries with `rods=1`.

Lifetime heat (NBT `avgHeatAccu`) exists on items in-game tooltip but is **not** exposed in `getFuels`.

**Max rods** the reactor can hold is **not** in the CC API (structure / fuel holders). Put `max_rods` in cfg if needed.

## Inventory (crate) — observed

Crate `gtceu:steel_crate_1`: types `gtceu:steel_crate` + `inventory`, size 72.  
Methods: `getItemDetail`, `getItemLimit`, `list`, `parsePlaceholders`, `pullItems`, `pushItems`, `setBufferedText`, `size`.

Fresh thorium rod via `getItemDetail` / `list`:

| Field | Value |
|---|---|
| `name` | `tfg:thorium_rod` |
| `displayName` | `item.tfg.thorium_rod` (untranslated key) |
| `count` | 1 |
| `maxCount` | 1 |
| `damage` | 0 (fresh) |
| `maxDamage` | 5000 |
| `nbt` | opaque **hash string** (e.g. `552887…`) — not expanded tags |
| `tags` | `deafission:fuels=true`, `tfg:fission_rods=true` |

Notes:
- Identify rods: `name` (`tfg:…_rod`) and/or tags `tfg:fission_rods` / `deafission:fuels`.
- Same NBT hash → same group if inserted together into reactor (`getFuels` merges, `rods` stacks).
- CC does **not** expose fuel `heat` rating or `avgHeatAccu` from crate `getItemDetail` (only opaque nbt hash). Durability is `damage`/`maxDamage`.
- Rated heat is a property of the **item type** — look up by `name` in cfg (table below). After insert, confirm via `getFuels[].heat`.
- Crate in probe was filled 72/72 (rods + redstone dust fillers).

## TFG fuel rods (heat rating)

Source: pack `kubejs/startup_scripts/tfg/nuclear/materials.nuclear.js`  
`fuel(id, durability, rods, heat)` → items `tfg:{id}` / `tfg:depleted_{id}`.

Pack comment: heating ≈ `fuelHeat * 200 * throttle`; steady-state with full coolant ≈ `fuelHeat * 200 / 1.01` per 100% cell (1 rod).

| Item | heat | durability | ~steady heat @ 1 rod |
|---|---|---|---|
| `tfg:thorium_rod` | 0.7 | 5000 | ~139 |
| `tfg:uranium_rod` | 2.2 | 20000 | ~435 |
| `tfg:plutonium_rod` | 3.0 | 30000 | ~595 |
| `tfg:tbu_232_rod` | 2.0 | 5000 | ~396 (Th–U) |
| `tfg:americium_241_rod` | 0.5 | 5000000 | ~99 |
| `tfg:neptunium_237_rod` | 2.0 | 100000 | ~396 |
| `tfg:californium_252_rod` | 4.0 | 500000 | ~792 |

Put this map in script cfg if deciding feeds **before** insert. Different fuels = different `name`; same type → same heat.

## Probe UX

- First version collapsed tables → looked like metrics had only 3 fields. Fixed: one key per line + scroll + `fission_probe.txt`.
- Keys: ↑↓ PgUp/PgDn Home/End, `r` refresh, `q` quit.
