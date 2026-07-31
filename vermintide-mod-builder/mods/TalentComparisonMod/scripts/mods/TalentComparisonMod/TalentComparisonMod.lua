local mod = get_mod("TalentComparisonMod")

-- Talent Comparison Mod
-- ============================================================================
-- Shows, as running totals for the current run, how much value EACH talent in a
-- row would provide, regardless of which is equipped. Each talent row is a fully
-- distinct group: its own module file, on-screen panel, and settings.
--
-- This entry file is a thin dispatcher. It loads the shared UI framework and one
-- module per talent group, then drives their update / reset / game-state hooks.
-- Adding a future group = one new module + one settings checkbox (see CLAUDE.md).
-- ============================================================================

local BASE = "scripts/mods/TalentComparisonMod/modules/"
local ui    = mod:dofile(BASE .. "ui_panel")
-- Shared per-unit-category bucketing + the global display filter. Loaded first and
-- exposed as mod._filter so every value module can F.add/F.read through it.
local filter = mod:dofile(BASE .. "unit_filter")
filter.init(mod)
mod._filter = filter
-- Gameplay-affecting feature switchboard (master consent + per-feature gates,
-- L15-row unequip). Loaded before the value modules so mod._gameplay_on exists.
local gameplay = mod:dofile(BASE .. "gameplay_control")
local control = mod:dofile(BASE .. "control_panel")
local thp   = mod:dofile(BASE .. "thp_talents")
local level15 = mod:dofile(BASE .. "level15_talents")
local level10 = mod:dofile(BASE .. "level10_whc_talents")
local level10_merc = mod:dofile(BASE .. "level10_merc_talents")
local level10_bw = mod:dofile(BASE .. "level10_bw_talents")
local level10_ws = mod:dofile(BASE .. "level10_ws_talents")
local level20 = mod:dofile(BASE .. "level20_merc_talents")
local level30_bh = mod:dofile(BASE .. "level30_bh_talents")
local ult_refund = mod:dofile(BASE .. "career_ult_refund")
local crit_tracker = mod:dofile(BASE .. "crit_tracker")

-- Every talent-group module implements: init(mod, ui), reset(), wants_display(), draw(gui).
-- level15 owns the single DamageUtils.calculate_damage hook (VMF ignores a duplicate
-- hook on the same func from the same mod) and forwards each local-player hit to
-- mod._l10_on_hit, which level10.init installs; the forward is resolved at call time,
-- so init order does not matter.
-- level20 (Mercenary) also piggybacks on level15's shared hooks (calculate_damage,
-- client_owner_start_action, apply_buffs_to_power_level) via mod._l20_* forwards.
-- level10_merc registers power_boost instances, so it must init AFTER level15 (which
-- owns mod._power_boost); its position after level15 in this list guarantees that.
-- control_panel is FIRST: it is always drawn (even while everything else is hidden)
-- so the Hide/Show + unit-filter buttons stay reachable.
-- level10_bw (Battle Wizard) also piggybacks on level15's shared calculate_damage
-- hook via mod._l10_bw_on_hit and reuses mod._kill_tracker, so it must init AFTER
-- level15 (which owns those); its position after level15 here guarantees that.
-- level10_ws (Waystalker) also piggybacks on level15's shared calculate_damage /
-- ActionSweep hooks via mod._l10_ws_* forwards and reuses the shared attack_speed_sim
-- + dot_sim modules, so it must init AFTER level15; its position after it guarantees that.
local groups = { control, gameplay, thp, level15, level10, level20, level10_merc, level10_bw, level10_ws, level30_bh, ult_refund, crit_tracker }

-- Draw-only wrappers that route the two ult-refund panels onto different tabs
-- (Combat Ult Refund -> Other Stats; Ready for Action -> Lvl 30, as a Mercenary
-- L30 talent). The real career_ult_refund module stays in `groups` above so its
-- shared cooldown-sampling engine still gets init/update/reset once; these facades
-- only implement the wants_display/draw the tab loop calls.
local ult_combat = {
	wants_display = function () return true end,
	draw = function (gui) ult_refund.draw_combat(gui) end,
}
local ult_rfa = {
	wants_display = function () return ult_refund.rfa_wants_display() end,
	draw = function (gui) ult_refund.draw_rfa(gui) end,
}

-- Tab bar (control panel): one TOGGLE button per tab, ordered by talent level,
-- utility panels grouped under "Other Stats". Each tab independently shows/hides
-- its module(s)' free-floating draggable panel(s); any number can be on at once.
-- A tab only appears while one of its modules is available (career-gated tabs
-- follow the current career).
local TABS = {
	{ id = "lvl5",  label = "Lvl 5",       groups = { thp } },
	{ id = "lvl10", label = "Lvl 10",      groups = { level10, level10_merc, level10_bw, level10_ws } },
	{ id = "lvl15", label = "Lvl 15",      groups = { level15 } },
	{ id = "lvl20", label = "Lvl 20",      groups = { level20 } },
	{ id = "lvl30", label = "Lvl 30",      groups = { level30_bh, ult_rfa } },
	{ id = "other", label = "Other Stats", groups = { ult_combat, crit_tracker } },
}
mod._tabs = TABS

-- Per-tab visibility toggle (persisted; default on). Shared with the control
-- panel, which draws the toggle buttons.
mod._tab_enabled = function (id)
	local v = mod:get("show_tab_" .. id)
	if v == nil then return true end
	return v
end

local function reset_all()
	-- Snapshot every group's totals to chat/log before clearing, so the Reset
	-- button / keybind / mission-entry reset all leave a verifiable record.
	for _, g in ipairs(groups) do
		if g.log_state then pcall(g.log_state) end
	end
	for _, g in ipairs(groups) do
		g.reset()
	end
end

ui.init(mod, reset_all)
for _, g in ipairs(groups) do
	g.init(mod, ui)
end

-- ---------------------------------------------------------------------------
-- Only draw the panels while actually playing a mission -- never on the main
-- menu, loading screens, or before the local player has spawned. This gates
-- DRAWING only; the per-group simulation and totals-reset logic are untouched.
-- ---------------------------------------------------------------------------
local function in_mission()
	if not RESOLUTION_LOOKUP or not RESOLUTION_LOOKUP.res_w then return false end
	local pm = Managers.player
	if not pm then return false end
	local ok, player = pcall(function () return pm:local_player() end)
	if not ok or not player then return false end
	local unit = player.player_unit
	return unit ~= nil and Unit.alive(unit)
end

-- ---------------------------------------------------------------------------
-- Update loop: draw each enabled group's panel.
-- ---------------------------------------------------------------------------
mod.update = function (dt)
	if not mod:is_enabled() then return end

	-- Advance per-group simulation (e.g. THP decay) every frame, regardless of
	-- whether the panel is currently displayed, so running totals stay correct.
	for _, g in ipairs(groups) do
		if g.update then g.update(dt) end
	end

	-- Do not draw outside an active mission (menu / loading / not yet spawned).
	-- Also drop any cached GUI handle here: a level teardown/restart (e.g. the
	-- "Restart Level" mod) destroys the screen GUI while REUSING the level_world
	-- table (same pointer), so ui.get_gui()'s world-identity check would happily
	-- hand back a dead handle on re-entry. Drawing into that raises a hard C++
	-- access violation (0xc0000005) that pcall CANNOT catch -- it crashes the game
	-- outright. Invalidating whenever we're between missions guarantees a fresh
	-- GUI is built the next time we actually draw.
	if not in_mission() then
		ui.invalidate_gui()
		return
	end

	-- Global hide: when on, only the control panel is drawn so the Hide/Show +
	-- filter + tab buttons stay reachable to bring the content back.
	local hidden = mod._hide_all == true

	local gui = ui.get_gui()
	if not gui then return end

	local cursor_active = ui.cursor_active()

	-- Guard each draw: if the cached GUI has gone stale (an incompatible mod or a
	-- level teardown can destroy it without the world changing), Gui.rect/Gui.text
	-- throws "Gui expected, got userdata". Swallow it and invalidate the GUI so
	-- it's rebuilt next frame instead of aborting the whole update (which left
	-- the panels permanently blank).
	local function safe_draw(g)
		local ok, err = pcall(g.draw, gui)
		if not ok then
			ui.invalidate_gui()
			if err then mod:dump(err, "TalentComparisonMod draw", 1) end
			return false
		end
		return true
	end

	-- The control panel (tab bar host) is always drawn so the Hide / filter /
	-- tab-toggle buttons stay reachable.
	if not safe_draw(control) then return end

	-- Draw every toggled-on tab's module panels (free-floating, individually
	-- draggable), unless the global Hide is on.
	if not hidden then
		for _, tab in ipairs(TABS) do
			if mod._tab_enabled(tab.id) then
				for _, g in ipairs(tab.groups) do
					if g.wants_display() and not safe_draw(g) then return end
				end
			end
		end
	end

	ui.end_frame(cursor_active)
end

-- ---------------------------------------------------------------------------
-- Reset totals on new mission / via keybind
-- ---------------------------------------------------------------------------
mod.reset = function ()
	reset_all()
	mod:echo("Talent comparison totals reset.")
end

-- Bound to the Hide keybind (unbound by default): toggle the global hide-all so
-- every panel except the control panel is shown/hidden.
mod.toggle_hide = function ()
	filter.toggle_hidden()
end

local function current_level_is_hub()
	local lth = Managers.level_transition_handler
	if not lth then return false end
	local ok, level_key = pcall(function () return lth:get_current_level_keys() end)
	if not ok or not level_key then return false end
	local settings = LevelSettings and LevelSettings[level_key]
	return settings and settings.hub_level == true
end

mod.on_game_state_changed = function (status, state_name)
	-- Any game-state transition (loading, restart, leaving a mission) can tear
	-- down the screen GUI out from under us. Always drop the cached handle so it
	-- is rebuilt fresh rather than reused as a dead pointer (see the update loop).
	ui.invalidate_gui()

	if status == "enter" and state_name == "StateIngame" then
		mod._is_hub = current_level_is_hub()
		-- Auto-clear totals on entering a non-hub mission, UNLESS the user turned
		-- off the "Reset On Restart" panel toggle (default on) -- then totals carry
		-- across a restart / new mission until Reset is pressed manually.
		local reset_on_restart = mod:get("reset_on_restart")
		if reset_on_restart == nil then reset_on_restart = true end
		if not mod._is_hub and reset_on_restart then
			reset_all()
		end
	end
end

mod.on_enabled = function ()
	-- nothing special
end

mod.on_disabled = function ()
	-- Hand back anything we changed in gameplay (the removed L15 talent row) before
	-- going quiet; the forced buffs/spreads simply stop being maintained.
	gameplay.restore()
end
