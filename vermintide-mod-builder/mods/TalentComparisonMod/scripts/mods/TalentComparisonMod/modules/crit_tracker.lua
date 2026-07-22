-- crit_tracker.lua
-- ============================================================================
-- Talent group: none -- a general local-player crit-rate tracker. Shows, as a
-- running rate for the current run, how often the local player's attacks are
-- critical strikes, split Melee / Ranged. Each counter covers EVERY swing/shot
-- ATTEMPTED (hits and non-hits together), so it is the true crit-chance rate:
-- a wide sweep that whiffs on a corpse or empty air, or a shot into thin air,
-- still rolled a crit and is counted.
--
-- The count is the crit ROLL itself, which happens once per swing/shot attempt
-- (ActionUtils.is_critical_strike), independent of whether anything is hit:
--   Melee  -- forwarded from the level-15 module's ActionSweep.client_owner_start_action
--             hook (mod._crit_on_melee_swing); by the time that hook_safe callback
--             runs, self._is_critical_strike already holds this swing's roll.
--   Ranged -- every ranged weapon rolls its crit in its own action class'
--             client_owner_start_action / _start_shooting (bow, crossbow, handgun,
--             staff, beam, flamethrower, thrown, shotgun, ...), so hooking any one
--             action base covers only a subset. Instead we hook the single shared
--             roll site they all funnel through, ActionUtils.is_critical_strike,
--             and count each call for the local player whose action.kind is NOT a
--             melee kind (melee is already counted via the sweep hook above, so it
--             is excluded here to avoid double counting). Nothing else in this mod
--             hooks is_critical_strike, so no VMF duplicate-hook conflict.
-- ============================================================================

local M = {}

local mod -- set in init()
local ui  -- shared ui_panel, set in init()

local melee_total, melee_total_crits = 0, 0
local ranged_total, ranged_total_crits = 0, 0

function M.reset()
	melee_total, melee_total_crits = 0, 0
	ranged_total, ranged_total_crits = 0, 0
end

local function active()
	return mod:get("show_crit_tracker")
end

local function local_player_unit()
	if not Managers.player then return nil end
	local ok, player = pcall(function () return Managers.player:local_player() end)
	if not ok or not player then return nil end
	return player.player_unit
end

-- One melee swing ATTEMPT, forwarded from the level-15 module's ActionSweep
-- client_owner_start_action hook (self._is_critical_strike is already set).
local function account_melee_swing(sweep_self)
	if sweep_self.owner_unit ~= local_player_unit() then return end
	melee_total = melee_total + 1
	if sweep_self._is_critical_strike then melee_total_crits = melee_total_crits + 1 end
end

-- Melee action kinds that also funnel through ActionUtils.is_critical_strike;
-- these are already counted by the sweep hook, so the is_critical_strike hook
-- skips them (leaving only genuine ranged rolls).
local MELEE_KINDS = {
	sweep = true,
	charged_sweep = true,
	shield_slam = true,
	push_stagger = true,
}

-- One ranged shot ATTEMPT (crit roll), from the ActionUtils.is_critical_strike hook.
local function account_ranged_roll(unit, action, is_crit)
	if unit ~= local_player_unit() then return end
	if type(action) == "table" and MELEE_KINDS[action.kind] then return end
	ranged_total = ranged_total + 1
	if is_crit then ranged_total_crits = ranged_total_crits + 1 end
end

function M.wants_display()
	return active()
end

function M.log_state()
end

-- ---------------------------------------------------------------------------
-- Display
-- ---------------------------------------------------------------------------
local VAL_COL = 210
local PANEL_W = 370

local function fmt_rate(crits, attempts)
	if attempts == 0 then return "--" end
	return string.format("%.1f%% (%d/%d)", (crits / attempts) * 100, crits, attempts)
end

function M.draw(gui)
	local FONT_SIZE = ui.FONT_SIZE

	local x, top, row_y, collapsed, title_visible =
		ui.frame(gui, PANEL_W, 2, "crit_pos_x", "crit_pos_y", 0.03, 0.84, "crit", M.reset)
	if not x then return end

	if title_visible then
		ui.text_bold(gui, "Crit Rate:", x, row_y(0), FONT_SIZE, ui.yellow)
	end
	if collapsed then return end

	ui.text(gui, "Melee", x, row_y(1), FONT_SIZE, ui.white)
	ui.text(gui, fmt_rate(melee_total_crits, melee_total), x + VAL_COL, row_y(1), FONT_SIZE, ui.white)

	ui.text(gui, "Ranged", x, row_y(2), FONT_SIZE, ui.white)
	ui.text(gui, fmt_rate(ranged_total_crits, ranged_total), x + VAL_COL, row_y(2), FONT_SIZE, ui.white)
end

function M.init(owner_mod, ui_panel)
	mod = owner_mod
	ui = ui_panel

	-- Melee: forwarded from the level-15 module's ActionSweep
	-- client_owner_start_action hook (same duplicate-hook reason).
	mod._crit_on_melee_swing = function (sweep_self)
		pcall(account_melee_swing, sweep_self)
	end

	-- Ranged: hook the single shared crit-roll site every ranged action funnels
	-- through. Full hook (not hook_safe) so we can read the roll result; melee
	-- kinds are excluded inside account_ranged_roll (counted via the sweep hook).
	if rawget(_G, "ActionUtils") and ActionUtils.is_critical_strike then
		mod:hook(ActionUtils, "is_critical_strike", function (func, unit, action, t, overrides)
			local is_crit = func(unit, action, t, overrides)
			pcall(account_ranged_roll, unit, action, is_crit)
			return is_crit
		end)
	end
end

return M
