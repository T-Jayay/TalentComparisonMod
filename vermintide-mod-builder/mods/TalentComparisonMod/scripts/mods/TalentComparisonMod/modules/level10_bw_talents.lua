-- level10_bw_talents.lua
-- ============================================================================
-- Talent group: Level-10 Battle Wizard (bw_adept). CAREER-SPECIFIC, like the
-- level-10 WHC / Mercenary and level-20 Mercenary panels -- the panel is hidden and
-- NONE of the simulation runs unless the LOCAL player is currently playing Battle
-- Wizard (career_name "bw_adept").
--
-- A Battle Wizard picks 2 of these 3 at level 10 (talent_settings_sienna.lua):
--   Volcanic Force  (sienna_adept_power_level_on_full_charge) -- fully charging a
--     spell adds +50% POWER to that attack. `full_charge_boost` (stacking_multiplier
--     0.5) is applied to the action's power_level BEFORE calculate_damage, at the three
--     charged-spell action sites (action_charged_projectile / action_geiser /
--     action_flamethrower, each gated on charge_level >= 1). Because it is a pre-
--     calculate_damage power multiplier it respects armour breakpoints (NOT a flat
--     +50% of damage), so it is valued by re-running the real hit with the attack's
--     original_power_level scaled by 1.5 (or 1/1.5 when equipped, to strip it).
--   Famished Flames (sienna_adept_increased_burn_damage_reduced_non_burn_damage) --
--     burn DoT damage +100% AND all weapon (melee/ranged) damage -15%. (TOURNEY
--     BALANCE: burn +150% and weapon -30% -- ff_burn_factor()/ff_weapon_factor()
--     resolve x2.5 / x0.70 when TB is loaded, x2.0 / x0.85 otherwise.) Both are
--     POST-calculate_damage stat buffs (DamageUtils.apply_buffs_to_damage):
--       * increased_burn_dot_damage (x2.0 / x2.5 TB) applies ONLY when damage_type ==
--         "burninating" (burn DoT ticks).
--       * reduced_non_burn_damage (x0.85 / x0.70 TB) applies ONLY to hits whose damage_source is
--         a weapon with a melee/ranged buff_type (so NOT DoTs, NOT career-skill /
--         explosion damage without a weapon template). This DOES include Sienna's
--         staff direct hits -- they are ranged weapon damage.
--     Since both are applied AFTER calculate_damage, ctx.final is always the pre-FF
--     base for either hit, so the deltas are exact: +base for a burn tick, -0.15*base
--     for a weapon hit -- regardless of whether FF is equipped. Reported as a NET
--     (Burn gain minus Weapon loss) with the split shown beneath.
--   Lingering Flames (sienna_adept_infinite_burn) -- burns last until the enemy dies
--     and no longer stack (max 1 stack), and the single stack ticks TWICE as fast
--     (buff_utils.generate_infinite_burn_variants halves time_between_dot_damages,
--     removes duration, forces max_stacks 1). (TOURNEY BALANCE: the extra tick rate
--     is REMOVED -- the infinite single stack ticks at the NORMAL interval; lf_touch
--     uses x1.0 instead of x0.5 under TB.) It has buffs = {} and works via a
--     has_talent() DoT-template swap, so it cannot be forced by adding a buff. It is
--     SIMULATED: from a unit's first observed burn tick we project one persistent
--     stack ticking at 2x rate until the unit dies, and report (projected LF burn) -
--     (real burn) with overkill removed against the unit's HP. NOTE: the sampled burn
--     tick is the ACTUAL APPLIED value -- when Famished Flames is ALSO equipped its
--     post-calculate_damage +100% doubles every real tick, so LF feeds `final x2` (not
--     the pre-FF ctx.final) into both its vanilla baseline and its 2x-rate projection;
--     both worlds carry the same FF factor and the overkill cap engages against real HP.
--     Because LF trades
--     stacking (up to 3) for a permanent 2x single stack, its value is LEGITIMATELY
--     negative for stack-heavy play and positive for long-lived single targets.
--
-- Reported per talent, like the other damage panels: Total (overkill removed) /
-- Uncapped (raw) / Real Total (kill-aware, shared kill_tracker). Volcanic Force and
-- Famished Flames feed the kill tracker; Lingering Flames is a forward projection
-- with no real per-hit add_damage to calibrate, so its Real Total shows "-".
--
-- EQUIPPED HANDLING (the whole point of a comparison panel):
--   * Volcanic Force equipped -> real charged hits already carry the +50%, so we
--     STRIP it (recompute at 1/1.5) and report the boost already realized.
--   * Famished Flames equipped -> real burn ticks already x2 and real weapon hits
--     already x0.85; the kill-tracker pairs are expressed so the batch's K =
--     real/model calibration reproduces the correct FF / no-FF applied damage in
--     either case (see credit_ff_kill). The damage columns read ctx.final (the pre-FF
--     model), matching every other panel (damage columns are low by K by design).
--   * Lingering Flames equipped -> the observed ticks ARE the infinite world; the
--     vanilla-stacking baseline cannot be reconstructed from them, so the row shows
--     "-" and a note. (Measured only when NOT equipped -- "value of the talent you
--     didn't take", like Deathknell / Riposte / Helborg.)
--
-- WIRING: this module owns ONE non-conflicting hook set -- hook_safe on the three
-- charged-spell actions' client_owner_start_action, to detect a fully-charged cast
-- and arm the Volcanic Force window. All per-hit crediting is forwarded from the
-- level-15 DamageUtils.calculate_damage hook via mod._l10_bw_on_hit(ctx). Melee/ranged
-- dedupe reuses the level-15 per-genuine-hit decision (mod._l15_melee_credit). Burn
-- DoT ticks are credited every tick (no dedupe, like WHC Flense). Most accurate as
-- host (calculate_damage / the DoT server_apply_hit resolve server-side).
-- ============================================================================

local M = {}

local mod   -- set in init()
local ui    -- shared ui_panel, set in init()
local l10bw_kt   -- shared kill-tracker instance (mod._kill_tracker.new(), created in init)
local F          -- unit_filter (mod._filter), set in init

local DBG = false
local function dlog(fmt, ...)
	if DBG and mod then
		local ok, s = pcall(string.format, "[TCM10BW] " .. fmt, ...)
		if not ok then s = "[TCM10BW] (log format error) " .. fmt end
		mod:echo((s:gsub("%%", "%%%%")))
	end
end

local BW_CAREER_NAME = "bw_adept"
-- Talent buff names for has_talent() detection (talent_settings_sienna.lua).
local TALENT_VF = "sienna_adept_power_level_on_full_charge"
local TALENT_FF = "sienna_adept_increased_burn_damage_reduced_non_burn_damage"
local TALENT_LF = "sienna_adept_infinite_burn"

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

-- Talent numbers (buff_tweak_data in talent_settings_sienna.lua).
-- Volcanic Force is unchanged by TB. Famished Flames and Lingering Flames ARE:
--   * Famished Flames (changelog): burn bonus +100% -> +150% (x2 -> x2.5); non-burn
--     penalty -15% -> -30% (x0.85 -> x0.70). Both remain POST-calculate_damage, so the
--     factor stays exact -- only the magnitude changes.
--   * Lingering Flames (changelog): "Additional tick rate removed" -- under TB the
--     infinite single stack ticks at the NORMAL interval (no x2 rate); see lf_touch.
local VF_FACTOR       = 1.5   -- sienna_adept_power_level_on_full_charge.multiplier 0.5 -> x1.5
-- FF factors resolve live per hit so they track whichever mod is loaded.
local function ff_burn_factor()   return tb_mod_active() and 2.5  or 2.0  end
local function ff_weapon_factor() return tb_mod_active() and 0.70 or 0.85 end
-- Volcanic Force window: a fully-charged cast's damage lands over the projectile's
-- flight / the geiser or flamethrower's spray. Armed on each fully-charged cast and
-- refreshed on each boosted hit, so a sustained spray keeps crediting.
local VF_WINDOW = 3.0

-- Base burn tick intervals (buff_templates.lua time_between_dot_damages), keyed by the
-- resolved DamageProfileTemplate so a burn tick can be mapped to its cadence. The
-- Lingering Flames variant halves this. Unknown burn profiles fall back to DEFAULT.
local BURN_INTERVAL_BY_PROFILE_NAME = {
	burning_dot = 0.75,
	beam_burning_dot = 1.0,
	flamethrower_burning_dot = 0.65,
}
local BURN_INTERVAL_DEFAULT = 0.75

local TALENTS10BW = { "volcanic", "famished", "lingering" }
local TALENT10BW_NAMES = {
	volcanic  = "Volcanic Force",
	famished  = "Famished Flames",
	lingering = "Lingering Flames",
}

-- ---------------------------------------------------------------------------
-- Running totals (per unit-category bucket, merged by the filter in draw).
--   vf_cat   : Volcanic Force extra damage      { total, uncap }
--   ffb_cat  : Famished Flames burn GAIN        { total, uncap }
--   ffw_cat  : Famished Flames weapon LOSS      { total, uncap } (positive magnitude)
--   lf_final : Lingering Flames banked extra from finished units { total, uncap }
-- Lingering Flames' LIVE contribution is computed from lf_units at draw time.
-- ---------------------------------------------------------------------------
local vf_cat, ffb_cat, ffw_cat, lf_final
local lf_units   -- unit -> live LF sim state (see lf_touch)
-- DEBUG-ONLY: per-unit observation of the REAL burn ticks, recorded for EVERY burning
-- unit regardless of whether Lingering Flames is equipped. When LF IS equipped these
-- are the actual LF-world burns (single 2x-rate stack until death) -- exactly "the
-- numbers Lingering produces when the talent is on" -- so we can validate the sim
-- against reality. Never feeds display; logged per unit at death and in log_state.
local lf_dbg     -- unit -> { ticks, real_sum, hp0, equipped, profile, base_iv, first_t, last_t, cat }

local function new_pair() return { total = 0, uncap = 0 } end
local function fresh_cat()
	return { elite = new_pair(), special = new_pair(), mon = new_pair(), trash = new_pair() }
end

vf_cat  = fresh_cat()
ffb_cat = fresh_cat()
ffw_cat = fresh_cat()
lf_final = fresh_cat()
lf_units = {}
lf_dbg = {}

function M.reset()
	if l10bw_kt then l10bw_kt:reset() end
	vf_cat  = fresh_cat()
	ffb_cat = fresh_cat()
	ffw_cat = fresh_cat()
	lf_final = fresh_cat()
	lf_units = {}
	lf_dbg = {}
end

-- Kill-column record for `talent`, or an all-zero default before its first credit.
local ZERO_KILLS = { n = 0, saved_sum = 0, saved_n = 0, hpk_sum = 0, hpk_n = 0, real_total = 0 }
local function kget(talent)
	return (l10bw_kt and l10bw_kt:get(talent)) or ZERO_KILLS
end

-- Merge a per-category { total, uncap } accumulator over the filter-enabled categories.
local CATS = { "elite", "special", "mon", "trash" }
local function merge_pair(catset)
	local total, uncap = 0, 0
	for _, c in ipairs(CATS) do
		if F.enabled(c) then
			total = total + catset[c].total
			uncap = uncap + catset[c].uncap
		end
	end
	return total, uncap
end

-- ---------------------------------------------------------------------------
-- Helpers (mirror the other modules).
-- ---------------------------------------------------------------------------
local function local_player_unit()
	if not Managers.player then return nil end
	local ok, player = pcall(function () return Managers.player:local_player() end)
	if not ok or not player then return nil end
	return player.player_unit
end

local function game_time()
	local ok, t = pcall(function () return Managers.time:time("game") end)
	if ok and t then return t end
	return 0
end

local function unit_current_health(unit)
	local he = ScriptUnit.has_extension(unit, "health_system")
	if not he then return nil end
	local ok, h = pcall(function () return he:current_health() end)
	if ok and type(h) == "number" then return h end
	return nil
end

-- Overkill accounting, identical to the other modules.
local function useful_extra(baseline, extra, H)
	if not H then return extra end
	local lo = math.min(baseline, H)
	local hi = math.min(baseline + extra, H)
	local u = hi - lo
	if u < 0 then u = 0 end
	if u > extra then u = extra end
	return u
end

local function career_is_bw()
	local unit = local_player_unit()
	if not unit then return false end
	local ce = ScriptUnit.has_extension(unit, "career_system")
	if not ce then return false end
	local ok, name = pcall(function () return ce:career_name() end)
	return ok and name == BW_CAREER_NAME
end

-- Panel/simulation active only while playing Battle Wizard.
local function active()
	return career_is_bw()
end

local function talent_equipped(unit, talent_name)
	local te = ScriptUnit.has_extension(unit, "talent_system")
	if not te then return false end
	local ok, res = pcall(function () return te:has_talent(talent_name) end)
	return ok and res or false
end

-- Is this hit's damage_type "burninating" (a burn DoT tick)? Mirrors the game's
-- own gate for increased_burn_dot_damage (DamageUtils.apply_buffs_to_damage).
local function is_burn_hit(ctx)
	local dp = ctx.damage_profile
	if not dp or not dp.is_dot then return false end
	local ok, dt = pcall(function ()
		return DamageUtils.get_damage_type(dp, ctx.target_index or 1)
	end)
	return ok and dt == "burninating"
end

-- Does reduced_non_burn_damage apply to this hit? The game gates it on the
-- damage_source resolving to a weapon template whose buff_type is a melee OR ranged
-- type (DamageUtils.apply_buffs_to_damage). Excludes DoTs, career skills, explosions.
local function is_weapon_hit(ctx)
	if ctx.damage_profile and ctx.damage_profile.is_dot then return false end
	local ok, res = pcall(function ()
		local item = rawget(ItemMasterList, ctx.damage_source)
		local tmpl = item and item.template
		local wt = tmpl and WeaponUtils.get_weapon_template(tmpl)
		local bt = wt and wt.buff_type
		if not bt then return false end
		return (MeleeBuffTypes[bt] or RangedBuffTypes[bt]) and true or false
	end)
	return ok and res or false
end

-- The base tick interval for a burn DoT profile (before Lingering Flames halves it).
local function burn_base_interval(dp)
	local ok, name = pcall(function ()
		-- Reverse-lookup the profile name; the resolved dp table has no name field.
		local dpt = rawget(_G, "DamageProfileTemplates")
		if not dpt then return nil end
		for pn, iv in pairs(BURN_INTERVAL_BY_PROFILE_NAME) do
			if dpt[pn] == dp then return iv end
		end
		return nil
	end)
	if ok and name then return name end
	return BURN_INTERVAL_DEFAULT
end

-- Debug-only: reverse-lookup the burn profile's NAME (for logging which cadence table
-- entry a tick mapped to). Returns "?" if it can't be resolved.
local function burn_profile_name(dp)
	local ok, name = pcall(function ()
		local dpt = rawget(_G, "DamageProfileTemplates")
		if not dpt then return nil end
		for pn in pairs(BURN_INTERVAL_BY_PROFILE_NAME) do
			if dpt[pn] == dp then return pn end
		end
		return nil
	end)
	if ok and name then return name end
	return "?"
end

-- A short unit tag for logs (breed name + a stable, GUARANTEED-UNIQUE sequential id),
-- so interleaved per-unit lines can be told apart. tostring(unit) can print the same
-- "#ID[...]" for two live units, so we allocate our own ids in a weak-keyed map instead.
local unit_ids = setmetatable({}, { __mode = "k" })
local unit_id_next = 0
local function unit_tag(unit)
	local id = unit_ids[unit]
	if not id then
		unit_id_next = unit_id_next + 1
		id = unit_id_next
		unit_ids[unit] = id
	end
	local breed = "?"
	pcall(function ()
		local b = Unit.get_data(unit, "breed")
		if b and b.name then breed = b.name end
	end)
	return string.format("%s#u%d", breed, id)
end

-- ---------------------------------------------------------------------------
-- Volcanic Force: re-run calculate_damage with the attack's original power scaled by
-- `factor` (full_charge_boost is applied to the power BEFORE calculate_damage, so we
-- model it on original_power_level -- NOT via the post-scale apply_buffs_to_power_level
-- hook the EP/Reaper power_level stat buffs use).
-- ---------------------------------------------------------------------------
local vf_window = nil   -- game-time expiry of the fully-charged window

local function vf_recompute(ctx, factor)
	local ok, v = pcall(ctx.func, ctx.damage_output, ctx.target_unit, ctx.attacker_unit,
		ctx.hit_zone_name, (ctx.original_power_level or 0) * factor, ctx.boost_curve,
		ctx.boost_damage_multiplier, ctx.is_critical_strike, ctx.damage_profile,
		ctx.target_index, ctx.backstab_multiplier, ctx.damage_source)
	if ok and type(v) == "number" then return v end
	return ctx.final
end

-- ---------------------------------------------------------------------------
-- Per-hit crediting (Volcanic Force + Famished Flames + Lingering Flames sampling).
-- ---------------------------------------------------------------------------
local function credit_pair(catset, cat, base, extra, health)
	if extra == 0 then return end
	local capped = useful_extra(base, math.abs(extra), health)
	if extra < 0 then capped = -capped end
	catset[cat].total = catset[cat].total + capped
	catset[cat].uncap = catset[cat].uncap + extra
end

-- Feed the shared kill tracker a with/without pair whose K=real/model calibration
-- reproduces the correct FF / no-FF (or VF / no-VF) applied damage. `factor` is the
-- talent's per-hit damage multiplier (>1 boost, <1 reduction). When NOT equipped the
-- model (ctx.final) IS the no-talent world, so without=final, with=final*factor. When
-- equipped ctx.final is still the pre-talent model but the REAL applied damage carries
-- the factor (so the batch K already includes it): with=final, without=final/factor,
-- and with*K / without*K then land on the real / real-without-factor applied damage.
local function credit_kill(talent, final, factor, equipped)
	if factor == 1.0 then return end
	if equipped then
		l10bw_kt:add(talent, final / factor, final)
	else
		l10bw_kt:add(talent, final, final * factor)
	end
end

-- Lingering Flames: record a real burn tick and (re)arm the per-unit projection.
local function lf_touch(unit, tick_dmg, dp, cat, health)
	local st = lf_units[unit]
	if not st then
		st = { cat = cat or "trash", lf_timer = 0, lf_sum = 0, real_sum = 0,
			hp0 = health or unit_current_health(unit) or math.huge }
		lf_units[unit] = st
	end
	st.tick_dmg = tick_dmg
	-- Vanilla Lingering Flames ticks at 2x rate (interval x0.5); TB removes the extra
	-- tick rate, so the infinite single stack ticks at the NORMAL interval.
	st.lf_interval = burn_base_interval(dp) * (tb_mod_active() and 1.0 or 0.5)
	st.real_sum = st.real_sum + tick_dmg
	st.cat = cat or st.cat
end

-- DEBUG: record every real burn tick on a unit (equipped or not) into lf_dbg.
local function lf_dbg_observe(unit, tick_dmg, dp, cat, health, equipped)
	if not DBG then return end
	local st = lf_dbg[unit]
	local now = game_time()
	if not st then
		st = { ticks = 0, real_sum = 0, hp0 = health or unit_current_health(unit) or math.huge,
			equipped = equipped, profile = burn_profile_name(dp), base_iv = burn_base_interval(dp),
			first_t = now, last_t = now, cat = cat or "trash" }
		lf_dbg[unit] = st
	end
	st.ticks = st.ticks + 1
	st.real_sum = st.real_sum + tick_dmg
	st.last_t = now
	st.equipped = equipped
	dlog("LF-obs tick %s eq=%s prof=%s dmg=%.2f real_sum=%.2f ticks=%d dt=%.2f (base_iv=%.2f)",
		unit_tag(unit), tostring(equipped), st.profile, tick_dmg, st.real_sum, st.ticks,
		now - (st.last_prev or now), st.base_iv)
	st.last_prev = now
end

-- DEBUG: log a unit's observed real-burn summary at death, and drop it from lf_dbg.
local function lf_dbg_finalize(unit)
	if not DBG then return end
	local st = lf_dbg[unit]
	if not st then return end
	lf_dbg[unit] = nil
	local span = st.last_t - st.first_t
	local obs_iv = (st.ticks > 1) and (span / (st.ticks - 1)) or 0
	dlog("LF-obs DEATH %s eq=%s prof=%s ticks=%d real_burn=%.2f hp0=%.2f span=%.2fs obs_iv=%.2f (expect eq->%.2f / vanilla->%.2f)",
		unit_tag(unit), tostring(st.equipped), st.profile, st.ticks, st.real_sum, st.hp0,
		span, obs_iv, st.base_iv * (tb_mod_active() and 1.0 or 0.5), st.base_iv)
end

-- Compute a live LF unit's current extra (LF projected burn - real burn), capped and raw.
local function lf_unit_extra(st)
	local hp0 = st.hp0
	local uncap = st.lf_sum - st.real_sum
	local capped = math.min(st.lf_sum, hp0) - math.min(st.real_sum, hp0)
	return capped, uncap
end

-- Bank a finished (dead / despawned) LF unit's extra into lf_final and drop it.
local function lf_finalize(unit)
	lf_dbg_finalize(unit)
	local st = lf_units[unit]
	if not st then return end
	lf_units[unit] = nil
	if st.cat and lf_final[st.cat] then
		local capped, uncap = lf_unit_extra(st)
		lf_final[st.cat].total = lf_final[st.cat].total + capped
		lf_final[st.cat].uncap = lf_final[st.cat].uncap + uncap
		dlog("LF-sim DEATH %s cat=%s projected_burn=%.2f real_burn=%.2f hp0=%.2f -> extra capped=%.2f uncap=%.2f iv=%.2f",
			unit_tag(unit), st.cat, st.lf_sum, st.real_sum, st.hp0, capped, uncap, st.lf_interval or -1)
	end
end

local function on_hit(ctx)
	if not active() then return end
	local attacker = ctx.attacker_unit
	if attacker ~= local_player_unit() then return end
	local final = ctx.final
	if not final or final <= 0 then return end
	local dp = ctx.damage_profile
	if not dp then return end

	local target = ctx.target_unit
	local health = unit_current_health(target)
	if health and health <= 0 then   -- corpse contact / already dead
		if l10bw_kt then l10bw_kt:forget(target) end
		lf_finalize(target)
		return
	end
	local cat = ctx.cat or F.cat_of(target)

	-- --- Burn DoT ticks: Famished Flames burn gain + Lingering Flames sampling. ---
	if dp.is_dot then
		if is_burn_hit(ctx) then
			-- Famished Flames: +100%/+150% (TB) burn -> the extra is the base tick times
			-- (factor-1). Post-calc, so the factor is exact whether or not FF is equipped.
			local ff_equipped = talent_equipped(attacker, TALENT_FF)
			local burn_factor = ff_burn_factor()
			local gain = final * (burn_factor - 1.0)
			credit_pair(ffb_cat, cat, final, gain, health)
			credit_kill("famished", final, burn_factor, ff_equipped)
			dlog("FF burn %s eq=%s base=%.2f gain=%.2f hp=%s cat=%s",
				unit_tag(target), tostring(ff_equipped), final, gain,
				health and string.format("%.0f", health) or "?", cat)
			-- The ACTUAL applied burn this tick. FF's +100% is POST-calculate_damage, so
			-- ctx.final is pre-FF; when FF is equipped the real applied tick is final x2.
			-- Lingering Flames must compare in real applied-damage units (both its vanilla
			-- baseline and its 2x-rate projection carry the same FF factor, and the overkill
			-- cap is against the unit's REAL HP), so feed the applied burn -- NOT ctx.final.
			local applied_burn = ff_equipped and (final * burn_factor) or final
			-- Lingering Flames: sample the real burn tick and (re)arm the projection
			-- (only meaningful when NOT equipped -- see draw / M.update).
			local lf_equipped = talent_equipped(attacker, TALENT_LF)
			-- DEBUG: observe the REAL applied burn on every unit (equipped or not) so we can
			-- log exactly what Lingering produces when it IS on and validate the sim otherwise.
			lf_dbg_observe(target, applied_burn, dp, cat, health, lf_equipped)
			if not lf_equipped then
				lf_touch(target, applied_burn, dp, cat, health)
			end
		end
		return
	end

	-- --- Direct (non-DoT) hits: dedupe each genuine hit once (melee AND ranged),
	-- reusing the level-15 per-genuine-hit decision (self_ctx on host / time window
	-- on client), exactly as the level-15 account_hit does for non-dot hits. ---
	if not (mod._l15_melee_credit and mod._l15_melee_credit(ctx)) then return end

	-- --- Famished Flames: -15% to weapon (melee/ranged) hits, incl. staff direct. ---
	if is_weapon_hit(ctx) then
		local ff_equipped = talent_equipped(attacker, TALENT_FF)
		local weapon_factor = ff_weapon_factor()
		local loss = final * (1.0 - weapon_factor)   -- positive magnitude
		credit_pair(ffw_cat, cat, final - loss, loss, health)
		credit_kill("famished", final, weapon_factor, ff_equipped)
		dlog("FF weapon %s eq=%s base=%.2f loss=%.2f src=%s cat=%s",
			unit_tag(target), tostring(ff_equipped), final, loss,
			tostring(ctx.damage_source), cat)
	end

	-- --- Volcanic Force: +50% power on fully-charged spell hits. Only direct spell
	-- hits within the fully-charged window (not melee light/heavy attacks). ---
	local is_melee = dp.charge_value == "light_attack" or dp.charge_value == "heavy_attack"
	if not is_melee then
		local windowed = vf_window and game_time() <= vf_window
		if not windowed then
			dlog("VF skip %s: not in fully-charged window (chg=%s final=%.2f pwr=%.1f)",
				unit_tag(target), tostring(dp.charge_value), final, ctx.original_power_level or -1)
		else
			local vf_equipped = talent_equipped(attacker, TALENT_VF)
			local base, extra
			if vf_equipped then
				base = vf_recompute(ctx, 1.0 / VF_FACTOR)
				extra = final - base
			else
				base = final
				extra = vf_recompute(ctx, VF_FACTOR) - final
			end
			if extra > 0 then
				credit_pair(vf_cat, cat, base, extra, health)
				-- Kill-aware: feed the ACTUAL recomputed base/with (Volcanic Force is a
				-- pre-calc power boost, so its per-hit delta is nonlinear through armour
				-- breakpoints -- a flat 1/1.5 factor would misstate it). Both `base` and
				-- `base+extra` are in ctx.final's model scale, so the batch K = real/final
				-- calibration lands them on the real no-VF / VF applied damage either way.
				l10bw_kt:add("volcanic", base, base + extra)
				-- Refresh the window: a sustained spray keeps landing boosted ticks.
				vf_window = game_time() + VF_WINDOW
				dlog("VF hit %s eq=%s pwr=%.1f base=%.2f with=%.2f extra=%.2f (final=%.2f zone=%s crit=%s ti=%s)",
					unit_tag(target), tostring(vf_equipped), ctx.original_power_level or -1,
					base, base + extra, extra, final, tostring(ctx.hit_zone_name),
					tostring(ctx.is_critical_strike), tostring(ctx.target_index))
			else
				dlog("VF hit %s eq=%s extra<=0 (base=%.2f final=%.2f pwr=%.1f) -> not credited",
					unit_tag(target), tostring(talent_equipped(attacker, TALENT_VF)),
					base, final, ctx.original_power_level or -1)
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- Init / wiring
-- ---------------------------------------------------------------------------
function M.init(owner_mod, ui_panel)
	mod = owner_mod
	ui = ui_panel
	F = mod._filter

	-- Own kill / Real-Total tracker instance (shared engine, owned by level15).
	l10bw_kt = mod._kill_tracker.new()

	M.reset()

	-- Forwarded by the level-15 module's single calculate_damage hook.
	mod._l10_bw_on_hit = function (ctx) pcall(on_hit, ctx) end

	-- Volcanic Force detection: a fully-charged cast of any of the three charged-spell
	-- action classes arms the window. hook_safe (no return value needed); nothing else
	-- in this mod hooks these classes, so no VMF duplicate-hook conflict.
	local function arm_if_fully_charged(self, charge)
		if not active() then return end
		if self.owner_unit ~= local_player_unit() then return end
		if charge and charge >= 1 then
			vf_window = game_time() + VF_WINDOW
			dlog("VF fully-charged cast -> window armed")
		end
	end
	local charged_actions = {
		{ cls = "ActionChargedProjectile", get = function (self) return self._projectile_context and self._projectile_context.charge_level end },
		{ cls = "ActionGeiser",            get = function (self) return self.charge_value end },
		{ cls = "ActionFlamethrower",      get = function (self) return self.charge_level end },
	}
	for _, entry in ipairs(charged_actions) do
		local cls = rawget(_G, entry.cls)
		if cls then
			mod:hook_safe(cls, "client_owner_start_action", function (self)
				arm_if_fully_charged(self, entry.get(self))
			end)
		end
	end
end

-- ---------------------------------------------------------------------------
-- Update: advance each live Lingering-Flames projection (2x-rate persistent stack)
-- and bank units that have died / despawned.
-- ---------------------------------------------------------------------------
function M.update(dt)
	-- DEBUG: finalize (log + drop) observed burn units that have died. Needed for the
	-- LF-equipped case, where lf_units is empty so the projection loop below never runs.
	if DBG and next(lf_dbg) then
		for unit in pairs(lf_dbg) do
			local alive = Unit.alive(unit) and (unit_current_health(unit) or 0) > 0
			if not alive then lf_dbg_finalize(unit) end
		end
	end
	if not next(lf_units) then return end
	for unit, st in pairs(lf_units) do
		local alive = Unit.alive(unit) and (unit_current_health(unit) or 0) > 0
		if not alive then
			lf_finalize(unit)
		elseif st.tick_dmg and st.lf_interval and st.lf_interval > 0 then
			-- Emit LF ticks at 2x the base rate for as long as the unit lives (LF lasts
			-- until death); cap the projected burn at the unit's starting HP (no overkill).
			st.lf_timer = st.lf_timer + dt
			while st.lf_timer >= st.lf_interval do
				st.lf_timer = st.lf_timer - st.lf_interval
				if st.lf_sum < st.hp0 then
					st.lf_sum = st.lf_sum + st.tick_dmg
				end
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- Display
-- ---------------------------------------------------------------------------
local T10BW_TOTAL_COL = 190
local T10BW_UNCAP_COL = 320
local T10BW_REAL_COL  = 450   -- Real Total: extra damage that actually pulled kills sooner
local PANEL_W_T10BW   = 620

function M.wants_display()
	return active()
end

-- Sum live Lingering-Flames extra (banked finished units + current live units).
local function lf_totals()
	local total, uncap = merge_pair(lf_final)
	for _, st in pairs(lf_units) do
		if F.enabled(st.cat) then
			local c, u = lf_unit_extra(st)
			total = total + c
			uncap = uncap + u
		end
	end
	return total, uncap
end

function M.log_state()
	if not DBG then return end
	local vf_t, vf_u = merge_pair(vf_cat)
	local ffb_t = select(1, merge_pair(ffb_cat))
	local ffw_t = select(1, merge_pair(ffw_cat))
	local lf_t, lf_u = lf_totals()
	dlog("L10BW SNAP vf=%.1f (%.1f) | ff net=%.1f (burn +%.1f / weap -%.1f) | lf=%.1f (%.1f)",
		vf_t, vf_u, ffb_t - ffw_t, ffb_t, ffw_t, lf_t, lf_u)
	dlog("L10BW REAL-TOTAL vf=%.1f ff=%.1f (lingering has none: forward projection, no add_damage to calibrate)",
		kget("volcanic").real_total, kget("famished").real_total)
	-- Aggregate the debug LF observation across still-live units (equipped or not).
	local obs_units, obs_ticks, obs_sum, eq_any = 0, 0, 0, false
	for _, st in pairs(lf_dbg) do
		obs_units = obs_units + 1
		obs_ticks = obs_ticks + st.ticks
		obs_sum = obs_sum + st.real_sum
		if st.equipped then eq_any = true end
	end
	dlog("L10BW LF-OBS live_units=%d ticks=%d real_burn=%.1f (LF_equipped=%s) | sim_units_live=%d",
		obs_units, obs_ticks, obs_sum, tostring(eq_any), (function () local n = 0 for _ in pairs(lf_units) do n = n + 1 end return n end)())
end

function M.reset_self()
	if M.log_state then pcall(M.log_state) end
	M.reset()
end

function M.draw(gui)
	local FONT_SIZE = ui.FONT_SIZE
	local small = FONT_SIZE - 6

	-- rows: title(0) header(1) VF(2) FF(3) FF-split(4) LF(5) note(6). content_rows = 6.
	local x, top, row_y, collapsed, title_visible = ui.frame(gui, PANEL_W_T10BW, 6, "l10bw_pos_x", "l10bw_pos_y", 0.03, 0.35, "l10bw", M.reset_self)
	if not x then return end

	if title_visible then
		ui.text_bold(gui, "Volcanic Force / Famished Flames / Lingering Flames:", x, row_y(0), FONT_SIZE, ui.yellow)
	end
	if collapsed then return end

	ui.text(gui, "Extra Damage:", x, row_y(1), small, ui.grey)
	ui.text(gui, "Total", x + T10BW_TOTAL_COL, row_y(1), small, ui.grey)
	ui.text(gui, "Uncapped", x + T10BW_UNCAP_COL, row_y(1), small, ui.grey)
	ui.text(gui, "Real Total", x + T10BW_REAL_COL, row_y(1), small, ui.grey)

	local player_unit = local_player_unit()

	local function row(i, name, total, uncap, real_str)
		local ry = row_y(i)
		ui.text(gui, name, x, ry, FONT_SIZE, ui.white)
		ui.text(gui, string.format("%.0f", total), x + T10BW_TOTAL_COL, ry, FONT_SIZE, ui.white)
		ui.text(gui, string.format("%.0f", uncap), x + T10BW_UNCAP_COL, ry, FONT_SIZE, ui.white)
		ui.text(gui, real_str, x + T10BW_REAL_COL, ry, FONT_SIZE, ui.white)
	end

	-- Volcanic Force.
	local vf_total, vf_uncap = merge_pair(vf_cat)
	row(2, "Volcanic Force", vf_total, vf_uncap, string.format("%.0f", kget("volcanic").real_total))

	-- Famished Flames: NET (burn gain minus weapon loss), with the split beneath.
	local ffb_total, ffb_uncap = merge_pair(ffb_cat)
	local ffw_total, ffw_uncap = merge_pair(ffw_cat)
	row(3, "Famished Flames", ffb_total - ffw_total, ffb_uncap - ffw_uncap,
		string.format("%.0f", kget("famished").real_total))
	ui.text(gui, string.format("   burn +%.0f  /  weapon -%.0f", ffb_total, ffw_total),
		x, row_y(4), small, ui.grey)

	-- Lingering Flames: simulated. "-" for Real Total (projection, not calibrated);
	-- dashed entirely when equipped (the vanilla baseline can't be reconstructed).
	local lf_equipped = player_unit and talent_equipped(player_unit, TALENT_LF)
	local lf_ry = row_y(5)
	if lf_equipped then
		ui.text(gui, "Lingering Flames (equipped)", x, lf_ry, FONT_SIZE, ui.white)
		ui.text(gui, "-", x + T10BW_TOTAL_COL, lf_ry, FONT_SIZE, ui.white)
		ui.text(gui, "-", x + T10BW_UNCAP_COL, lf_ry, FONT_SIZE, ui.white)
		ui.text(gui, "-", x + T10BW_REAL_COL, lf_ry, FONT_SIZE, ui.white)
	else
		local lf_total, lf_uncap = lf_totals()
		row(5, "Lingering Flames", lf_total, lf_uncap, "-")
	end

	local note
	if lf_equipped then
		note = "Lingering Flames equipped: its burns are the measured ones (baseline not reconstructable)."
	else
		note = "Lingering Flames is simulated (1 stack, 2x tick rate, until death). Host-only, may be negative."
	end
	ui.text(gui, note, x, row_y(6), small, ui.grey)
end

return M
