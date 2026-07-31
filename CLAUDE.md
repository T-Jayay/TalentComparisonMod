# TalentComparisonMod — Vermintide 2 talent value comparison mod

A VMF mod for Vermintide 2 that shows, as **running totals for the current run**
(never DPS), how much value each talent in a row *would have provided*,
regardless of which one is equipped. Each talent row is a fully distinct
section: its own module file, its own on-screen panel, its own settings group.

See `PLAN.md` for the current cleanup/rework plan and implementation details.

## Project layout

- `vermintide-mod-builder/mods/TalentComparisonMod/` — the live mod (only mod;
  older `*V2` folders are stale rename leftovers slated for deletion).
  - `scripts/mods/TalentComparisonMod/TalentComparisonMod.lua` — thin entry:
    `mod:dofile`s the modules, drives update/reset/game-state.
  - `..._data.lua` — settings widgets (grouped per panel via sub_widgets);
    `..._localization.lua` — strings.
  - `modules/ui_panel.lua` — shared draggable-panel framework (GUI, draw helpers,
    mouse edge state, Reset button that calls the one `reset_all`).
  - **Enemy-type filter** (`modules/unit_filter.lua`): FOUR categories — `elite`
    (`breed.elite`), `special` (`breed.special`), `mon` (`breed.boss`), `trash`
    (everything else). The control panel's filter row is FOUR MULTI-SELECT toggle
    buttons (Elites / Specials / Monsters / Trash), each an independent on/off switch
    (`F.enabled(cat)` / `F.toggle(cat)`); every value panel sums the enabled
    categories, so any combination shows at once (e.g. Elites+Specials+Trash minus
    Monsters). There is NO "All" button — "all" is just every category on (default).
    At least one category always stays on. Selection persists as the comma-joined
    setting `filter_sel`. Buckets are per-category (`F.fresh_bucket` /
    `F.new_cat_set`); filter-aware readers (`F.read`, `F.merge_sets`, power_boost
    `bread`, attack_speed_sim `extra`, kill_tracker `:get`) take an `enabled(cat)`
    predicate (`F.enabled`) instead of the old single-value filter string.
  - **Tab-toggle UI**: the control panel (`modules/control_panel.lua`) hosts —
    title/Hide row, enemy-type filter row, tab row, gameplay-status lines. Tabs
    come from `mod._tabs` (ordered list in the entry file): Lvl 5 → thp, Lvl 10 →
    whc + merc L10 + bw L10, Lvl 15, Lvl 20, Lvl 30 → bh L30 + Ready-for-Action
    (Merc), Other Stats → Combat Ult Refund + crit_tracker. The two `career_ult_refund`
    panels are split across tabs by draw-only wrapper groups in the entry file
    (`ult_combat` → Other Stats, `ult_rfa` → Lvl 30); the single module still handles
    update/reset/init once (it stays in `groups`). Each
    tab button is an independent show/hide TOGGLE (any number on at once; persisted
    as `show_tab_<id>`, default on, read via `mod._tab_enabled(id)`); a tab button
    only appears while one of its modules `wants_display()` (career-gated tabs
    follow the career; settings-disabled panels drop their tab). Toggled-on tabs'
    panels are free-floating and individually draggable (per-panel pos settings),
    exactly as before; the global Hide button still hides all content panels.
  - `modules/thp_talents.lua`, `modules/level15_talents.lua` — one per talent
    group; each returns a table implementing `init/reset/wants_display/draw`.
  - `modules/kill_tracker.lua` — shared, talent-agnostic kill / **Real Total**
    engine (Early Kills / Hits Saved / Real Total). Each damage panel owns one
    `KillTracker.new()` instance (its own `kills`/`unit_state`, so its Reset zeroes
    only its rows); a GLOBAL batch/queue calibrates every modeled world against the
    REAL applied damage. Level 15 owns the queue: its `calculate_damage` hook wraps
    each genuine hit in `begin_hit`/`commit_hit` (panels append per-talent
    `{without, with}` pairs via `tracker:add`), and its health-extension `add_damage`
    hook calls `on_real_damage` (K = real/model). Shared via `mod._kill_tracker`
    (dofiled in level15.init before the L10/20 panels init). Extracted from level15's
    former inline `kill_track`/`enqueue`/`flush`.
  - `resource_packages/.../TalentComparisonMod.package` must glob both
    `scripts/mods/TalentComparisonMod/*` AND `.../modules/*` (subfolders are not
    recursive) or new modules won't ship in the bundle.
- `vermintide-2-source-code/` — decompiled game source; the reference for all
  mechanics (esp. `scripts/utils/damage_utils.lua`: `calculate_damage`,
  `apply_buffs_to_stagger_damage`).
- `vermintide-mod-builder/_Build Mod.bat` / `_Create Mod.bat` / `_Upload Mod.bat`
  — VMB build scripts. `mods/.temp/` is regenerable build cache.

**`string.format` gotcha (`%d` vs floats).** The game patches `string.format`
(`foundation/scripts/util/patches.lua`) to swallow errors and return the literal
`"<Invalid string format>"` string, which then renders on-screen instead of
crashing. The common cause is `%d` (or `%i`) with a **float** argument — many mod
values (unit counts, extras) are floats, so use `%.0f` for whole-number display,
never `%d`, unless the value is provably an integer.

## Gameplay-affecting features (modules/gameplay_control.lua)

Everything that CHANGES gameplay (vs just measuring) is gated behind ONE master
consent setting, `allow_gameplay` (default OFF → the mod is strictly measure-only),
with per-feature sub-toggles. Every forced code path asks
`mod._gameplay_on(feature)` (master AND sub; sub nil→default). Features:
- `force_ep` (sub default on) — force extra cleave for power-level talents (EP L15,
  Reikland Reaper L20, Limb Splitter/MtM L10 Merc). All former `mod:get("force_ep")`
  sites now call `mod._gameplay_on("force_ep")`; off → "(est)" labels.
- `force_flense` (on) — the WHC L10 forced Flense bleed. No longer implicit: gated,
  and the granted buff is REMOVED when the gate closes mid-life
  (`remove_forced_flense` scans buff_ext for the buff_type). Row reads "(off)" +
  footnote when neither forced nor equipped.
- `force_st_spread` (on) — the L20 Merc vanilla Strike Together ally spread. Gated in
  `finalize_swing`; ST row reads "(off)" when unequipped + gate closed.
- `unequip_l15` (default OFF) — removes the equipped level-15 talent's buffs
  entirely: a `mod:hook` on `TalentExtension.get_talent_ids` (local, non-bot player)
  filters out any talent whose `buffs` list is one of the five unbalance templates,
  and `gameplay_control.update` calls `talents_changed()` whenever the desired state
  flips (spawns pick the filter up automatically via `extensions_ready`). Since
  `has_talent`/`rpc_sync_talents` also read `get_talent_ids`, detection and network
  sync stay consistent; the L15 panel's equipped-talent base-stripping naturally
  no-ops (all five columns become true hypotheticals over one no-talent base) and its
  title shows "[row unequipped]". Restored on toggle-off and in `mod.on_disabled`
  (`gameplay.restore()` uses a `restore_override` so the hook goes transparent before
  the final `talents_changed`).

Runtime clarity: modules write live flags into `mod._gameplay_live` (force_flense by
the WHC module, force_st_spread by the L20 module, force_ep/unequip_l15 by
gameplay_control.update); the main control panel draws a status line — green
"Gameplay: untouched (measure-only)" or orange "Gameplay MODIFIED: <list>" from
`mod._gameplay.live_list()`. gameplay_control is a no-panel group module (groups[2]
in the entry file), loaded before the value modules.

## Conventions for every talent group

- Independent panel, separately toggleable, draggable, shared Reset button /
  keybind; totals reset on entering a non-hub mission.
- Values are hypothetical: "what would this talent have given me this run",
  computed from real hits/events of the local player. Most accurate as host.
- Adding a group = new module implementing `init(mod)/reset()/wants_display()/
  draw(gui)`, one settings checkbox, and a section in this file.

## Talent group: Temp Health (level 5) — DONE, do not change

Shows THP each talent would have generated: **Sting** (first-target
melee hits, 0.5/2/4 by crit+headshot), **Carve** (1 per cleaved target, 0.5 for
targets 6–10), **Execute** (breed `bloodlust_health` on melee kill), **Second
Wind** (stagger-tier based + 0.25 on kill). Formulas mirror the game's
`thp_*` buff funcs. Optional **Tourney Balance** column showing the same events
under the actual TB mod's `rebaltourn_*` talents (Regrowth/Reaper/Bloodlust/
Vanguard), each formula matched to the real mod source
(`Camilo-Guzman/Tourney-Balance .../changes/thp_stagger_changes.lua`):
- **Regrowth** (Sting): `rebaltourn_heal_finesse_damage_on_melee` — once per swing
  (first crit/headshot hit; `regrowth_procced` latch reset at target 1), headshot
  +3, crit +1.5 (stack → 4.5), plain hit **0** (no base heal).
- **Reaper** (Carve): `heal_damage_targets_on_melee` — flat **1** per target, only
  targets **1–5** (`max_targets=5`); no 6–10 drop-off tier. The template's
  `bonus`/`multiplier` fields are vestigial (the game func ignores them).
- **Bloodlust** (Execute): `heal_percentage_of_enemy_hp_on_melee_kill` heals a flat
  `breed.bloodlust_health` (the name and template `multiplier=0.2` are misleading —
  unused). TB **does** override this field for some breeds (e.g. Chaos Warrior 30→20,
  Chaos elite 15→10, monsters 50→35), so **Bloodlust ≠ Execute** on those breeds.
  Since only the loaded mod's value is live in `breed.bloodlust_health`, the module
  keeps two hardcoded category tables — `BL_OFFICIAL` (vanilla
  `BreedTweaks.bloodlust_health`, breed_tweaks.lua:594) and `BL_TB` (TB overrides) —
  plus a `TB_BREED_CATEGORY` breed→category map. Each column reads the **live** field
  for the active scenario and the hardcoded table for the other (`official_bloodlust`
  / `tb_bloodlust`), so both are correct whether or not TB is loaded.
- **Vanguard** (Second Wind): `rebaltourn_heal_stagger_targets_on_melee` — heal is
  the **raw** stagger number `(stagger_type or stagger_value) × 1` (NOT the vanilla
  `{0.25,1,2}` index → ~2× thp_tank), push flat **0.6**, gate `target_index < 5`,
  weapon caps (billhook stagger 9→2, ghost-scythe discharge→0.25, shield-slam
  heavy→0.75). **No on-kill component** — `on_stagger` only, and (like vanilla) it
  never fires on a killing blow, so nothing is credited on kill. The mod still
  excludes corpse-staggers from Vanguard (`target_is_corpse`).

**Two display modes** (`tb_mod_active()` = `get_mod("TourneyBalance")` loaded+enabled):
when the TB mod is NOT running, the panel shows **Live** (reality) first with the TB
column opt-in via `show_tb`; when the TB mod IS running, the game is already applying
`rebaltourn_*`, so the panel shows the **TB** column first and relabels the vanilla
column **Official** (both always shown). All four TB formulas are static (applied to
the same live hit/event params in either mode); the decay/Blocked pools still bank
the Official/Live amounts.

**Second Wind caveat (accuracy limit).** For Sting/Carve/Execute the cross column is
*exact* in either mode, because their proc inputs (crit/headshot/target_index/damage/
breed) are mod-independent. **Second Wind / Vanguard is the exception:** its THP is
driven by the game-computed `stagger_type`/`stagger_value` reaching `on_stagger`,
which derive from the weapon's IMPACT power — and TB's `weapon_changes.lua` rebalances
that impact (in-place edits to `DamageProfileTemplates`/`Weapons`, same unrecoverable
overwrite as `bloodlust_health`). So the stagger numbers reaching the proc are always
the *loaded* mod's, never the modeled mod's. Consequences: the **cross** column for
Second Wind (Official when TB is loaded; TB when it isn't) is only an **estimate** —
applying one mod's formula to the other mod's staggers — and TB's higher impact tends
to inflate the vanilla `thp_tank` estimate (Official reads high under TB). The
*reality* column (TB under TB, Live under vanilla) stays exact. The panel marks the
estimated Second Wind value with a leading `~` and a footnote (`M.draw`,
`sw_cross_key`). A truly accurate counterfactual would require hardcoding both
vanilla and TB impact tables per weapon/attack/armor and re-running the impact→
stagger_strength→threshold math — large and fragile, so not done. (Note: weapon caps
billhook/ghost-scythe/shield-slam and the corpse exclusion apply to Vanguard only, so
TB Second Wind legitimately reads *below* Official on those weapons — expected TB
design, not the estimate error.)

Optional **Decayed** column (`show_decay`): per talent, how much of its generated
THP would have decayed away this run. Each talent's THP is pooled separately;
every gain grows that pool and (re)arms decay to start `DEGEN_START` (3 s) later.
While armed and non-empty the pool loses `DEGEN_AMOUNT` (0.25) per tick — every
0.25 s not-wounded (1.0 THP/s), every 0.5 s wounded (0.5 THP/s), matching
`player_unit_health_extension.lua` / `player_unit_status_settings.lua`. All four
level-5 THP talents equip a healing perk (`smiter/linesman/tank/ninja_healing`)
whose not-wounded rate is identical, so only the gain events differ per talent.
Per the chosen model the pool is **uncapped** (no max-health clamp) and damage
taken is **ignored**, so the column is an upper bound on decay. The decay tick
runs every frame via `M.update(dt)` (driven from the entry file's update loop,
regardless of panel visibility). Columns in `draw` are now dynamic: Live is
always shown, TB / Decay / Dec % added per their toggles.

Optional **% time decaying** column (`show_decay_pct`, header "Dec %"): the
fraction of time each talent's THP would be actively decaying, **assuming an
endless supply of THP** — i.e. purely gain *cadence*, independent of pool size
and of the wounded/not-wounded rate. Per talent we track `first_t`/`last_t`; each
frame the slice past `last_t + DEGEN_START` (the 3 s grace window) is added to
`decaying_time`, and the column shows `decaying_time / (now − first_t)`. High %
means gains are spread out (pool often idle > 3 s → decaying); low % means gains
are frequent enough to keep re-arming the grace window. So Sting (sparse first-
target hits) reads higher than Carve (bursty cleave) even when Carve generates
more THP.

Optional **Blocked** column (`show_blocked`): the real damage each talent's THP
would have absorbed this run, using a *realistic* per-talent pool (`rpool`),
distinct from the uncapped Decayed pool:
- Gains are clamped so temp + permanent health never exceeds max health — the cap
  is `get_max_health() − current_permanent_health()` (`current_cap`, refreshed
  each update; `local_player_free_health()`); excess THP is wasted, not counted.
- `rpool` decays on the same schedule as the uncapped pool (shares `timer`; the
  3 s delay depends only on time-since-last-gain), stopping at empty.
- A `hook_safe` on `PlayerUnitHealthExtension.add_damage` (local player only,
  skipping `temporary_health_degen`) drains each `rpool` by `min(damage, rpool)`
  and adds that to the talent's running `blocked` total.
Draw columns are now Live / TB / Decay / Dec % / Blocked, each per its toggle.

Second Wind killing-blow rule: the game applies damage before the stagger proc and
only staggers `if target_alive` (`damage_utils.lua` `server_apply_hit`), so a hit
that kills **never fires `on_stagger`**. **Both** the Official (`thp_tank`) and TB
(`rebaltourn_vanguard`) buffs are `on_stagger`-only, so neither sees a killing-blow
stagger — there is nothing to credit on kill, and neither column adds any killing-
blow stagger THP. (Official/Live still gets its separate `+0.25` `thp_tank_kill_func`
on melee kill; TB Vanguard has no on-kill component at all.) The `server_apply_hit`
hook still computes the player's stagger and calls `mod._on_player_stagger` — but
now only to drive the Level-15 Bulwark window, not any THP crediting. (An earlier
version predicted killing-blow stagger via `mod._sw_pred`/`SW_KILL_STAGGER_WINDOW`
and added it to TB; that was wrong — the real TB mod never grants it — and was
removed.)

## Talent group: Level 15 damage (implemented — `modules/level15_talents.lua`)

Talents (each career's L15 row offers 3 options and the player picks exactly ONE:
two career-specific stagger talents from the first four, plus Enhanced Power, which
is always one of the three choices — it is NOT force-equipped):
- **Mainstay**: +40% dmg vs staggered, +60% vs multi-staggered.
- **Smiter**: first enemy hit counts as staggered; +20%/+40%.
- **Bulwark**: enemies you stagger take +10% melee damage for 2 s; +20%/+40%.
- **Assassin**: +20% vs staggered; crits/headshots (or multi-stagger) +40%.
- **Enhanced Power (EP)**: +7.5% total Power Level, applied before other buffs
  (affects damage, cleave, and stagger).

These five are the "unbalance" buff templates (`buff_templates.lua`): `smiter_unbalance`,
`linesman_unbalance` (Mainstay), `finesse_unbalance` (Assassin), `tank_unbalance`
(Bulwark), `power_level_unbalance` (Enhanced Power). Detect an equipped one with
`buff_ext:has_buff_type("<name>")` (buff_type == the sub-buff name).

Game mechanics (from `damage_utils.lua`): each hit reads a stagger number
S (0–2) from the target blackboard; final = base × (min_coeff + S ×
stagger_damage_multiplier), scaled by target `unbalanced_damage_taken`. Talent
buff perks modify S before that: `smiter_stagger_damage` (first target
S=max(1,S)), `linesman_stagger_damage` (Mainstay: S>0 → S+1),
`finesse_stagger_damage` (Assassin: crit/headshot → S=2). Bulwark and EP do not
touch S.

Corpse hits are skipped entirely: sweeps still run `calculate_damage` on dead
units they clip, and every corpse contact registers as a first-target S=0 hit
(a fake Smiter proc) that used to badly inflate Smiter's Uncapped column.
`account_hit` and the ally-Bulwark path return early when pre-hit health is 0.

Melee dedupe (`melee_should_credit`, shared via `mod._l15_melee_credit` with the
L10/L20 forwards): the game runs `calculate_damage` 2–3× per real hit (prediction,
application, torso recompute), so hits must be credited once — but a **dual-wield**
attack fires two sweeps (`damage_profile_left`/`_right`) at the same target and both
are genuine. On the **host** each genuine hit = one `server_apply_hit`, so a per-
target window (`self_ctx`, opened from the THP module's server_apply_hit hook via
`_l15_open_ally_ctx`) credits the first call and skips the rest; two dual-wield
sweeps = two windows = both counted. On a pure **client** server_apply_hit doesn't
run, so it falls back to time-window dedupe (dual-wield collapses — accepted; solo
is host). THP is unaffected (it's driven by the game's own `trigger_procs` events,
one per genuine hit).

Display — per talent, **Extra Damage: Total / First** (running damage totals,
first = target_index 1 only):
- Smiter / Mainstay / Assassin: derived via the stagger-number model — invert
  each real hit to base damage, re-apply each talent's S rule, credit the delta.
- Bulwark: **self-only**, code-accurate. Its aura (`tank_unbalance` →
  `tank_unbalance_buff`) adds +0.10 to the target's `unbalanced_damage_taken`,
  which is a `stacking_bonus` (no multiplier), so `calculate_damage` adds +0.10
  **flat** to the stagger bonus term. The exact per-hit delta is therefore
  `base_damage × 0.10`, independent of stagger number — not 10% of the whole hit
  (the tooltip's "10% more melee damage" is loose). Credited on the player's own
  melee hits within 2 s of the player staggering that unit (window opened from
  the THP module's `server_apply_hit` hook via `mod._on_player_stagger`). Allies
  are not modeled. The window is opened **after** the causing hit's `func()` runs
  (the `on_stagger` proc applies the debuff only after this hit's damage is
  computed), so the stagger-causing hit is **not** credited Bulwark — only later
  hits are. Marking before `func()` used to credit the causing hit too, badly
  inflating Bulwark on fast weapons that stagger-and-kill in one swing (e.g. rapier
  under TB's 5 s window). The mark is also gated to melee attacks (`MELEE_1H/2H`).
- EP: extra damage from **all** sources (melee, ranged, DoTs), computed by
  re-running the unhooked `calculate_damage` with the buff simulated at its real
  application point: a hook on `ActionUtils.apply_buffs_to_power_level`
  multiplies the **scaled** power by 1.075 while `ep_recompute_mult` is set —
  matching the `power_level` stat buff, which applies AFTER the difficulty power
  cap and diff-ratio compression in `scale_power_levels`. (Multiplying
  `original_power_level` pre-scale — the old approach — understated EP: ~6%
  below the cap, near 0 above it.) Respects armor breakpoints, so still not a
  flat +7.5%. Plus a **Force Enhanced Power** setting:
  when on, `account_sweep` raises the real sweep's `_max_targets_*` to the EP
  cleave budget so extra cleave physically happens; hits with `target_index`
  beyond the no-EP budget are counted as **extra units hit** with their full
  damage as **extra cleaved damage**. Force EP inflates cleave only, not per-hit
  damage, so it does not double-count the ×1.075 damage recompute. With Force EP
  off, the panel shows only a hypothetical extra-units estimate.
  - EP-only cleaved units (`target_index` beyond the no-EP budget) are credited
    ONLY to EP's cleave counters and skip all other talents, so Force EP does not
    inflate Smiter/Mainstay/Assassin/Bulwark by hits that wouldn't otherwise land.
  - If Enhanced Power is ALREADY equipped (`has_buff_type("power_level_unbalance")`),
    Force EP is a no-op (no second cleave boost) and the EP damage column reports
    the boost already realized: the hit is recomputed WITHOUT the buff
    (`ep_recompute_mult = 1/1.075` on scaled power) and the delta credited.

**Early Kills / Hits Saved columns.** Two always-on columns after Uncapped, per row
(incl. EP). Cross-hit state per unit (`unit_state`, keyed by target, pruned on death,
cleared on reset): for each talent two running sums — `with` (baseline + that talent's
extra) and `without` (its baseline) — plus a per-talent hit counter; threshold `init`
= the unit's real HP when first credited. **All rows share ONE true "no level-15
talent" base** (`base_no_talent`), in BOTH Official and TB. The player always equips
exactly one of the three L15 options (two career stagger talents, or Enhanced Power),
and whichever it is has its own extra stripped from the base: (a) an equipped **stagger
talent** via the `denom` inversion; (b) an equipped **Enhanced Power** via `final_no_l15
= final_damage − ep_extra` (detected by buff, not TB-gated); (c) an equipped **Bulwark**
via `bonus_no_aura` — its flat `unbalanced_damage_taken` aura (`tank_unbalance`, +0.10/
0.15) is subtracted from the baseline stagger bonus when the target currently carries it
(equipped AND within the stagger window). The real-hit inversion (`denom`) keeps the
aura since that is what actually landed. Without this, every column would be inflated by
whatever L15 talent is actually equipped. EP's kill columns are then valued on that same base (`base_no_talent +
ep_extra`, melee only) so its bigger per-hit boost crosses the threshold soonest → it
reads the HIGHEST Hits Saved and (consistently) the most Early Kills. (EP's Total/First/
Uncapped *damage* columns are unchanged — still its real all-source extra vs reality.)
Bulwark's pool is shared by self + ally hits. Forced-cleave-only units are excluded
(they feed EP's cleave counters, not `kill_track`).

**Real-damage calibration (DEFERRED kill-tracking).** `calculate_damage`'s return —
what the whole stagger model inverts — is the damage BEFORE `apply_buffs_to_damage`
and the `on_damage_dealt` procs (`add_damage_network_player:1919`), so any post-calc
attacker buff (e.g. **Slayer's stack damage**, ~+10%) is invisible to it. Near a
one-shot breakpoint that understated the baseline and fabricated Early Kills — the mod
thought a hit that really one-shot an enemy (no talent) was sub-lethal, and credited the
stagger talents for a kill that happened anyway. Fix: kill-tracking is **not** run inside
`account_hit` (which fires at `calculate_damage` time, before the hit lands). Instead each
credited melee hit's per-talent `{without, with}` pairs are **enqueued** (`pending_credit`,
FIFO per target, with the model's `final_damage`) and flushed by a `hook_safe` on the enemy
health extensions (`GenericHealthExtension`, `BeastmenStandardHealthExtension`)
`add_damage`, which runs just after with the **real applied damage**. `flush_kill_credit`
scales every modeled damage by `K = real / model_final` (talent-independent, so exact) and
sets `real_kill` from the real number, then runs `kill_track`. `M.update` stale-flushes any
hit whose `add_damage` never arrived (unhooked breeds, 0-damage/immune hits) at `K=1` — the
prior raw-model behaviour, so no hit is dropped. NOTE: the **damage** columns (Total/First/
Uncapped) are still modeled off the pre-buff number, i.e. low by the same `K`; only the
kill columns are calibrated.
- **Early Kills** (`kills[t].n`) = units that would have died *earlier this run purely
  because of the talent's extra damage*: credited when `not counted` AND `with >= init`
  AND `without < init` (talent's world kills it in strictly fewer hits than the no-talent
  world), latched once per unit — the mod never applies the damage, so the real unit
  may live on and must not be recounted. A kill the talent wouldn't have pulled sooner
  (both worlds die on the same hit, e.g. 90 HP / 30-per-hit / +5 talent) is NOT counted.
- **Hits Saved** (`saved_sum/saved_n`) = running average, over *every unit you actually
  killed* (real killing blow detected as `health - final_damage <= 0` on your hit), of
  **how many fewer hits the talent's world needed** — `real_hits − st.frozen[t]`, where
  `real_hits` is `h` (each talent is fed a pair on every hit, so its hit counter equals
  reality) and `st.frozen[t]` is the hit at which the talent's cumulative `with` would have
  crossed the unit's HP. So a stronger talent (bigger extra, e.g. EP) crosses sooner and
  reads a HIGHER Hits Saved. **The denominator is EVERY kill**, not just the units the
  talent finished sooner: a unit whose kill the talent's world never reached (`frozen` nil)
  or reached on the same hit as reality (`frozen == h`) saves 0 (`frozen or h` fallback,
  clamped ≥0) but STILL counts in the average — a talent that changes nothing reads
  **0.00**. This is the fix for the old **Hits/Kill** column (`hpk_sum/hpk_n`, still tracked
  internally, no longer displayed), which averaged `st.frozen[t]` over ONLY the self-selected
  subset of units the talent's world finished, dropping the rest. That let a do-nothing
  talent like **Bulwark** average only the easy few-hit kills its ~0 extra happened to cross
  and silently exclude the hard multi-hit units — reading a deceptively LOW Hits/Kill despite
  adding no damage (its sampled set was a subset of every stronger talent's, so the stronger
  talents "owned" the hard high-hit-count kills that dragged their averages up). Hits Saved's
  common denominator makes the rows directly comparable. Latched per unit per talent; units
  killed by allies/DoTs you didn't land are not sampled. Displayed to 2 decimals.

**Tourney Balance mode.** When the TB mod is loaded+enabled (`tb_mod_active()` =
`get_mod("TourneyBalance")`, same detection as the THP panel) the game is already
applying TB's reworked level-15 talents, so the panel switches every value to TB's
numbers — a **single reality column** (no cross-mod estimate: the stagger number S
is read off the target blackboard, so it is always the loaded mod's real S). TB's
changes (`.../TourneyBalance/changes/thp_stagger_changes.lua`):
- **Mainstay** (`rebaltourn_linesman_unbalance`) — **re-added in TB v37** (it was
  removed in the previous TB) with a NEW mechanic: a melee direct hit applies
  `rebaltourn_mainstay_stagger_mark_buff` to the target (a `dummy_stagger` stat,
  **+1 per stack, max 2 stacks, 2 s, refreshed per hit**); the stagger number for
  the **first 5 targets** reads `min(base_sn + stacks, 2)`. The mark is applied
  AFTER the causing hit's damage, so the first hit gets nothing and repeated hits on
  the same target build toward +2 — unlike vanilla Mainstay (`S>0 → S+1` on the same
  hit). Modeled per-target via `mainstay_marks` (read prior stacks, credit, then bump
  the mark); the equipped-Mainstay inversion reads the REAL `dummy_stagger` buff off
  the target. Row is shown in both modes now.
- **Assassin** (`finesse_unbalance`) — S=2 on head/neck **only**; crit no longer
  procs (TB's `apply_buffs_to_stagger_damage` rewrite). Gated by
  `assassin_uses_crit()` in both `talent_stagger_number` and
  `equipped_stagger_number`.
- **Bulwark** (`rebaltourn_tank_unbalance_buff`) — flat bonus **0.10** (v37 lowered
  it from the earlier TB's 0.15 back to 0.10), window **10 s** (v37 raised it from
  5 s) (`bulwark_damage_taken()` / `bulwark_window()`). Still applied to the stagger
  bonus term, self-only melee (the "10% from all sources" tooltip is loose flavor —
  mechanically still the `unbalanced_damage_taken` stacking_bonus). v37 also gives
  Bulwark a self **+10% `power_level_impact`** (stagger strength); not modeled, like
  vanilla Bulwark's unmodeled self buff.
- **Enhanced Power** (`power_level_unbalance`) — +7.5%→**+10%** (`multiplier 0.1`).
  The shared `power_boost` instance now takes `mult` as a function (`ep_power_bonus`)
  so it resolves 0.075/0.10 live per hit/sweep; `Boost:cur_mult()` in `power_boost.lua`.
- **Smiter** — unchanged.

Exact decompiled-source file paths and line numbers for all of this are in the
`level15-source-locations` memory (buff templates, damage pipeline, buff
extension, cleave).

Setting ids: `show_thp`, `show_tb`, `show_decay`, `show_decay_pct`,
`show_blocked`, `show_level15`, `show_level10`, `show_level20`,
`show_ult_refund`, the gameplay group `allow_gameplay` (master) with sub-toggles
`force_ep` / `force_flense` / `force_st_spread` / `unequip_l15`, plus per-panel
drag positions `thp_pos_x/y`, `l15_pos_x/y`,
`l10_pos_x/y`, `l10m_pos_x/y`, `l10bw_pos_x/y`, `l10ws_pos_x/y` (Waystalker),
`l20_pos_x/y`, `l30bh_pos_x/y`
(BH L30), `ultc_pos_x/y` (combat), `ultm_pos_x/y` (Ready for Action).

**Tiered settings.** `show_level10` and `show_level20` are now *category masters*
("Level 10/20 Talents") with career-specific `sub_widgets`: `show_level10_whc`,
`show_level10_merc`, `show_level20_merc` (each defaults on; nil→on in code). A career
module's `active()` = tier master AND its sub-toggle (nil→true) AND the career match,
so only one career's panel per tier can ever show. This structure is the template for
future tiers (L25/L30) and careers.

## Talent group: Level 10 Witch Hunter Captain (`modules/level10_whc_talents.lua`)

CAREER-SPECIFIC — the first one-career group; the template for future ones. The
panel is hidden and NONE of its simulation runs unless the local player's
`career_system:career_name() == "wh_captain"` (checked via `active()` =
`show_level10` AND WHC). WHC picks 2 of these 3 at level 10:
- **Riposte** (`victor_witchhunter_guaranteed_crit_on_timed_block`): a perfectly
  timed block makes your NEXT melee/ranged attack (≤2 s) a guaranteed crit
  (single hit — the buff is `remove_on_proc` on `on_hit`).
- **Deathknell** (`victor_witchhunter_headshot_damage_increase`): +headshot BONUS
  damage — `stat_buff headshot_multiplier`, source `buff_tweak_data` value **0.5**
  (`DEATHKNELL_HEADSHOT_BONUS`; tooltip loosely says 25%). Finesse hits only.
- **Flense** (`victor_witchhunter_bleed_on_critical_hit`): despite the name, every
  light/heavy melee hit applies the `weapon_bleed_dot_whc` DoT (`bleed` profile,
  ≤3 stacks) in `damage_utils.lua server_apply_hit` (~3697). A NEW DoT source.

Reported per talent exactly like Level 15: **Total** (overkill-removed extra),
**First** (target_index 1), **Uncapped** (raw), plus **Real Total** (kill-aware, via
the shared `kill_tracker` — Deathknell/Riposte feed it their `{without, with}` pairs;
**Flense** shows `-`, a DoT has no per-hit kill sequence of its own). Derivation:
- **Flense** — FORCED: while active on WHC and Flense not equipped, `M.update`
  grants the bleed buff to the local player (`buff_system:add_buff`) so the game
  applies the real DoT (gameplay-affecting, modded realm; most accurate as host).
  Every `bleed`-profile DoT tick on the player's targets is credited at full
  damage (baseline 0), overkill-capped; ticks stop at death so Total/Uncapped sum
  only real ticks. On WHC nothing else uses the `bleed` profile → unambiguous.
- **Deathknell** — re-run `calculate_damage` with `+DEATHKNELL_HEADSHOT_BONUS`
  injected into `headshot_multiplier` (a `BuffExtension.apply_buffs_to_value` hook
  gated by `dk_recompute_ext`, mirroring the EP recompute). Body hits → 0.
- **Riposte** — OPPORTUNISTIC: a `hook_safe` on
  `GenericStatusExtension.blocked_attack` detects a real timed block
  (`t < self.timed_block`) and arms a 2 s window; the next local melee/ranged hit,
  if not already a crit, is re-run with `is_critical_strike = true` and the delta
  credited, then the window is consumed. No gameplay change.

Deathknell/Riposte are credited only when NOT equipped (this is a "value of the
talent you didn't take" panel); the one you took reads 0. Flense is always measured.

Damage crediting piggybacks on the Level-15 module's single `calculate_damage`
hook, which calls `mod._l10_on_hit(ctx)` (ctx = unhooked `func` + all args + real
`final`) for every local-player hit. This module owns two non-conflicting hooks:
`BuffExtension.apply_buffs_to_value` and `GenericStatusExtension.blocked_attack`.

## Talent group: Level 10 Mercenary (`modules/level10_merc_talents.lua`)

CAREER-SPECIFIC (`es_mercenary`); panel + sim gated on `show_level10` AND
`show_level10_merc` AND Merc, mirroring the WHC L10 module. Owns no hooks — per-hit
crediting is forwarded from the L15 `calculate_damage` hook via `mod._l10_merc_on_hit`
(added beside the `_l10`/`_l20` forwards); melee dedupe reuses `mod._l15_melee_credit`.
Merc picks 2 of 3:
- **More the Merrier** (`markus_mercenary_increased_damage_on_enemy_proximity`): the
  sub-buff `markus_mercenary_damage_on_enemy_proximity` is a **`power_level`** stat buff
  (mult **0.05**, `max_stacks` 5), so despite the "damage" name it is a variable
  power boost of `0.05 × stacks`. Stacks = alive enemies within **3 m**, computed the
  way the game does (`buff_function_templates.lua`
  `activate_buff_stacks_based_on_enemy_proximity`): a **server broadphase** query
  (`ai_system.broadphase`, `POSITION_LOOKUP`, `side.enemy_broadphase_categories`,
  count `HEALTH_ALIVE`, cap 5) — **HOST ONLY**. Valued exactly like Enhanced Power via
  a registered `power_boost` instance whose `mult` is the live `mtm_mult` function
  (all-source extra damage + extra cleave; Total/First/Uncapped).
- **Limb Splitter** (`markus_mercenary_power_level_cleave`): `power_level_melee_cleave`
  stacking-multiplier **0.5**, applied to cleave power at `action_sweep.lua:190` (the
  exact term `power_boost.run_sweep` omits from its baseline). A **cleave-only**
  registered boost — the module never calls its `account_hit` (no per-hit damage); the
  shared sweep/cleave hooks measure the extra units + their damage. Reuses the general
  **Force cleave button (`force_ep`)**: forced (measured) when on + not equipped,
  else a rough estimate. Reads "—" while actually equipped (the real sweep already
  cleaves, so `run_sweep` skips it — engine only forces/estimates the not-equipped case).
- **Helborg's Tutelage** (`markus_mercenary_crit_count`): every **5** attacks
  (`buff_on_stacks`; counter increments once per attack via
  `add_buff_on_first_target_hit`, incl. ranged) grant one guaranteed crit
  (`remove_on_proc`) AND random crits are removed. Valued as a **net**: `+`(crit delta)
  on each forced-crit attack that wasn't already a crit, `−`(crit delta) on each real
  random crit it would have suppressed. Crit delta via re-running `ctx.func` with the
  crit flag toggled (the WHC-Riposte trick). Per-attack forced/normal decision is made
  at the first target and reused for cleaved targets (a crit crits every target). Net
  Total/First/Uncapped may be **negative** (high real crit chance → suppression
  outweighs the cadence). Measured only when NOT equipped (dashes when equipped).
  **TB variant / cross column:** under Tourney Balance, Merc still crits, so TB's
  Helborg does NOT suppress random crits — its value is just the forced-crit gains (no
  `−`(suppression) term, so TB ≥ Official). The module tracks both records (`helborg`
  Official, `helborg_tb` TB): forced-crit gains credit both (`credit_helborg(...,
  also_tb=true)`), the suppression event credits Official only. The panel adds one
  cross column (`T10M_CROSS_COL`) via the shared `tb_mod_active()` detection — on
  vanilla the Total is Official and the extra column header is **TB**; under TB the
  Total is TB and the extra column is **Official**. Only the Helborg row populates it.

Overkill accounting via the shared `useful_extra` model. Reset on mission entry / Reset.
Also a **Real Total** column (kill-aware, shared `kill_tracker`): **More the Merrier**
and **Helborg** feed it (Helborg tracks two kill records — `helborg` Official incl. the
suppression `with < without`, `helborg_tb` forced-crit gains only — and the column
shows the current mode's variant, matching the Total); **Limb Splitter** shows `-`
(pure cleave, no per-hit kill model).

## Talent group: Level 10 Battle Wizard (`modules/level10_bw_talents.lua`)

CAREER-SPECIFIC (`bw_adept`; panel + sim gated on the local player being Battle
Wizard, like the other career modules). Owns ONE hook set only: `hook_safe` on the
three charged-spell actions' `client_owner_start_action` (`ActionChargedProjectile` /
`ActionGeiser` / `ActionFlamethrower`) to detect a fully-charged cast; all per-hit
crediting is forwarded from the L15 `calculate_damage` hook via `mod._l10_bw_on_hit`.
Non-DoT dedupe reuses `mod._l15_melee_credit` (melee AND ranged — the L15
`account_hit` dedupes all non-dot hits, and Sienna's staff hits are ranged); burn DoT
ticks are credited every tick (no dedupe, like WHC Flense). BW picks 2 of 3
(`sienna_adept_*`, `talent_settings_sienna.lua`):
- **Volcanic Force** (`sienna_adept_power_level_on_full_charge`, mult **0.5**):
  fully charging a spell adds +50% POWER to that attack. `full_charge_boost`
  (`stacking_multiplier`) is applied to the action's `power_level` **before**
  `calculate_damage`, at the three action sites (`action_charged_projectile.lua:185`,
  `action_geiser.lua:29`, `action_flamethrower.lua:50`, each gated on `charge_level >=
  1`). Because it is a PRE-calc power multiplier it is modeled by re-running the hit
  with `original_power_level × 1.5` (NOT the post-scale `apply_buffs_to_power_level`
  hook the EP/Reaper `power_level` stat buffs use — those apply after the difficulty
  cap; `full_charge_boost` applies before it). Respects breakpoints (not a flat +50%).
  Credited only to direct spell hits (`not is_melee`) inside a fully-charged window
  (`VF_WINDOW` 3 s, armed on each fully-charged cast and refreshed on each boosted hit
  — burn-tick boost and spell cleave are NOT modeled). Equipped → `original_power_level`
  already carries ×1.5, so it is stripped (recompute ×1/1.5). Kill tracker fed the
  ACTUAL recomputed base/with (nonlinear, so no flat factor).
- **Famished Flames** (`sienna_adept_increased_burn_damage_reduced_non_burn_damage`):
  burn DoT damage **+100%** (`increased_burn_dot_damage` ×2, applied only when
  `damage_type == "burninating"`) AND all weapon melee/ranged damage **−15%**
  (`reduced_non_burn_damage` ×0.85, applied only to hits whose `damage_source` is a
  weapon with a melee/ranged `buff_type` — so incl. Sienna's staff direct hits, but
  NOT DoTs, career skills, or explosions). **Both are POST-`calculate_damage`**
  (`DamageUtils.apply_buffs_to_damage:2418/2431`), so `ctx.final` is always the pre-FF
  base for either hit → deltas are exact: burn tick gain `= +base`, weapon loss
  `= −0.15·base`, regardless of equipped state. Shown as a NET row (burn gain minus
  weapon loss) with the split beneath. Kill tracker: a factor-based `{without, with}`
  pair (`credit_kill`) that the batch's `K = real/model` calibration turns into the
  correct FF / no-FF applied damage in both equipped and unequipped cases (FF is
  post-calc and linear, so the factor is exact — unlike VF).
- **Lingering Flames** (`sienna_adept_infinite_burn`): burns last until the enemy dies,
  no longer stack (`max_stacks` forced to 1), and the single stack ticks **twice as
  fast** (`buff_utils.generate_infinite_burn_variants` halves `time_between_dot_damages`,
  removes `duration`, sets `max_stacks 1`). It has `buffs = {}` and works via a
  `has_talent()` DoT-template swap (`weapons.lua:169` `InfiniteBurnDotLookup`), so it
  can't be forced by adding a buff → it is SIMULATED: from a unit's first observed burn
  tick, `M.update` projects one persistent stack ticking at 2× the base interval
  (`BURN_INTERVAL_BY_PROFILE_NAME` /2; burning_dot 0.75, beam 1.0, flamethrower 0.65)
  until the unit dies, capped at the unit's starting HP (no overkill), and reports
  `LF burn − real burn`. The sampled tick is the **actual applied** burn: FF's +100% is
  post-`calculate_damage`, so when Famished Flames is ALSO equipped every real tick is
  `ctx.final × 2`, and LF feeds that doubled value into BOTH its vanilla baseline and its
  2× projection (both carry the same FF factor; the overkill cap engages against real HP).
  Because LF trades stacking (up to 3) for a permanent 2× single
  stack, its value is **legitimately negative** for stack-heavy play and positive for
  long-lived single targets. Real Total shows `-` (a forward projection, no real
  `add_damage` to calibrate). Measured only when NOT equipped (the observed ticks ARE
  the infinite world when equipped, and the vanilla-stacking baseline can't be
  reconstructed from them) — dashed + noted when equipped.

Reported Total (overkill removed) / Uncapped (raw) / Real Total, per unit-category
buckets merged by the filter, own `kill_tracker` instance. Drag pos `l10bw_pos_x/y`;
appears under the **Lvl 10** tab. Host-only (calculate_damage / DoT `server_apply_hit`
resolve server-side).

**Tourney Balance mode** (`tb_mod_active()` = `get_mod("TourneyBalance")` loaded+enabled,
same detection as the other panels). Volcanic Force is unchanged; the other two shift:
**Famished Flames** — burn +100%→**+150%** and non-burn penalty −15%→**−30%**
(`ff_burn_factor()` ×2.0→×2.5, `ff_weapon_factor()` ×0.85→×0.70; both still post-calc,
so the deltas and the kill-tracker factor stay exact). **Lingering Flames** — the extra
tick rate is **removed**, so under TB the infinite single stack ticks at the NORMAL
interval (`lf_touch` uses ×1.0 not ×0.5); the value is more often negative vs vanilla
since it no longer trades stacking for a 2× rate. No separate TB GUI — the live constants
just resolve per hit.

## Talent group: Level 10 Waystalker (`modules/level10_ws_talents.lua`)

CAREER-SPECIFIC (Kerillian career `we_waywatcher`; panel + sim gated on the local
player being Waystalker, like the other career modules). Owns NO hooks — per-hit
crediting is forwarded from the L15 `calculate_damage` hook via `mod._l10_ws_on_hit`
and melee swing starts from its `ActionSweep.client_owner_start_action` hook via
`mod._l10_ws_on_swing_start`; non-DoT dedupe reuses `mod._l15_melee_credit` (melee
AND ranged — the L15 `self_ctx` window opens for any genuine local hit). Ranged shots
have no host start hook, so they are segmented from the hit stream by time gap
(`RANGED_SHOT_GAP` 0.3 s), like the L20 ally-swing reconstruction. Talent IDs live in
`talent_settings_kerillian.lua` (row is `kerillian_waywatcher_*`, not `waystalker`).
Waystalker picks 2 of 3:
- **Blood Shot** (`kerillian_waywatcher_extra_arrow_melee_kill`): a MELEE KILL
  (light/heavy killing blow) grants a 10 s buff (`..._buff.duration` 10) whose next
  ranged hit fires ONE extra projectile (`stat_buff extra_shot` +1, `remove_on_proc`
  on `on_ranged_hit`). Valued as the extra arrow's damage, ESTIMATED as the damage of
  the first ranged shot fired within 10 s of a melee kill (the extra arrow duplicates
  that shot). A melee killing blow (`final >= health`) arms the window; the first
  ranged shot in the window opens a same-shot crediting window (`RANGED_SHOT_GAP`) and
  consumes the 10 s window, crediting every hit of that shot (overkill-capped).
- **Serrated Shots** (`kerillian_waywatcher_critical_bleed`, perk
  `kerillian_critical_bleed_dot`): despite the internal "critical" name, in
  `damage_utils.lua:3698` EVERY projectile hit (`charge_value == "projectile"`) applies
  the `weapon_bleed_dot_whc` DoT (profile `bleed`, tick 0.75 s, dur 2 s, ≤3 stacks) —
  the SAME bleed WHC Flense uses — with NO crit gate. Turned off on some weapons
  (hagbane / deus) via the `kerillian_critical_bleed_dot_disable` perk (skipped when the
  attacker carries it). Rather than force the DoT (gameplay change, the Flense route),
  it is PROJECTED with the shared `dot_sim` module: per projectile hit we compute one
  bleed tick's damage by re-running `calculate_damage` with the `bleed` profile / neck /
  crit=false / boost=0 / `dot_debuff` source (exactly what the game's DoT tick does),
  and hand it to `dot_sim`, which schedules the ticks forward until the unit dies.
  Pure estimate, equip-independent, no gameplay.
- **Drakira's Alacrity** (`kerillian_waywatcher_attack_speed_on_ranged_headshot`): a
  RANGED HEADSHOT (head/neck, not melee — `add_buff_on_ranged_headshot`; the
  `buff_on_stacks=5` field is IGNORED by the func) grants +15% attack speed for 5 s.
  Attack speed affects BOTH melee and ranged, so it is valued with the shared
  `attack_speed_sim` fed BOTH the melee swing stream AND the ranged shot stream, each
  swing/shot boosted ×1.15 while the Drakira window is up (armed after a ranged headshot,
  refreshed per headshot). Shows Extra Damage + an uptime %. Like the L20 Enhanced
  Training panel, an EQUIPPED Drakira contaminates the observed cadence (real
  swings/shots already sped up), so the panel warns to unequip it for a clean estimate.
  **Tourney Balance** buffs Drakira to **+20% attack speed for 10 s**
  (`drakira_speed()` 0.15→0.20, `drakira_duration()` 5.0→10.0, resolved live via the
  shared `tb_mod_active()`); Blood Shot and Serrated Shots are unchanged by TB.

Reported Extra Damage **Total** (overkill removed) / **Uncapped** (raw) / **Real
Total** (kill-aware), per unit-category buckets merged by the filter; Drakira shows
only a ghost-delta Total (ESTIMATION) plus uptime. **Real Total** uses the shared
`kill_tracker` exactly like Famished Flames — only **Blood Shot** feeds it (its own
`kill_tracker` instance): each extra-arrow-credited hit adds a `{without=final,
with=2×final}` pair (baseline = the real shot that lands either way; with = real shot
+ the duplicate extra arrow), so the tracker credits only the part of the extra arrow
that actually pulled the kill sooner, calibrated against the real applied damage.
**Serrated Shots** shows `-` (a forward DoT projection has no real `add_damage` to
calibrate, like Lingering Flames) and **Drakira** shows `-` (an attack-speed cadence
estimate, like Enhanced Training). All three Total/Uncapped figures are ESTIMATES and
host-only. Drag pos `l10ws_pos_x/y`; appears under the **Lvl 10** tab.

**Shared `modules/dot_sim.lua`** — reusable, talent-agnostic DoT PROJECTION engine
(the DoT analogue of `attack_speed_sim`). Described by `{ tick_interval, duration,
max_stacks }`; `:apply(unit, tick_dmg, now, hp0, cat)` adds/refreshes a stack (cap
`max_stacks`, refresh whole expiry to now+duration), `:update(dt, now, alive_fn)`
emits a tick worth `tick_dmg × stacks` every `tick_interval` while armed and banks
dead units, `:totals()` returns overkill-capped + raw sums over the filter-enabled
categories. An UPPER-BOUND estimate (assumes every projected tick lands), equip-
independent (never touches gameplay). Currently used by Serrated Shots for
`weapon_bleed_dot_whc`.

## Talent group: Level 20 Mercenary (`modules/level20_merc_talents.lua`)

CAREER-SPECIFIC (`es_mercenary`; panel + sim gated on `show_level20` AND Merc,
like the WHC L10 module). Merc's passive **Paced Strikes**
(`markus_mercenary_passive`, targets 3 / `markus_mercenary_passive_proc` mult 0.1,
6 s): a light/heavy hitting ≥3 targets → +10% attack speed 6 s. The L20 row
modifies it; Merc picks 2 of 3:
- **Reikland Reaper** (`markus_mercenary_passive_power_level_on_proc`): the ≥3 proc
  also grants +15% power 6 s (`markus_mercenary_passive_power_level` mult 0.15);
  attack speed unchanged. Valued like EP — re-run each real hit with ×1.15 power
  (via the shared L15 `apply_buffs_to_power_level` hook + `mod._l20_power_mult`),
  crediting the delta ONLY while base Paced Strikes is up. Also a **Real Total**
  column (kill-aware, shared `kill_tracker`): only **Reikland Reaper** feeds it
  (per-hit power boost); **Enhanced Training** and **Strike Together** show `-` (their
  ghost-swing attack-speed estimates have no per-real-hit kill model). Total/First/Uncapped,
  same overkill model as L15. All sources (melee/ranged/DoT). Force-cleave not
  modeled (phase 2).
- **Enhanced Training** (`markus_mercenary_passive_improved`, targets 4 / mult 0.2):
  the proc now needs ≥4 targets and gives +20% attack speed. It REPLACES base PS —
  with it equipped a <4 hit grants nothing (`buff_templates.lua`
  `gain_markus_mercenary_passive_proc`), so uptime can be LOWER despite the bigger
  bonus. Valued via the reusable **`attack_speed_sim`**: two ghost-swing sims over
  the same real melee swings — base PS (+10% on ≥3) and ET (+20% on ≥4) — reporting
  `ET.extra − base.extra` as Extra Damage plus Extra DPS, with a base-vs-ET uptime
  comparison.
- **Strike Together** (`markus_mercenary_passive_group_proc`): on a ≥3-target melee
  proc, spreads the +10% PS buff to EVERY living ally (`buff_templates.lua`
  `gain_markus_mercenary_passive_proc` group branch, server-gated). FORCED like
  Flense: the talent has `buffs = {}` and the game gates the spread on `has_talent`,
  so it can't be forced by adding a buff — instead, when it isn't equipped, on each
  real ≥3-target melee swing we replicate the group branch ourselves
  (`buff_system:add_buff(ally, "markus_mercenary_passive_proc", owner)` for each
  living ally). We only ever observe an ally's already-sped-up swings, so the value is
  a **down-sample**: reconstruct each ally's swing stream from their `calculate_damage`
  hits (no ally swing-start hook on host → segment by `ALLY_SWING_GAP` = 0.3 s time
  gap; per-target dedupe; ally whiffs are invisible), feed the shared `attack_speed_sim`
  `m = 1/1.1` for swings landed while the ally carried PS (detected via
  `buff_template_name == "markus_mercenary_passive_proc"` — the proc sub-buff has no
  `buff_type`), and report `real − ghost` = damage the spread bought. Aggregate Extra
  Damage (ESTIMATION) plus a per-ally breakdown under Show Details. Host only; ally
  hits only run `calculate_damage` on the server. Ally hits reach the module via the
  L15 `calculate_damage` hook's new `mod._l20_on_ally_hit` forward.

**Tourney Balance mode (a whole TB *version of the GUI*, not extra columns).** When
`tb_mod_active()` (`get_mod("TourneyBalance")`, same detection as the THP/L15 panels)
is true, `M.draw` dispatches to `draw_tb` instead of `draw_vanilla`, reflecting TB's
Merc rework (the changelog: ET "target requirement decreased from 4 to 3", Strike
Together "proccing Paced Strikes now requires hitting only one enemy", and the base
passive now spreads Paced Strikes to allies on its own):
- **Enhanced Training** procs at **≥3** targets under TB (`ET_TARGETS_TB`, set at
  `reset`), so ET and base PS share the ≥3 threshold; ET value is still
  `et_track.extra − base_track.extra` (now +20%@≥3 vs +10%@≥3).
- **Reikland Reaper** — unchanged (+15% power during the ≥3 Paced-Strikes window;
  "force PS proc'd on 3 hits for both Reaper and ET").
- **Strike Together** is valued as the extra damage **you AND your allies** get from
  proccing PS off a **single enemy** (≥1), **not counting** the ≥3 procs (those are
  free from the base passive and cancel out). A third local track `st_track`
  (threshold `ST_TARGETS_TB` = 1, +10%) is fed the local swing stream alongside
  base/et; **your** share = `st_track.extra − base_track.extra`. For **allies**, the
  vanilla forced-buff spread is **disabled under TB** (base passive already spreads;
  forcing would double-apply/change gameplay) — instead each ally gets two ghost sims
  (`base_sim`/`st_sim`) fed off the **Merc's own proc windows** captured at ally
  swing start (`base_track.expiry` = Merc ≥3 window, `st_track.expiry` = Merc ≥1
  window); ally share = `st_sim.extra − base_sim.extra`. `st_total` sums you + all
  allies. The difference model isolates only the extra single-enemy proc windows, so
  it holds whether or not the observed ally swings are already sped (still an
  ESTIMATION; assumes ST not equipped, host only).
- **Uptime line** switches from base-vs-ET to **base (≥3) vs Strike Together (≥1)**
  (`uptime_pct(base_track)` vs `uptime_pct(st_track)`); Details add a "you +X / allies
  +Y" split line plus the per-ally breakdown.

**Ghost-swing engine (`modules/attack_speed_sim.lua`)** — reusable, talent-agnostic.
Index-domain zero-order-hold resample: cursor `pos`; each real swing with multiplier
`m` (1+attack_speed_bonus) advances `pos→pos+m` and emits a ghost for every integer
in `[pos, pos+m)`, each valued at that swing's total real damage; `extra = ghost −
real`. `m=1`→0 extra; no swing→no advance (idle never invents damage, ghosts start
from the first swing); `m<1` (decrease) drops swings. Reproduces the reference
timeline `10,5,8,0,20 → 10,10,5,8,0,20 = +10`. Extra is an UPPER BOUND (assumes 100%
attack utilization). Whiffs are 0-damage swings (keep cadence honest).

Swing stream: no own hooks — L15's `client_owner_start_action` hook forwards melee
swing starts to `mod._l20_on_swing_start` (swing boundaries + whiffs); L15's
`calculate_damage` hook forwards each local hit to `mod._l20_on_hit` (per-swing
damage sum via per-target time dedupe, Reaper recompute). A swing that sees no hit
for 1 s is flushed in `M.update` (end-of-chain / whiff). Uptime integrated per frame
since the first swing.

## Talent group: Level 30 Bounty Hunter (`modules/level30_bh_talents.lua`)

CAREER-SPECIFIC (`wh_bountyhunter`; panel + sim gated on the local player being
Bounty Hunter, like the other career modules). NOT a damage group — it measures, PER ULT
CYCLE (like Mercenary's Ready for Action), how much each of BH's two L30 cooldown talents
refunds the career skill (**Locked and Loaded**, base cooldown 70 s, ability id 1), for
BOTH regardless of which is equipped. Three figures per talent: **Per ult** = average
NOMINAL cooldown-seconds removed per (simulated) ult cycle (`sum_secs / cycles`);
**Last / Avg** = the talent's **% share of the ult bar it removed, discounting the cooldown
combat knocked off on its own** — `removed / (base − combat)`, which equals `removed /
(removed + passive)` since `base = removed + combat + passive` (each cycle banks
`passive_secs` separately in `step_state`), last cycle + running average; **Procs** =
cumulative count of that talent's effective procs (procs that removed time from a charging
sim cooldown). E.g. a 42 s Double Shotted proc on a 70 s ult that combat also shaved 15 s
reads `42/(70−15) = 42/55 = 76 %`. Because the denominator is `removed + passive` and
passive ≥ 0, the share is provably ≤ 100 %, so a big proc can never clamp to a bogus 100 %.
(This replaced an earlier `removed / real_elapsed` share, which mixed cooldown-seconds with
real wall-clock seconds and clamped to 100 % whenever a big proc — esp. Double Shotted's
42 s — removed more cooldown than the shortened cycle's wall-clock length.) Owns no
hooks — each local-player hit is forwarded from the L15
`calculate_damage` hook via `mod._l30_bh_on_hit`; duplicate `calculate_damage` calls are
collapsed with the shared `mod._l15_melee_credit` dedupe (melee AND ranged, same as the
other forwards). BH picks 2 of 3 (the third, `..._reset_cooldown_on_stacks`, isn't tracked):
- **Just Reward** (`victor_bountyhunter_activated_ability_passive_cooldown_reduction`):
  a RANGED critical hit reduces the cooldown by `max_cooldown × 0.2` (14 s at base), at
  most once per lockout (**10 s vanilla, 4.5 s under TB v37** — `jr_lock()`). Source:
  `victor_bountyhunter_reduce_activated_ability_cooldown_on_passive_crit`
  (`on_critical_hit`; skipped when `attack_type` is `light_attack`/`heavy_attack`, i.e.
  melee) with a `t + cooldown` internal lockout. Detected via `ctx.is_critical_strike`
  AND `damage_profile.charge_value ∉ {light/heavy_attack}`, replicating the lockout on
  `Managers.time:time("game")` (which also auto-dedupes the duplicate calc calls).
- **Double Shotted** (`victor_bountyhunter_activated_ability_railgun`): a headshot
  (`head`/`neck`) with the sidearm special (weapon `buff_type == "RANGED_ABILITY"`) reduces
  the cooldown by `max_cooldown × 0.6` (42 s), **once per volley**. Source: the railgun
  buff_func adds `..._railgun_delayed_add` (`max_stacks = 1`, `multiplier = 0.6`, removed
  0.25 s later → `reduce_activated_ability_cooldown_percent(0.6)`); the `max_stacks = 1` is
  what makes "even though two bullets are shot, this can only apply once" true, so a 0.25 s
  lockout collapses the two-bullet volley into one credit. **Tourney Balance** raises the
  headshot CDR to **0.8** (56 s at base) — `ds_mult()` resolves 0.6/0.8 live via the shared
  `tb_mod_active()`. Just Reward's per-proc CDR (0.2) and the base ult cooldown (70 s)
  are unchanged by TB, but Just Reward's lockout drops 10 s → 4.5 s under TB (see above).
  `buff_type` is derived exactly as
  the game does: `DamageUtils.get_item_buff_type(ctx.damage_source)`.

**EQUIP-INDEPENDENT ESTIMATE (why it does NOT read the real cooldown for the math).**
Clamping reductions against the real remaining cooldown / dividing by the real recharge time
would make the numbers depend on which talent is actually equipped (an equipped Double Shotted
shrinks the real cooldown that Just Reward's estimate is then measured against, and vice-versa).
Instead each talent runs its OWN SIMULATED cooldown so both read the same value regardless of
loadout. Per talent: `{ charging, cd, el, removed, base }`. A simulated cycle starts when the
player REALLY activates the ult AND that talent's sim ult is ready (`start_state`, `maxcd`
base); a talent still charging ignores the activation (couldn't recast in its own world). Each
frame (`step_state`) the sim `cd` decays by `passive (dt × cooldown_regen)` + `combat` — the
run's real combat rate, derived from the real timeline (`(prev_cd − cd) − passive`, so it
captures cooldown-on-hit AND cooldown-on-damage-taken exactly, no hardcoded per-career values)
but with the equipped L30 talent's INSTANT drops stripped (`> SPIKE = 8 s` in one frame → a
talent/potion proc, not combat, excluded) so the base+combat rate is loadout-independent. Each
talent proc (`proc_state`, from `on_hit`) removes `min(base × mult, sim cd)` from ONLY that
talent's sim cd and banks it; a proc while its sim ult is ready removes 0. On `cd ≤ 0`,
`finalize_state` records `removed / el` (%, clamped) + `removed` seconds. Only real activations
are read off `current_ability_cooldown(1)`; the recharge math is entirely simulated. **Accuracy
note:** combat is only observed while the REAL ult is on cooldown, so HOLDING a ready ult while
a slower talent's sim ult is still charging contributes only passive (combat unseen) → a slower
talent's recharge can read slightly long; prompt recasts minimise this. Host-most-accurate
(`calculate_damage` resolves server-side); the local player's own cooldown is authoritative
client-side too. Drag pos `l30bh_pos_x/y`; appears under the **Lvl 30** tab, alongside
Mercenary's Ready for Action (also an L30 talent).

## Crit rate tracker (`modules/crit_tracker.lua`)

NOT a talent group (no per-talent value, no settings section pattern beyond a single
toggle) — a small utility panel showing the local player's crit rate this run, split
**Melee** / **Ranged**, each with two rows:
- **Hits** — of attacks that actually connected with an enemy (ran
  `DamageUtils.calculate_damage`), % that were crits. DoT ticks
  (`damage_profile.is_dot`) are excluded (not attack rolls). Forwarded from the
  level-15 module's single `calculate_damage` hook via `mod._crit_on_hit(ctx)`,
  reusing `dp.charge_value == "light_attack"/"heavy_attack"` for the melee/ranged
  split and `mod._l15_melee_credit` for the same dual-wield-safe melee dedupe the
  L10/L20 modules use.
- **Total** — of every swing/shot attempted, whether or not it connected, % that
  were crits (the true crit-chance rate; a whiffed sweep or a shot into empty air
  still rolled a crit that Hits never sees). The roll happens once per attempt in
  `ActionUtils.is_critical_strike`, independent of hitting anything:
  - Melee: forwarded from the level-15 module's `ActionSweep.client_owner_start_action`
    hook via `mod._crit_on_melee_swing(self)` (`self._is_critical_strike` is already
    set by the time that hook_safe callback runs).
  - Ranged: this module hooks the roll sites directly (nothing else hooks these
    classes, so no VMF duplicate-hook conflict): `ActionRangedBase._start_shooting`
    (bow/crossbow/handguns/thrown/etc using the shared base impl) and
    `ActionShotgun.client_owner_start_action` (shotgun-family weapons, which
    override the base shooting flow and roll crit in start_action instead). Known
    gap: a few weapons roll crit in their own overridden methods (e.g. beam/channel
    staves) and are not covered by Total; their Hits are still counted correctly.

Also tracks **Headshot Rate** (Melee / Ranged), hits-only (a miss can't be a
headshot): forwarded from the level-15 module's single `calculate_damage` hook
via `mod._crit_on_hit(ctx)` (ctx = every calculate_damage argument + real final
damage, already filtered to the local player's genuine hits). A hit is a headshot
when `ctx.hit_zone_name == "head" or "neck"` (the same weakspot check the level-15
stagger model uses). DoT ticks excluded; melee/ranged split via
`damage_profile.charge_value`; melee hits deduped via the shared
`mod._l15_melee_credit` (dual-wield-safe, same as the L10/L20 forwards).

Setting id `show_crit_tracker`, drag position `crit_pos_x/y`.

## Talent group: Career-skill ult cooldown refund (`modules/career_ult_refund.lua`)

NOT a talent-damage group — tracks how much the local player's **career skill
(ultimate) cooldown** was refunded, per completed ult cycle (activation → ready).
Setting `show_ult_refund`; no hooks — measured purely by sampling
`CareerExtension:current_ability_cooldown(1)` (current, max) each frame in
`M.update`. Two panels, split across tabs by draw-only wrappers in the entry file
(`M.draw_combat` / `M.draw_rfa` + `M.rfa_wants_display`; the module keeps one shared
sampling engine and stays in `groups` for update/reset/init):

- **Combat Ult Refund** (all careers): combat-driven reduction as a % of the base
  cooldown, `combat_seconds / max_cooldown`. Shows last ult + running average. Drawn
  under the **Other Stats** tab.
- **Ready for Action** (only Mercenary `es_mercenary` with talent
  `markus_mercenary_activated_ability_cooldown_no_heal`): RFA's own share of the
  ACTUAL, already-combat-shortened recharge time — `rfa_seconds /
  actual_recharge_time`, where `rfa_seconds = max_cooldown × 0.2` is the talent's
  fixed instant discount (an `activated_cooldown` −0.2 stacking multiplier applied
  at use, so the cooldown starts at base×0.8; `max_cooldown` itself is unchanged).
  E.g. a 90 s ult that actually came back in 36 s thanks to combat still owes 18 s
  of that to RFA alone — 18/36 = 50% of the real wait. Last + avg. Drawn under the
  **Lvl 30** tab (it is a Mercenary L30 talent), beside the BH L30 panel.

Mechanics (`career_extension.lua`): passive decay is
`reduce_activated_ability_cooldown(dt × cooldown_regen)` per frame; combat
reductions (cooldown-on-hit / cooldown-on-damage-taken — see the appendix table)
are EXTRA reductions on top. So each frame `combat = (prev_cd − cd) − dt ×
cooldown_regen` (clamped ≥0, `cooldown_regen` from `buff_ext:apply_buffs_to_value(
1,"cooldown_regen")`) is accumulated; cycle finalizes when `cd` hits 0. Activation
is detected as a jump up from ready (`prev_cd ≤ 1` → `cd > 5`). Any non-passive
reduction counts as "combat" (a Concentration-Potion reset or kill-cooldown talent
would too). Correct client-side (local player's own cooldown is authoritative).

**Tourney Balance:** no code change needed. TB rebalances many career ult cooldowns
(e.g. Huntsman 90→75, FK 30→40, WS 80→65, SotT 40→60, BW 50→60) and per-hit/damage
CDR rates, but both panels read the **live** `CareerExtension:current_ability_cooldown(1)`
(current + max) every frame, and RFA's discount is `max_cooldown × 0.2` off the live max,
so they automatically track whichever mod is loaded.

## Deploying / testing locally

From `vermintide-mod-builder/`, build and locally install the mod (no Steam
Workshop upload) with:

```
./vmb.exe build TalentComparisonMod -g 2
```

This copies the built bundle into the local Steam workshop content folder, so
it's picked up by the in-game mod manager on next launch/restart of VT2.
Equivalent to running `_Build Mod.bat` and entering `TalentComparisonMod` / `2`
at the prompts.

To push the change to the Steam Workshop (affects other subscribers — confirm
before doing this), run `./vmb upload TalentComparisonMod -g 2` afterward, or use
`_Upload Mod.bat`.

## Future talent groups

Follow the same module/panel/settings pattern; document each group's mechanics
here with a distinct section. Candidates: level 10, 20, 25, 30 rows.

## Appendix: Career Skill Cooldown and Cooldown On Hit/Damage Taken Table

Career	Career Skill Cooldown
(seconds)	Cooldown on hit
(seconds per hit)	Cooldown on damage taken
(seconds per damage taken)
Mercenary	90	0.5	0.5
Huntsman	90	0.3	0.4
Foot Knight	30	0.25	0.5
Grail Knight	60	0.25	0.25
Ranger Veteran	120	0.3	0.3
Ironbreaker	120	0.25	0.5
Slayer	40	0.5	0.1
Outcast Engineer	60/90	0	0
Waystalker	80	0.35	0.3
Handmaiden	20	0.25	0.5
Shade	70	0.5	0.2
Sister of the Thorns	40	0.3	0.4
Witch Hunter Captain	90	0.5	0.2
Bounty Hunter	70	0.25	0.3
Zealot	60	0.5	0.2
Warrior Priest of Sigmar	70	0.25	0.25
Battle Wizard	50	0.25	0.5
Pyromancer	50	0.25	0.3
Unchained	120	0.25	0.5
Necromancer	110	0.25	0.25