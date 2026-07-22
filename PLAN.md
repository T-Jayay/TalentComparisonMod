# TalentComparisonMod — Cleanup & Level 15 Rework Plan

## 1. Project cleanup

**Stale folders to delete** (leftovers from the two renames; permission was denied to auto-delete, remove manually or approve):
- `vermintide-mod-builder/mods/TalentComparisonModV2/` (empty shell)
- `vermintide-mod-builder/mods/TempHealthTalentComparisonV2/` (empty shell)
- `vermintide-mod-builder/mods/.temp/TalentComparisonModV2/` (build cache of dead mod)
- `vermintide-mod-builder/mods/.temp/TempHealthTalentComparisonV2/` (build cache of dead mod)

The only live mod is `vermintide-mod-builder/mods/TalentComparisonMod/`.

**Code restructure — one file per talent group.** Split the 900-line
`TalentComparisonMod.lua` so each talent section is fully distinct and future
groups slot in the same way:

```
scripts/mods/TalentComparisonMod/
  TalentComparisonMod.lua        -- entry: mod:dofile() the modules, update loop,
                                    game-state reset, reset keybind
  TalentComparisonMod_data.lua   -- settings (grouped per panel, see §4)
  TalentComparisonMod_localization.lua
  modules/ui_panel.lua           -- shared draggable-panel framework (panel_frame,
                                    draw_text/rect, mouse helpers, gui acquisition)
  modules/thp_talents.lua        -- Temp Health group: totals, formulas, TB tables,
                                    trigger_procs hook, draw function  (UNCHANGED logic)
  modules/level15_talents.lua    -- Level 15 group: reworked per §3
```

Each module exposes `init(mod)`, `reset()`, `wants_display()`, `draw(gui)` so the
entry file stays a thin dispatcher and a future group is just one new module +
one settings checkbox.

## 2. Temp Health group (level 5)

No behavior changes — user is happy with it. Just moves into
`modules/thp_talents.lua` verbatim (formulas, TB column, corpse-stagger fix).

## 3. Level 15 group rework

All numbers are **running damage totals for the current run — never DPS**.
(Fix the localization strings that still say "DPS".)

Panel layout per talent — two columns, explicitly labeled:

```
Level 15 Talents — Extra Damage
              Total    First
Smiter          123       88
Mainstay        ...      ...
Assassin        ...      ...
Bulwark         ...      ...
Enh. Power      ...      ...
EP cleave: +N units, +X dmg      (only meaningful with Force EP on)
```

- **Total** = summed extra damage the talent would have added this run, all targets.
- **First** = same, but only hits with `target_index == 1`.

### 3a. Smiter / Mainstay / Assassin (stagger-number model — keep current approach)

The existing `account_hit()` inversion is correct and stays: hook
`DamageUtils.calculate_damage`, invert the real hit back to base damage using the
equipped talent's stagger number, then re-apply each talent's stagger-number rule
(`smiter`: first target S=max(1,S); `mainstay`: S>0 → S+1; `assassin`:
crit/headshot → S=2) and accumulate `base * (bonus(S_talent) − bonus(S_none))`.

### 3b. Bulwark (self-only estimate — replace current approximation)

Drop the current "+1 effective stagger tier" guess. Bulwark's real differentiator
is: enemies **you stagger** take **+10% melee damage for 2 s**. Estimate only the
player's own benefit, not allies':

1. In the existing `DamageUtils.server_apply_hit` hook (which already runs
   `calculate_stagger_player`), when the player's hit staggers a unit, record
   `bulwark_marks[unit] = t + 2.0` (game time).
2. In `account_hit()`, for melee hits where `bulwark_marks[target_unit] > t`:
   `extra = base_damage * (coeff + bonus_for(base_sn)) * 0.10`
   i.e. 10% on top of what the hit would deal with no level-15 talent. Add to
   Total/First. (Bulwark's stagger-damage perk is identical to the baseline
   perk everyone effectively compares against, so the 10% aura is the whole delta.)
3. Prune expired marks lazily on hit; clear the table on reset.

Limitation to document in-code: uses the player's own staggers only, so it
understates Bulwark in coordinated play — that is intended per spec.

### 3c. Enhanced Power (all sources + Force EP setting)

**Extra damage (keep, it's already right):** every hit — melee, ranged, DoT
ticks — is recomputed by calling the unhooked `calculate_damage` at
`power_level * 1.075`; the delta goes to EP Total/First. This respects armor
breakpoints rather than a flat 7.5%.

**New setting `force_ep` ("Force Enhanced Power"):** when enabled the mod makes
the game behave as if EP were equipped, so the extra cleave actually happens and
can be measured on real hits:

1. Hook `ActionUtils.scale_power_levels` (or apply a `power_level` /
   `power_level_melee_cleave` multiplier via a hook on
   `BuffExtension.apply_buffs_to_value` for the local player) to multiply the
   player's power by 1.075 **only if** no EP-style buff is already present.
   Simplest reliable point: in the `ActionSweep.client_owner_start_action` hook
   we already have, plus a `calculate_damage` power-level override — verify in
   testing which single hook covers both cleave-target count and damage.
   Note this is a gameplay-affecting cheat — modded-realm only.
2. **Extra units hit:** per sweep, compute `base_max = get_max_targets(dp, cpl)`
   *without* EP (existing `account_sweep` baseline). During that sweep, any hit
   with `target_index > floor(base_max)` is a unit only reached because of EP →
   increment `extra_units_hit`.
3. **Extra cleaved damage:** for each such extra unit, add its full final hit
   damage to `extra_cleave_dmg` (the entire hit on that unit exists only because
   of EP).
4. Display line: `EP cleave: +N units, +X dmg`. When `force_ep` is off, keep the
   current hypothetical extra-units counter but label it as an estimate.

### 3d. Bookkeeping

- Per-talent record: `{ total_dmg, first_dmg }`; EP additionally
  `{ extra_units_hit, extra_cleave_dmg }`.
- Reset on new non-hub mission, reset button, and reset keybind (unchanged).

## 4. Settings (grouped per talent section)

Use VMF sub_widgets so the mod options mirror the group structure:

- **Temp Health panel** (checkbox, default on) — sub: Show Tourney Balance column.
- **Level 15 panel** (checkbox, default off) — sub: Force Enhanced Power (default
  off, warns it changes gameplay).
- Reset keybind (global).

## 5. Verification

1. `_Build Mod.bat` → TalentComparisonMod builds clean.
2. In modded realm, host a custom game: melee a horde and check Smiter First ≈
   20% of first-target base damage on unstaggered hits, Mainstay 0 on
   unstaggered targets, Assassin credit on headshots/crits only.
3. Bulwark: shove then hit within 2 s → credit; hit after 3 s → none.
4. Force EP off vs on: with a high-cleave weapon confirm extra units are actually
   hit with the setting on and both EP cleave counters advance.

## 6. Future talent groups

Adding a group = new `modules/<group>.lua` implementing
`init/reset/wants_display/draw`, one settings checkbox, a CLAUDE.md section
documenting the mechanics. Candidates: level 10 (offense stats), level 20
(survival), level 25 (mobility/utility), level 30 (ult mods).
