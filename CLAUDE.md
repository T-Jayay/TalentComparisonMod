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
  - `modules/thp_talents.lua`, `modules/level15_talents.lua` — one per talent
    group; each returns a table implementing `init/reset/wants_display/draw`.
  - `resource_packages/.../TalentComparisonMod.package` must glob both
    `scripts/mods/TalentComparisonMod/*` AND `.../modules/*` (subfolders are not
    recursive) or new modules won't ship in the bundle.
- `vermintide-2-source-code/` — decompiled game source; the reference for all
  mechanics (esp. `scripts/utils/damage_utils.lua`: `calculate_damage`,
  `apply_buffs_to_stagger_damage`).
- `vermintide-mod-builder/_Build Mod.bat` / `_Create Mod.bat` / `_Upload Mod.bat`
  — VMB build scripts. `mods/.temp/` is regenerable build cache.

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

**Early Kills / Hits/Kill columns.** Two always-on columns after Uncapped, per row
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
reads the LOWEST Hits/Kill and (consistently) the most Early Kills. (EP's Total/First/
Uncapped *damage* columns are unchanged — still its real all-source extra vs reality.)
Bulwark's pool is shared by self + ally hits. Forced-cleave-only units are excluded
(they feed EP's cleave counters, not `kill_track`).
- **Early Kills** (`kills[t].n`) = units that would have died *earlier this run purely
  because of the talent's extra damage*: credited when `not counted` AND `with >= init`
  AND `without < init` (talent's world kills it in strictly fewer hits than the no-talent
  world), latched once per unit — the mod never applies the damage, so the real unit
  may live on and must not be recounted. A kill the talent wouldn't have pulled sooner
  (both worlds die on the same hit, e.g. 90 HP / 30-per-hit / +5 talent) is NOT counted.
- **Hits/Kill** (`hpk_sum/hpk_n`) = running average over *every unit you actually killed*
  (real killing blow detected as `health - final_damage <= 0` on your hit) of the
  **hits-to-kill in that talent's world** — `st.frozen[t]`, the hit at which the talent's
  cumulative damage (`with`) would have crossed the unit's HP, recorded for every kill
  (not just early ones), always ≤ the real hits. So a stronger talent (bigger extra, e.g.
  EP) crosses sooner and reads a LOWER Hits/Kill; a talent that never reaches the kill in
  its world falls back to the real hits. Latched per unit per talent; units killed by
  allies/DoTs you didn't land are not sampled. (Note the frozen hit is also what gates
  Early Kills, but Hits/Kill records it for ALL kills, Early Kills only the strictly
  earlier subset.)

**Tourney Balance mode.** When the TB mod is loaded+enabled (`tb_mod_active()` =
`get_mod("TourneyBalance")`, same detection as the THP panel) the game is already
applying TB's reworked level-15 talents, so the panel switches every value to TB's
numbers — a **single reality column** (no cross-mod estimate: the stagger number S
is read off the target blackboard, so it is always the loaded mod's real S). TB's
changes (`.../TourneyBalance/changes/thp_stagger_changes.lua`):
- **Mainstay removed** — no TB career has it (`talent_third_row` lists are
  smiter-assassin-EP / smiter-bulwark-EP / bulwark-smiter-EP). The module skips
  crediting `mainstay` and hides its row (dynamic `disp` list in `M.draw`); title
  becomes "Stagger Talents (TB):".
- **Assassin** (`finesse_unbalance`) — S=2 on head/neck **only**; crit no longer
  procs (TB's `apply_buffs_to_stagger_damage` rewrite). Gated by
  `assassin_uses_crit()` in both `talent_stagger_number` and
  `equipped_stagger_number`.
- **Bulwark** (`rebaltourn_tank_unbalance_buff`) — flat bonus **0.10→0.15**,
  window **2s→5s** (`bulwark_damage_taken()` / `bulwark_window()`). Still applied
  to the stagger bonus term, self-only melee (the "all damage types" changelog note
  is loose flavor — mechanically still the `unbalanced_damage_taken` stacking_bonus).
- **Enhanced Power** (`power_level_unbalance`) — +7.5%→**+10%** (`multiplier 0.1`).
  The shared `power_boost` instance now takes `mult` as a function (`ep_power_bonus`)
  so it resolves 0.075/0.10 live per hit/sweep; `Boost:cur_mult()` in `power_boost.lua`.
- **Smiter** — unchanged.

Exact decompiled-source file paths and line numbers for all of this are in the
`level15-source-locations` memory (buff templates, damage pipeline, buff
extension, cleave).

Setting ids: `show_thp`, `show_tb`, `show_decay`, `show_decay_pct`,
`show_blocked`, `show_level15`, `force_ep`, `show_level10`, `show_level20`,
`show_ult_refund`, plus per-panel drag positions `thp_pos_x/y`, `l15_pos_x/y`,
`l10_pos_x/y`, `l10m_pos_x/y`, `l20_pos_x/y`, `ultc_pos_x/y` (combat), `ultm_pos_x/y`
(Ready for Action).

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
**First** (target_index 1), **Uncapped** (raw). Derivation:
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
  crediting the delta ONLY while base Paced Strikes is up. Total/First/Uncapped,
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

Setting id `show_crit_tracker`, drag position `crit_pos_x/y`.

## Talent group: Career-skill ult cooldown refund (`modules/career_ult_refund.lua`)

NOT a talent-damage group — tracks how much the local player's **career skill
(ultimate) cooldown** was refunded, per completed ult cycle (activation → ready).
Setting `show_ult_refund`; no hooks — measured purely by sampling
`CareerExtension:current_ability_cooldown(1)` (current, max) each frame in
`M.update`. Two panels:

- **Combat Ult Refund** (all careers): combat-driven reduction as a % of the base
  cooldown, `combat_seconds / max_cooldown`. Shows last ult + running average.
- **Ready for Action** (only Mercenary `es_mercenary` with talent
  `markus_mercenary_activated_ability_cooldown_no_heal`): RFA's own share of the
  ACTUAL, already-combat-shortened recharge time — `rfa_seconds /
  actual_recharge_time`, where `rfa_seconds = max_cooldown × 0.2` is the talent's
  fixed instant discount (an `activated_cooldown` −0.2 stacking multiplier applied
  at use, so the cooldown starts at base×0.8; `max_cooldown` itself is unchanged).
  E.g. a 90 s ult that actually came back in 36 s thanks to combat still owes 18 s
  of that to RFA alone — 18/36 = 50% of the real wait. Last + avg.

Mechanics (`career_extension.lua`): passive decay is
`reduce_activated_ability_cooldown(dt × cooldown_regen)` per frame; combat
reductions (cooldown-on-hit / cooldown-on-damage-taken — see the appendix table)
are EXTRA reductions on top. So each frame `combat = (prev_cd − cd) − dt ×
cooldown_regen` (clamped ≥0, `cooldown_regen` from `buff_ext:apply_buffs_to_value(
1,"cooldown_regen")`) is accumulated; cycle finalizes when `cd` hits 0. Activation
is detected as a jump up from ready (`prev_cd ≤ 1` → `cd > 5`). Any non-passive
reduction counts as "combat" (a Concentration-Potion reset or kill-cooldown talent
would too). Correct client-side (local player's own cooldown is authoritative).

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
before doing this), run `vmb upload TalentComparisonMod -g 2` afterward, or use
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