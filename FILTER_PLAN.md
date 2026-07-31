# Main Control Panel + Per-Unit-Category Stat Filtering — Implementation Plan

> Working plan. Progress is tracked with the checklist at the bottom. If a session
> ends mid-way, resume from the first unchecked box.

## Goal

1. A **main control panel** with a single **Hide-all** button (also toggleable via a
   keybind) that shows/hides every other panel, plus four **unit-filter buttons**:
   **All / Elites+Specials / Monsters / Trash**.
2. Every panel's values tracked **per unit category** so a filter button switches all
   panels to show only that category's stats (All = sum of all three).
3. Attack-speed (ghost-swing) panels valued **per unit category** — only hits on units of
   a category feed that category's bucket.

Confirmed decisions:
- Three categories: `es` (Elites + Specials), `mon` (Monsters + Bosses + Lords), `trash`.
- Buttons: **All / Elites+Specials / Monsters / Trash**.
- Main panel **replaces** the per-panel Hide buttons.
- Hide keybind ships **unbound** (like Reset keybind).

## Category definition

Breed tables carry `elite` / `special` / `boss` bools (lords are `boss = true`).
- `es`    = `breed.elite or breed.special`
- `mon`   = `breed.boss`
- `trash` = otherwise
Resolve with `AiUtils.unit_breed(unit)` (already used in level15).

## Core: modules/unit_filter.lua (new, `mod._filter`)

- `F.cat_of(unit)` -> `"es"|"mon"|"trash"` (nil breed -> trash).
- State on `mod`: `mod._unit_filter` (`"all"|"es"|"mon"|"trash"`), `mod._hide_all` (bool),
  each backed by persisted settings (`unit_filter`, `hide_all`), loaded in `init`.
- `F.add(rec, field, cat, v)`: lazily `rec[field] = {es=0,mon=0,trash=0}`, add v to slot.
- `F.read(rec, field)`: sum slots selected by `mod._unit_filter` (all -> all three).

This bucketed-field pattern is applied everywhere a running total is stored/read.

## Per-module bucket substitution

`rec.field = rec.field + x`  ->  `F.add(rec,"field",cat,x)`;  read `rec.field` ->
`F.read(rec,"field")`. Thread `cat` from `F.cat_of(target_unit)` through credit paths.
- level15_talents.lua: `credit`/`account_hit` (~549-556, 676-680) + draw (~968-1082).
  Add `ctx.cat = F.cat_of(target_unit)` in the shared calculate_damage hook so all
  forwarded modules (`_l10_on_hit`, `_l10_merc_on_hit`, `_l20_on_hit`,
  `_l20_on_ally_hit`, `_crit_on_hit`) reuse it.
- level10_whc / level10_merc / level20_merc / thp_talents / crit_tracker: same. THP decay
  & blocked pools go per-category. crit_tracker: Hits row is filterable; whiff/Total
  attempts have no unit — keep a note that Total is not category-split (documented).

## kill_tracker.lua

Partition by category (each unit is one category):
- `M.begin_hit(unit, model_final, health, cat)` stores `cat` in the batch.
- `Tracker:track` routes into `self.kills[cat][talent]`.
- `Tracker:get(talent)` sums selected categories (Hits/Kill avg from summed sums).
- `Tracker:reset` clears per-category tables.

## attack_speed_sim.lua + L20 ghost swings

Per-swing damage becomes `dmg_by_cat` (`{es,mon,trash}`). The index-domain resample emits
ghosts per category (`extra[cat] = ghost[cat] - real[cat]`); reported extra/DPS are
filtered sums. Applies to Reikland Reaper, Enhanced Training, Strike Together (ally sims
tag by ally-hit target category via `_l20_on_ally_hit`).

## modules/control_panel.lua (new)

- `wants_display()` = enabled + in mission; ALWAYS drawn (ignores hide).
- `draw`: draggable panel (`ctl_pos_x/y`), title, Hide/Show button (toggles
  `mod._hide_all`), four filter buttons (All/E+S/Monsters/Trash, active highlighted).
- Reuse `ui.rect/ui.text`; expose `point_in_box`/`get_mouse`/`mouse_left_down` from
  ui_panel.lua for hit-testing.
- `mod.toggle_hide` keybind flips `mod._hide_all`.
- Add as first entry in `groups` (TalentComparisonMod.lua:33).

## Remove per-panel Hide (ui_panel.lua ui.frame)

Delete Hide/Show button + `collapse_id`/`collapsed`/`title_visible` (ui_panel.lua
~168-266). Keep panel bg, drag, Reset, extra button. `ui.frame` returns `(x, top,
row_y)`. Update ~7 `M.draw` callers. Enforce global hide in the entry update loop
(TalentComparisonMod.lua:91-116): when `mod._hide_all`, draw only control_panel.

## Settings / localization

- data.lua: add `hide_keybind` (`function_call` -> `toggle_hide`, default `{}`).
- localization: `hide_keybind` (+ tooltip).
- entry file: `mod.toggle_hide`.

## Build / verify

`./vmb.exe build TalentComparisonMod -g 2` from vermintide-mod-builder/. In a non-hub
mission (host): Hide/Show toggles all panels + keybind; filter buttons switch every
panel; kill trash vs elite vs monster and confirm buckets; L20 attack-speed extra
changes per filter; Reset zeroes all buckets.

## Checklist

- [x] modules/unit_filter.lua (F.cat_of, add, read, merge_sets, state load/persist)
- [x] ui_panel.lua: removed per-panel Hide; exposed mouse helpers; frame kept 5-value
      return (collapsed=false,title_visible=true) so existing draw callers work unchanged
- [x] control_panel.lua (hide + 4 filter buttons, always drawn)
- [x] TalentComparisonMod.lua: dofile new modules, groups order, global-hide gate, toggle_hide
- [x] data.lua + localization: hide_keybind
- [x] level15_talents.lua: cat threading + pointer-swap totals_cat + merge in draw
- [x] kill_tracker.lua: per-category partition (kills[cat][talent]) + filter-aware get
- [x] power_boost.lua: bucketed fields + Boost:rd/:units_hit + set_category_fns
- [x] thp_talents.lua: bucketed totals (Live/TB filter; decay/dec%/blocked stay aggregate)
- [x] level10_whc_talents.lua: pointer-swap totals_cat
- [x] level10_merc_talents.lua: pointer-swap helborg/helborg_tb + boost :rd readers
- [x] level20_merc_talents.lua + attack_speed_sim.lua: per-category ghost swings (dmg_by_cat)
- [x] crit_tracker.lua: LEFT AS-IS (measures attempt rolls incl. whiffs; no target unit,
      so no unit-category dimension) — documented decision
- [x] Build passes: `./vmb.exe build TalentComparisonMod -g 2` (Finished building, 12 files compile)
- [ ] In-game verify (requires launching VT2 as host — see Verification section)

## How to continue / verify in-game (last step)

Launch VT2 with the mod enabled, enter a non-hub mission (host for full accuracy):
1. Control panel visible; **Hide** collapses all other panels, **Show** restores;
   the bound Hide keybind (set it in mod options first) toggles the same.
2. Filter buttons switch every panel: kill clanrats (Trash), a Stormvermin/Gutter
   Runner (Elites+Specials), and a Rat Ogre (Monsters); confirm each filter shows only
   that category and **All** = the sum.
3. L20 Merc attack-speed Extra Damage changes per filter (ghost swings valued only on
   the selected category's hits).
4. Reset (button + keybind) zeroes all category buckets; mission re-entry resets.

If a panel throws at draw, the entry loop invalidates the GUI and dumps the error via
`mod:dump` — check the VMF console / game log for the offending module, then inspect its
`F.merge_sets`/`:rd` read sites. Known deliberate gaps: THP Decay/Dec%/Blocked columns
and the Crit Rate panel are NOT category-filtered (documented in-code).
