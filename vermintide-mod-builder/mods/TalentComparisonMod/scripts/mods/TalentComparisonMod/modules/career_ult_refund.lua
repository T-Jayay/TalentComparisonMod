-- career_ult_refund.lua
-- ============================================================================
-- Talent group: Career-skill (ultimate) cooldown refund tracking.
--
-- Two related metrics, both measured per completed ult cycle (from the moment the
-- ult is used until the career skill is ready again), for the LOCAL player:
--
--   Combat Ult Refund (ALL careers): how much faster the ult recharged thanks to
--     COMBAT cooldown reduction -- the "cooldown on hit" and "cooldown on damage
--     taken" per-career values (see the appendix table in CLAUDE.md). Reported as
--     combat_seconds / base_cooldown, for the last ult and as a running average.
--
--   Ready for Action (Mercenary + that talent ONLY): RFA's own share of the
--     ACTUAL, already-combat-shortened recharge time -- rfa_seconds /
--     actual_recharge_time, where rfa_seconds = base_cooldown * 0.2 is the
--     talent's fixed instant discount (activated_cooldown -0.2 multiplier
--     applied at use, so the cooldown starts at base * 0.8). E.g. a 90s ult
--     that actually came back in 36s thanks to combat still owes 18s of that
--     to RFA alone -- 18 / 36 = 50% of the real wait.
--
-- HOW IT IS MEASURED (no per-career buff knowledge needed)
--   The career skill cooldown decays passively at dt * cooldown_regen per frame
--   (CareerExtension.update -> reduce_activated_ability_cooldown(dt * mult)).
--   Combat reductions are EXTRA reductions applied on top via buff procs. So each
--   frame we sample current_ability_cooldown(1); the reduction beyond the expected
--   passive dt * cooldown_regen is combat-driven and accumulated. When the cooldown
--   reaches 0 the cycle is finalized into the running records.
--
--   base_cooldown is the ability's max_cooldown (e.g. 90 for Mercenary). Ready for
--   Action does NOT change max_cooldown; it only lowers the starting cooldown at
--   activation, so max_cooldown is the correct "full wait" denominator.
--
-- NOTE: any non-passive reduction is attributed to "combat" -- so a cooldown-reset
--   effect (e.g. Concentration Potion) or kill-based cooldown talents also count.
--   Most accurate as host, but the local player's own cooldown is authoritative
--   client-side too, so this reads correctly on clients as well.
-- ============================================================================

local M = {}

local mod   -- set in init()
local ui    -- shared ui_panel, set in init()

local DBG = false
local function dlog(fmt, ...)
	if DBG and mod then
		local ok, s = pcall(string.format, "[TCMult] " .. fmt, ...)
		if not ok then s = "[TCMult] (log format error) " .. fmt end
		mod:echo((s:gsub("%%", "%%%%")))
	end
end

local MERC_CAREER_NAME   = "es_mercenary"
local TALENT_READY_FOR_ACTION = "markus_mercenary_activated_ability_cooldown_no_heal"

-- Activation is detected as a jump UP in cooldown from a ready-ish state. These
-- thresholds keep normal per-frame decay and small mid-cycle buff jitter from
-- being mistaken for a fresh ult use.
local READY_EPS   = 1.0    -- cooldown at/below this counts as "ready" for detection
local ACTIVATE_EPS = 5.0   -- jump above this from ready => a new activation

-- ---------------------------------------------------------------------------
-- Running records. Each holds the last completed cycle's % and a sum/count for
-- the average. combat = all careers; total = Mercenary Ready for Action only.
-- ---------------------------------------------------------------------------
local combat_rec, total_rec

-- Per-cycle accumulators.
local prev_cd          -- previous frame's cooldown sample (nil until first sample)
local cycle_active     -- currently mid-cooldown after an activation
local cycle_base       -- max_cooldown captured at activation (denominator)
local cycle_elapsed    -- real seconds since activation
local cycle_combat     -- combat-attributed seconds this cycle

local function new_rec()
	return { last = nil, sum = 0, count = 0 }
end

function M.reset()
	combat_rec = new_rec()
	total_rec = new_rec()
	prev_cd = nil
	cycle_active = false
	cycle_base = 0
	cycle_elapsed = 0
	cycle_combat = 0
end

M.reset()

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local function local_player_unit()
	if not Managers.player then return nil end
	local ok, player = pcall(function () return Managers.player:local_player() end)
	if not ok or not player then return nil end
	return player.player_unit
end

local function career_ext(unit)
	return unit and ScriptUnit.has_extension(unit, "career_system") or nil
end

local function buff_ext(unit)
	return unit and ScriptUnit.has_extension(unit, "buff_system") or nil
end

local function career_name(ce)
	local ok, name = pcall(function () return ce:career_name() end)
	return ok and name or nil
end

local function is_merc_rfa(unit, ce)
	if career_name(ce) ~= MERC_CAREER_NAME then return false end
	local te = ScriptUnit.has_extension(unit, "talent_system")
	if not te then return false end
	local ok, res = pcall(function () return te:has_talent(TALENT_READY_FOR_ACTION) end)
	return ok and res or false
end

local function active()
	return true
end

-- ---------------------------------------------------------------------------
-- Finalize a completed cycle into the running records.
-- ---------------------------------------------------------------------------
local function finalize(unit, ce)
	local base = cycle_base
	if not base or base <= 0 then return end

	-- combat_seconds / base : the fraction of the full wait removed by combat.
	local combat_pct = math.clamp(cycle_combat / base, 0, 1) * 100
	combat_rec.last = combat_pct
	combat_rec.sum = combat_rec.sum + combat_pct
	combat_rec.count = combat_rec.count + 1

	-- Ready for Action's own share of the ACTUAL (post-combat) recharge time.
	-- RFA is a fixed instant -20% of base_cooldown (the cooldown starts at
	-- base * 0.8), applied before any combat reduction on top. Expressed as a
	-- fraction of how long the ult actually took to come back up, i.e. how much
	-- of the real, already-combat-shortened wait RFA itself is responsible for.
	if is_merc_rfa(unit, ce) then
		local rfa_seconds = base * 0.2
		-- RFA is a fixed instant discount applied at use, so it can never account
		-- for MORE than the whole actual recharge time. When combat shortens the
		-- wait below rfa_seconds the raw ratio would exceed 1 (e.g. 240%), which is
		-- nonsensical -- clamp the share to 100%.
		local total_pct = cycle_elapsed > 0 and math.clamp((rfa_seconds / cycle_elapsed) * 100, 0, 100) or 0
		total_rec.last = total_pct
		total_rec.sum = total_rec.sum + total_pct
		total_rec.count = total_rec.count + 1
		dlog("FINALIZE base=%.1f elapsed=%.1f combat=%.1f rfa_s=%.1f -> rfa=%.1f%% combat=%.1f%%",
			base, cycle_elapsed, cycle_combat, rfa_seconds, total_pct, combat_pct)
	else
		dlog("FINALIZE base=%.1f elapsed=%.1f combat=%.1f -> combat=%.1f%%",
			base, cycle_elapsed, cycle_combat, combat_pct)
	end
end

-- ---------------------------------------------------------------------------
-- Update: sample the cooldown every frame and drive the cycle state machine.
-- ---------------------------------------------------------------------------
function M.update(dt)
	if not active() then
		prev_cd = nil
		cycle_active = false
		return
	end

	local unit = local_player_unit()
	if not unit or not Unit.alive(unit) then
		prev_cd = nil
		cycle_active = false
		return
	end
	local ce = career_ext(unit)
	if not ce then
		prev_cd = nil
		cycle_active = false
		return
	end

	local ok, cd, maxcd = pcall(function ()
		return ce:current_ability_cooldown(1)
	end)
	if not ok or type(cd) ~= "number" then
		return
	end

	-- Passive decay multiplier, mirroring CareerExtension.update.
	local be = buff_ext(unit)
	local regen = 1
	if be then
		local rok, r = pcall(function () return be:apply_buffs_to_value(1, "cooldown_regen") end)
		if rok and type(r) == "number" then regen = r end
	end

	if prev_cd ~= nil then
		if prev_cd <= READY_EPS and cd > ACTIVATE_EPS then
			-- Fresh activation: start a new cycle.
			cycle_active = true
			cycle_base = (type(maxcd) == "number" and maxcd > 0) and maxcd or cd
			cycle_elapsed = 0
			cycle_combat = 0
			dlog("ACTIVATE cd=%.1f base=%.1f", cd, cycle_base)
		elseif cycle_active then
			local delta = prev_cd - cd
			if delta < -0.5 then
				-- Cooldown jumped UP mid-cycle (an increase buff, or a re-cast we
				-- did not classify as a fresh activation). Restart the baseline so
				-- we do not credit a bogus cycle.
				cycle_base = (type(maxcd) == "number" and maxcd > 0) and maxcd or cd
				cycle_elapsed = 0
				cycle_combat = 0
			else
				if delta < 0 then delta = 0 end
				cycle_elapsed = cycle_elapsed + dt
				local passive = dt * regen
				local combat = delta - passive
				if combat > 0 then
					cycle_combat = cycle_combat + combat
				end
				if cd <= 0 then
					finalize(unit, ce)
					cycle_active = false
				end
			end
		end
	end

	prev_cd = cd
end

-- ---------------------------------------------------------------------------
-- Display
-- ---------------------------------------------------------------------------
local VAL_COL = 200
local PANEL_W = 360

local function fmt_pct(v)
	if v == nil then return "--" end
	return string.format("%.1f%%", v)
end

local function avg(rec)
	if rec.count == 0 then return nil end
	return rec.sum / rec.count
end

function M.wants_display()
	return active()
end

function M.log_state()
	if not DBG then return end
	dlog("SNAP combat last=%s avg=%s (n=%d) | total last=%s avg=%s (n=%d)",
		fmt_pct(combat_rec.last), fmt_pct(avg(combat_rec)), combat_rec.count,
		fmt_pct(total_rec.last), fmt_pct(avg(total_rec)), total_rec.count)
end

function M.reset_self()
	if M.log_state then pcall(M.log_state) end
	M.reset()
end

-- Draw one refund panel (title + Last + Average + note).
local function draw_panel(gui, rec, title, note, pos_x, pos_y, default_yfrac, drag_key)
	local FONT_SIZE = ui.FONT_SIZE
	local small = FONT_SIZE - 6

	local x, top, row_y, collapsed, title_visible = ui.frame(gui, PANEL_W, 3, pos_x, pos_y, 0.03, default_yfrac, drag_key, M.reset_self)
	if not x then return end

	if title_visible then
		ui.text_bold(gui, title, x, row_y(0), FONT_SIZE, ui.yellow)
	end
	if collapsed then return end

	ui.text(gui, "Last ult", x, row_y(1), FONT_SIZE, ui.white)
	ui.text(gui, fmt_pct(rec.last), x + VAL_COL, row_y(1), FONT_SIZE, ui.white)

	ui.text(gui, string.format("Average (%d)", rec.count), x, row_y(2), FONT_SIZE, ui.white)
	ui.text(gui, fmt_pct(avg(rec)), x + VAL_COL, row_y(2), FONT_SIZE, ui.white)

	ui.text(gui, note, x, row_y(3), small, ui.grey)
end

-- Combat Ult Refund panel (every career). Lives on the "Other Stats" tab.
function M.draw_combat(gui)
	draw_panel(gui, combat_rec, "Combat Ult Refund:",
		"% of base cooldown saved by combat.",
		"ultc_pos_x", "ultc_pos_y", 0.5, "ultc")
end

-- Ready for Action is only meaningful for Mercenary with that L30 talent, so its
-- panel (and the Lvl 30 tab entry that hosts it) only appears then.
function M.rfa_wants_display()
	local unit = local_player_unit()
	local ce = unit and career_ext(unit)
	return (ce and is_merc_rfa(unit, ce)) == true
end

-- Ready for Action panel: a Mercenary L30 talent, so it is drawn under the
-- Lvl 30 tab (routed via a draw-only wrapper in the entry file), NOT here.
function M.draw_rfa(gui)
	if not M.rfa_wants_display() then return end
	draw_panel(gui, total_rec, "Ready for Action:",
		"RFA's share of the actual recharge time.",
		"ultm_pos_x", "ultm_pos_y", 0.68, "ultm")
end

function M.init(owner_mod, ui_panel)
	mod = owner_mod
	ui = ui_panel
	-- No hooks: this group measures purely by sampling the career-skill cooldown
	-- each frame in M.update.
end

return M
