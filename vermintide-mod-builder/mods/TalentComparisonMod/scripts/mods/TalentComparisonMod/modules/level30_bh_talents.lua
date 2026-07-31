-- level30_bh_talents.lua
-- ============================================================================
-- Talent group: Level 30 Bounty Hunter (wh_bountyhunter) -- career-skill
-- (Locked and Loaded) cooldown-refund comparison, PER ULT CYCLE.
--
-- BH's level-30 row includes two talents that shave time off the Locked and
-- Loaded cooldown. This panel reports, per ult cycle and just like Mercenary's
-- Ready for Action, how much each talent refunds -- measured for BOTH regardless
-- of which one is equipped (the mod's core "value of the talent you didn't take"
-- idea). Two figures per talent:
--
--   * Per ult -- the AVERAGE nominal cooldown-seconds each talent removed from the
--     cooldown per ult cycle (total seconds removed / number of simulated cycles).
--   * Last / Avg -- the talent's SHARE of the ult bar it removed, discounting the
--     cooldown combat knocked off on its own: removed / (base - combat), which
--     equals removed / (removed + passive) since base = removed + combat + passive.
--     E.g. a 42s Double Shotted proc on a 70s ult that combat also shaved 15s reads
--     42/(70-15) = 42/55 = 76%. Because the denominator is removed + passive and
--     passive >= 0, this is provably <= 100%, so a big proc can no longer clamp to a
--     bogus 100% the way the old removed / real_elapsed share did (that one mixed
--     cooldown-seconds with real wall-clock seconds). Last cycle + running average.
--   * Procs -- cumulative count of every real qualifying proc of that talent this
--     run (a ranged crit for Just Reward, a RANGED_ABILITY headshot volley for Double
--     Shotted), whether or not the simulated cooldown was charging at the time. This
--     counts blessed-shot / on-melee-kill-refresh procs that fire faster than the
--     ult's own recharge -- they were previously dropped because the count was gated
--     on the simulated cooldown being mid-charge.
--
--   Just Reward (victor_bountyhunter_activated_ability_passive_cooldown_reduction)
--     -- a RANGED critical hit reduces the cooldown by max_cooldown * 0.2 (14s at
--     the 70s base), at most once every 10s. Source: buff_func
--     victor_bountyhunter_reduce_activated_ability_cooldown_on_passive_crit
--     (on_critical_hit; skipped when attack_type is light_attack/heavy_attack, i.e.
--     melee) with a t+cooldown internal lockout (10s vanilla, 4.5s under TB v37 --
--     jr_lock()), calling reduce_activated_ability_cooldown_percent(0.2).
--
--   Double Shotted (victor_bountyhunter_activated_ability_railgun)
--     -- a headshot (head/neck) with the sidearm special (weapon buff_type
--     "RANGED_ABILITY") reduces the cooldown by max_cooldown * 0.6 (42s), once per
--     volley. TOURNEY BALANCE increases this to 0.8 (56s) -- ds_mult(). Source: buff_func
--     victor_bounty_hunter_reduce_activated_ability_cooldown_railgun
--     (on_hit; can_trigger re-armed when target_number<=1) adds the delayed buff
--     victor_bountyhunter_activated_ability_railgun_delayed_add (max_stacks=1,
--     multiplier=0.6, removed 0.25s later -> reduce_activated_ability_cooldown_percent(0.6)).
--     The max_stacks=1 on the delayed buff is what makes "even though two bullets
--     are shot, this can only apply once" true, so a ~0.25s lockout collapses the
--     two-bullet volley into one credit.
--
-- EQUIP-INDEPENDENT ESTIMATE (why this does NOT read the real ult cooldown for the
-- math). If we clamped reductions against the real remaining cooldown and divided
-- by the real recharge time, the numbers would depend on which talent is actually
-- equipped: an equipped Double Shotted shrinks the real cooldown that Just Reward's
-- estimate is then measured against, and vice-versa. Instead each talent runs its
-- OWN SIMULATED cooldown, so both read the same value whether or not either is
-- equipped:
--   * base + combat: every frame the simulated cooldown decays by the passive
--     regen (dt * cooldown_regen) plus the run's real COMBAT reduction rate --
--     derived from the real timeline (so it captures BOTH cooldown-on-hit AND
--     cooldown-on-damage-taken exactly, no hardcoded per-career values) but with
--     the equipped L30 talent's big INSTANT drops stripped out (any single-frame
--     reduction above SPIKE seconds is a talent/potion proc, not combat, so it is
--     excluded). Thus the base+combat rate is the same regardless of the equipped
--     L30 talent.
--   * talent procs: each talent's own qualifying proc reduces ONLY that talent's
--     simulated cooldown by min(nominal, remaining_sim) and banks the removed
--     seconds. A proc while that talent's simulated ult is already ready removes 0
--     (matches the game clamp).
-- A talent's simulated cycle starts when the player really activates the ult AND
-- that talent's simulated ult is ready (a talent whose hypothetical ult is still
-- charging can't be recast, so it ignores that activation); it finalizes when the
-- simulated cooldown reaches 0. Host-most-accurate (calculate_damage resolves
-- server-side); the local player's own cooldown is authoritative on clients too.
--
-- Accuracy note: the combat rate is only observed while the REAL ult is on cooldown
-- (the only time the real timeline moves). If you HOLD a ready ult while a slower
-- talent's simulated ult would still be charging, that stretch contributes only
-- passive regen (combat unseen), so a slower talent's recharge can read slightly
-- long. Prompt recasts keep the combat signal flowing and minimise this.
--
-- No own hooks: each local-player hit is forwarded from the level-15 module's
-- single DamageUtils.calculate_damage hook via mod._l30_bh_on_hit(ctx); duplicate
-- calculate_damage calls (prediction/application/torso) are collapsed with the
-- shared mod._l15_melee_credit dedupe (dual-wield/ranged-safe), same as the other
-- forwards.
-- ============================================================================

local M = {}

local mod -- set in init()
local ui  -- shared ui_panel, set in init()

local DBG = false
local function dlog(fmt, ...)
	if DBG and mod then
		local ok, s = pcall(string.format, "[TCbh30] " .. fmt, ...)
		if not ok then s = "[TCbh30] (log format error) " .. fmt end
		mod:echo((s:gsub("%%", "%%%%")))
	end
end

local BH_CAREER_NAME = "wh_bountyhunter"

-- Tourney Balance detection (same list/logic as the level-15 / L20 / THP panels).
local TB_MOD_IDS = { "TourneyBalance", "TourneyBalanceTesting", "Tourney Balance Testing" }
local function tb_mod_active()
	for _, id in ipairs(TB_MOD_IDS) do
		local ok, m = pcall(get_mod, id)
		if ok and m then
			local ok2, enabled = pcall(function () return m:is_enabled() end)
			if not ok2 or enabled == true then return true end
		end
	end
	return false
end

local JR_MULT   = 0.2   -- Just Reward: reduce_activated_ability_cooldown_percent(0.2) (unchanged in TB)
local JR_LOCK    = 10   -- Just Reward internal cooldown, seconds (vanilla)
local JR_LOCK_TB = 4.5  -- TB v37 shortens the lockout to 4.5s
local function jr_lock() return tb_mod_active() and JR_LOCK_TB or JR_LOCK end
-- Double Shotted CDR-on-headshot: 60% base, 80% under Tourney Balance (changelog).
local function ds_mult() return tb_mod_active() and 0.8 or 0.6 end
local DS_LOCK   = 0.25  -- collapse a two-bullet volley (delayed buff max_stacks=1, 0.25s)

-- Activation is detected as a jump UP in the real cooldown from a ready-ish state.
local READY_EPS    = 1.0
local ACTIVATE_EPS = 5.0

-- A single-frame real-cooldown drop larger than this is an INSTANT talent/potion
-- proc (Just Reward removes ~14s, Double Shotted ~42s), not the smooth per-frame
-- combat/passive decay -- exclude it from the combat rate so the base+combat rate
-- is independent of the equipped L30 talent.
local SPIKE = 8

-- ---------------------------------------------------------------------------
-- Running records, per talent: seconds removed and % share of the estimated
-- recharge time, accumulated over completed (simulated) ult cycles.
-- ---------------------------------------------------------------------------
local jr_rec, ds_rec

-- Per-talent simulated-cooldown state:
--   charging = its hypothetical ult is on cooldown
--   cd       = simulated remaining cooldown (seconds)
--   el       = real seconds elapsed since this simulated cycle began
--   removed  = seconds this talent has shaved off its own simulated cooldown
--   base     = the max_cooldown captured when this cycle started (for nominal)
--   passive_secs = cooldown-seconds covered by passive regen this cycle (share denom)
local jr_st, ds_st

-- Real-cooldown sample from the previous frame (activation + combat-rate detection).
local prev_cd

-- Just Reward / Double Shotted proc lockouts (game-time based).
local jr_next_t, ds_next_t

local function new_rec()
	return { last_pct = nil, sum_pct = 0, sum_secs = 0, procs = 0, count = 0 }
end

local function new_state()
	return { charging = false, cd = 0, el = 0, removed = 0, base = 0, passive_secs = 0 }
end

function M.reset()
	jr_rec = new_rec()
	ds_rec = new_rec()
	jr_st = new_state()
	ds_st = new_state()
	prev_cd = nil
	jr_next_t = 0
	ds_next_t = 0
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

local function is_bounty_hunter()
	local unit = local_player_unit()
	if not unit or not Unit.alive(unit) then return false end
	local ce = career_ext(unit)
	return ce ~= nil and career_name(ce) == BH_CAREER_NAME
end

local function active()
	return is_bounty_hunter()
end

local function game_time()
	local ok, t = pcall(function () return Managers.time:time("game") end)
	return ok and t or 0
end

-- Live (remaining_cooldown, max_cooldown) for Locked and Loaded (ability 1).
local function ability_cooldown()
	local unit = local_player_unit()
	local ce = career_ext(unit)
	if not ce then return nil, nil end
	local ok, cd, maxcd = pcall(function () return ce:current_ability_cooldown(1) end)
	if not ok or type(cd) ~= "number" or type(maxcd) ~= "number" then return nil, nil end
	return cd, maxcd
end

-- The weapon buff_type for a hit's damage_source, exactly as the game derives it
-- for the on_hit proc (DamageUtils.get_item_buff_type). Double Shotted gates on
-- this being "RANGED_ABILITY" (the sidearm special).
local function hit_buff_type(damage_source)
	if not damage_source then return nil end
	local du = rawget(_G, "DamageUtils")
	if not du or not du.get_item_buff_type then return nil end
	local ok, bt = pcall(du.get_item_buff_type, damage_source)
	return ok and bt or nil
end

-- ---------------------------------------------------------------------------
-- Simulated-cooldown mechanics
-- ---------------------------------------------------------------------------
local function finalize_state(st, rec)
	local el = st.el
	if el and el > 0 then
		-- The talent's share of the ult bar it removed, discounting the cooldown
		-- combat knocked off on its own: removed / (base - combat) = removed /
		-- (removed + passive). Because the denominator is removed + passive and
		-- passive >= 0, this is provably <= 100% (a big proc can never clamp).
		-- E.g. 42s removed on a 70s ult that combat also shaved 15s -> 42/55 = 76%.
		local denom = st.removed + (st.passive_secs or 0)
		local pct = 0
		if denom > 0 then
			pct = math.clamp((st.removed / denom) * 100, 0, 100)
		end
		rec.last_pct = pct
		rec.sum_pct = rec.sum_pct + pct
		rec.sum_secs = rec.sum_secs + st.removed
		rec.count = rec.count + 1
		dlog("FINALIZE removed=%.1f passive=%.1f -> %.1f%%", st.removed, st.passive_secs or 0, pct)
	end
	st.charging = false
	st.cd = 0
end

local function start_state(st, maxcd)
	st.charging = true
	st.cd = maxcd
	st.el = 0
	st.removed = 0
	st.base = maxcd
	st.passive_secs = 0
end

-- Decay a charging talent's simulated cooldown by this frame's passive + combat.
-- Passive is banked separately (it's the share-metric denominator alongside removed).
local function step_state(st, rec, dt, passive, combat)
	if not st.charging then return end
	st.cd = st.cd - (passive + combat)
	st.el = st.el + dt
	st.passive_secs = (st.passive_secs or 0) + passive
	if st.cd <= 0 then
		st.cd = 0
		finalize_state(st, rec)
	end
end

-- A talent proc removes min(nominal, remaining) from ITS OWN simulated cooldown.
-- The proc COUNT is incremented by the caller (on_hit) for every real qualifying
-- proc -- including ones that fire while this talent's simulated ult is already
-- ready (idle) and therefore remove 0 seconds. Only the removed-seconds bookkeeping
-- is gated on the sim cooldown being charging.
local function proc_state(st, rec, mult)
	if not st.charging then return 0 end
	local removed = math.min(st.base * mult, st.cd)
	if removed <= 0 then return 0 end
	st.cd = st.cd - removed
	st.removed = st.removed + removed
	if st.cd <= 0 then
		st.cd = 0
		finalize_state(st, rec)
	end
	return removed
end

-- ---------------------------------------------------------------------------
-- Per-hit crediting, forwarded from the level-15 calculate_damage hook. Applies
-- each talent's qualifying proc to its own simulated cooldown.
-- ctx = { func, target_unit, attacker_unit, hit_zone_name, is_critical_strike,
--         damage_profile, target_index, damage_source, final, ... }
-- ---------------------------------------------------------------------------
local function on_hit(ctx)
	if not active() then return end

	local dp = ctx.damage_profile
	if not dp or dp.is_dot then return end

	-- One credit per genuine hit: collapse the 2-3 calculate_damage calls the game
	-- runs per real hit (prediction / application / torso recompute). Shared with
	-- every other forward so the answer is consistent (cached on ctx).
	if mod._l15_melee_credit and not mod._l15_melee_credit(ctx) then return end

	local weakspot = ctx.hit_zone_name == "head" or ctx.hit_zone_name == "neck"
	local is_melee = dp.charge_value == "light_attack" or dp.charge_value == "heavy_attack"
	local t = game_time()

	-- Just Reward: any RANGED critical hit, at most once per lockout (10s vanilla,
	-- 4.5s under TB v37). Count EVERY real qualifying proc (blessed-shot / on-melee-
	-- kill refreshes can fire these faster than the ult's own recharge); proc_state
	-- only removes time when the sim ult is actually charging.
	if ctx.is_critical_strike and not is_melee and t >= jr_next_t then
		jr_next_t = t + jr_lock()
		jr_rec.procs = jr_rec.procs + 1
		local removed = proc_state(jr_st, jr_rec, JR_MULT)
		dlog("JR crit removed=%.1f cd=%.1f", removed, jr_st.cd)
	end

	-- Double Shotted: a headshot with the sidearm special (buff_type RANGED_ABILITY),
	-- once per volley (the delayed buff's max_stacks=1 collapses the two bullets).
	if weakspot and t >= ds_next_t and hit_buff_type(ctx.damage_source) == "RANGED_ABILITY" then
		ds_next_t = t + DS_LOCK
		ds_rec.procs = ds_rec.procs + 1
		local removed = proc_state(ds_st, ds_rec, ds_mult())
		dlog("DS headshot removed=%.1f cd=%.1f", removed, ds_st.cd)
	end
end

-- ---------------------------------------------------------------------------
-- Update: detect real ult activations (to start simulated cycles) and drive each
-- talent's simulated cooldown by passive + combat every frame.
-- ---------------------------------------------------------------------------
function M.update(dt)
	if not active() then
		prev_cd = nil
		return
	end

	local cd, maxcd = ability_cooldown()
	if cd == nil then
		return
	end
	if not maxcd or maxcd <= 0 then maxcd = cd end

	-- Passive decay multiplier, mirroring CareerExtension.update.
	local regen = 1
	local be = buff_ext(local_player_unit())
	if be then
		local rok, r = pcall(function () return be:apply_buffs_to_value(1, "cooldown_regen") end)
		if rok and type(r) == "number" then regen = r end
	end

	if prev_cd ~= nil then
		if prev_cd <= READY_EPS and cd > ACTIVATE_EPS then
			-- Real activation: start a simulated cycle for any talent whose own
			-- hypothetical ult is currently ready (idle). A talent still charging
			-- could not have been recast in its own world, so it ignores this.
			if not jr_st.charging then start_state(jr_st, maxcd) end
			if not ds_st.charging then start_state(ds_st, maxcd) end
			dlog("ACTIVATE maxcd=%.1f", maxcd)
		else
			-- Per-frame base+combat decay, derived from the real timeline with the
			-- equipped L30 talent's instant drops stripped out (see SPIKE).
			local passive = dt * regen
			local raw_combat = (prev_cd - cd) - passive
			local combat = raw_combat
			if combat > SPIKE then combat = 0 end
			if combat < 0 then combat = 0 end

			step_state(jr_st, jr_rec, dt, passive, combat)
			step_state(ds_st, ds_rec, dt, passive, combat)
		end
	end

	prev_cd = cd
end

-- ---------------------------------------------------------------------------
-- Display
-- ---------------------------------------------------------------------------
local C_SECS  = 210  -- "Per ult": avg nominal cooldown-seconds removed / ult
local C_LAST  = 290  -- last cycle % share of the (combat-discounted) recharge
local C_AVG   = 365  -- running-average % share
local C_PROCS = 435  -- cumulative effective proc counter
local PANEL_W = 490

local function fmt_secs(v)
	if v == nil then return "--" end
	return string.format("%.1fs", v)
end

local function fmt_pct(v)
	if v == nil then return "--" end
	return string.format("%.1f%%", v)
end

local function fmt_procs(v)
	return string.format("%.0f", v or 0)
end

local function avg_secs(rec)  -- avg NOMINAL cooldown removed per ult ("Per ult")
	if rec.count == 0 then return nil end
	return rec.sum_secs / rec.count
end

local function avg_pct(rec)  -- avg % share of the (combat-discounted) recharge
	if rec.count == 0 then return nil end
	return rec.sum_pct / rec.count
end

function M.wants_display()
	return active()
end

function M.log_state()
	if not DBG then return end
	dlog("SNAP JR per_ult=%s last=%s avg=%s n=%d procs=%d | DS per_ult=%s last=%s avg=%s n=%d procs=%d",
		fmt_secs(avg_secs(jr_rec)), fmt_pct(jr_rec.last_pct), fmt_pct(avg_pct(jr_rec)), jr_rec.count, jr_rec.procs,
		fmt_secs(avg_secs(ds_rec)), fmt_pct(ds_rec.last_pct), fmt_pct(avg_pct(ds_rec)), ds_rec.count, ds_rec.procs)
end

function M.reset_self()
	if M.log_state then pcall(M.log_state) end
	M.reset()
end

function M.draw(gui)
	if not active() then return end

	local FONT_SIZE = ui.FONT_SIZE
	local small = FONT_SIZE - 6

	local x, top, row_y, collapsed, title_visible =
		ui.frame(gui, PANEL_W, 4, "l30bh_pos_x", "l30bh_pos_y", 0.03, 0.5, "l30bh", M.reset_self)
	if not x then return end

	if title_visible then
		ui.text_bold(gui, "Bounty Hunter Lvl 30:", x, row_y(0), FONT_SIZE, ui.yellow)
	end
	if collapsed then return end

	-- Column headers, center-aligned over their column.
	ui.text_centered(gui, "Per ult", x + C_SECS,  row_y(1), small, ui.grey)
	ui.text_centered(gui, "Last",    x + C_LAST,  row_y(1), small, ui.grey)
	ui.text_centered(gui, "Avg",     x + C_AVG,   row_y(1), small, ui.grey)
	ui.text_centered(gui, "Procs",   x + C_PROCS, row_y(1), small, ui.grey)

	local function row(r, name, rec)
		local y = row_y(r)
		ui.text(gui, name, x, y, FONT_SIZE, ui.white)
		ui.text_centered(gui, fmt_secs(avg_secs(rec)), x + C_SECS,  y, FONT_SIZE, ui.white)
		ui.text_centered(gui, fmt_pct(rec.last_pct),   x + C_LAST,  y, FONT_SIZE, ui.white)
		ui.text_centered(gui, fmt_pct(avg_pct(rec)),   x + C_AVG,   y, FONT_SIZE, ui.white)
		ui.text_centered(gui, fmt_procs(rec.procs),    x + C_PROCS, y, FONT_SIZE, ui.white)
	end

	row(2, "Just Reward", jr_rec)
	row(3, "Double Shotted", ds_rec)

	if jr_st.charging or ds_st.charging then
		-- Time left until this batch finalizes ~= the slower talent's remaining
		-- simulated cooldown (cd is in cooldown-seconds; at ~1x passive regen and no
		-- further combat that is roughly wall-seconds, so it reads as an estimate).
		local remain = math.max(jr_st.charging and jr_st.cd or 0, ds_st.charging and ds_st.cd or 0)
		ui.text(gui, string.format("calculating... ~%.0fs", remain), x + PANEL_W - 260, row_y(0), small, ui.grey)
	end

	ui.text(gui, "Estimated (how much refund per ult)", x, row_y(4), small, ui.grey)
end

function M.init(owner_mod, ui_panel)
	mod = owner_mod
	ui = ui_panel
	-- No own hooks: per-hit crediting is forwarded from the level-15 module's
	-- single DamageUtils.calculate_damage hook (VMF ignores a duplicate hook on the
	-- same func from this mod).
	mod._l30_bh_on_hit = function (ctx)
		pcall(on_hit, ctx)
	end
end

return M
