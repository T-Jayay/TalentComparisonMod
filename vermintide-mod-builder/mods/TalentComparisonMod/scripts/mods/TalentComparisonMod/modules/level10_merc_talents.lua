-- level10_merc_talents.lua
-- ============================================================================
-- Talent group: Level-10 Mercenary (es_mercenary) talents. CAREER-SPECIFIC, like
-- the level-10 WHC and level-20 Mercenary panels -- the panel is hidden and NONE of
-- the simulation runs unless the LOCAL player is currently playing Mercenary.
--
-- A Mercenary picks 2 of these 3 at level 10:
--   More the Merrier (markus_mercenary_increased_damage_on_enemy_proximity) --
--     +5% POWER per nearby (<=3m) alive enemy, up to 5 stacks (25% max). The
--     internal name says "damage" but the sub-buff markus_mercenary_damage_on_enemy_
--     proximity is a `power_level` stat buff (multiplier 0.05, max_stacks 5), so it
--     is a variable-multiplier POWER boost -- valued exactly like Enhanced Power via
--     the shared power_boost engine, with mult = 0.05 * current_stacks resolved live.
--     Stacks are computed the way the game does (buff_function_templates.lua
--     activate_buff_stacks_based_on_enemy_proximity): a server broadphase query for
--     alive enemies within 3m. HOST ONLY (broadphase is server-side).
--   Limb Splitter (markus_mercenary_power_level_cleave) -- +50% cleave power
--     (power_level_melee_cleave stacking_multiplier 0.5), applied to the sweep's
--     cleave power in action_sweep.lua. Pure CLEAVE: it changes how many targets a
--     swing reaches, not per-hit damage. Valued through the shared power_boost cleave
--     machinery (extra units + their damage), reusing the general Force cleave button
--     (force_ep): forced when that is on and Limb Splitter is not equipped, otherwise
--     a rough estimate. Measured only when NOT equipped (the engine's force/estimate
--     path); when equipped the real sweep already cleaves so the panel shows "-".
--   Helborg's Tutelage (markus_mercenary_crit_count) -- every 5 attacks grant one
--     guaranteed crit (single hit, remove_on_proc) AND random crits are removed. So
--     its value is the crit damage of the guaranteed crits MINUS the random crits it
--     would have suppressed. Valued by re-running calculate_damage with the crit flag
--     toggled (the same trick WHC Riposte uses), netted over both effects. Measured
--     only when NOT equipped (this is a "value of the talent you didn't take" panel).
--
-- Reported per talent, like the other damage panels:
--   Total    : extra damage across all targets, OVERKILL removed.
--   First    : the same, first unit only (target_index 1).
--   Uncapped : the raw hypothetical extra (no overkill removal).
-- Limb Splitter instead reports extra units cleaved + the damage dealt to them.
--
-- WIRING: this module owns no hooks. Per-hit crediting is forwarded from the level-15
-- DamageUtils.calculate_damage hook via mod._l10_merc_on_hit(ctx) (VMF ignores a
-- duplicate hook on the same func from the same mod). Melee dedupe reuses the level-15
-- decision (mod._l15_melee_credit). More the Merrier / Limb Splitter register shared
-- power_boost instances (mod._power_boost), so the level-15 sweep/cleave hooks drive
-- their cleave automatically. Most accurate as host.
-- ============================================================================

local M = {}

local mod   -- set in init()
local ui    -- shared ui_panel, set in init()
local l10m_kt       -- shared kill-tracker instance (mod._kill_tracker.new(), created in init)
local PowerBoost    -- shared power_boost module (from level 15, via mod._power_boost)
local mtm_boost     -- More the Merrier's power_boost instance (mult 0.05*stacks)
local ls_boost      -- Limb Splitter's cleave-only power_boost instance (mult 0.5)

local DBG = false
local function dlog(fmt, ...)
	if DBG and mod then
		local ok, s = pcall(string.format, "[TCM10M] " .. fmt, ...)
		if not ok then s = "[TCM10M] (log format error) " .. fmt end
		mod:echo((s:gsub("%%", "%%%%")))
	end
end

-- TB-mode detection (same as the level-15 / THP panels): when the Tourney Balance
-- mod is loaded+enabled the game is running TB's reworked talents. For Helborg's
-- Tutelage the only relevant TB change is that Merc CAN still crit under TB, so TB's
-- Helborg does NOT suppress random crits -- its value is just the forced-crit gains,
-- with no suppression subtracted. We always track both variants and swap which is the
-- primary "Total" column by mode (Official primary + TB extra column on vanilla; TB
-- primary + Official extra column under TB).
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

local MERC_CAREER_NAME = "es_mercenary"
-- Talent buff names for has_talent() detection (talent_settings_markus.lua).
local TALENT_MTM     = "markus_mercenary_increased_damage_on_enemy_proximity"
local TALENT_LS      = "markus_mercenary_power_level_cleave"
local TALENT_HELBORG = "markus_mercenary_crit_count"

-- More the Merrier numbers (talent_settings_markus.lua buff_tweak_data).
local MTM_PER_STACK  = 0.05   -- markus_mercenary_damage_on_enemy_proximity.multiplier
local MTM_MAX_STACKS = 5       -- .max_stacks
local MTM_RANGE      = 3        -- markus_mercenary_increased_damage_on_enemy_proximity.range
-- Limb Splitter cleave power multiplier.
local LS_CLEAVE_MULT = 0.5      -- markus_mercenary_power_level_cleave.multiplier
-- Helborg's Tutelage: guaranteed crit every N attacks (markus_mercenary_crit_count
-- .buff_on_stacks = 5; the counter increments once per attack, incl. ranged).
local HELBORG_HIT_COUNT = 5

-- ---------------------------------------------------------------------------
-- Running totals (Helborg only; More the Merrier / Limb Splitter live on their
-- power_boost instances).
-- ---------------------------------------------------------------------------
local helborg      -- Official variant { total_dmg, first_dmg, total_uncapped } (with crit suppression)
local helborg_tb   -- TB variant (forced-crit gains only; no random-crit suppression)
local helborg_hits -- attack counter toward the next guaranteed crit
local cur_attack   -- per-attack Helborg decision, set at first target, reused for cleaved targets

-- Running average of the player's melee cleave-hit damage (non-first targets),
-- used to estimate Limb Splitter's extra-cleave damage when Force cleave is off
-- (the extra units are only counted, never actually landed, so we have no real
-- per-unit damage for them).
local ls_est_sum       -- sum of useful (health-capped) damage over sampled hits
local ls_est_uncap_sum -- sum of raw damage over sampled hits
local ls_est_count     -- number of sampled hits

local function new_record()
	return { total_dmg = 0, first_dmg = 0, total_uncapped = 0 }
end

function M.reset()
	if mtm_boost then mtm_boost:reset() end
	if ls_boost then ls_boost:reset() end
	if l10m_kt then l10m_kt:reset() end
	helborg = new_record()
	helborg_tb = new_record()
	helborg_hits = 0
	cur_attack = nil
	ls_est_sum = 0
	ls_est_uncap_sum = 0
	ls_est_count = 0
end

-- Kill-column record for `talent` from the shared tracker, or an all-zero default
-- before its first credit. Helborg tracks two variants ("helborg" Official /
-- "helborg_tb" TB), mirroring its two Total records.
local ZERO_KILLS = { n = 0, hpk_sum = 0, hpk_n = 0, real_total = 0 }
local function kget(talent)
	return (l10m_kt and l10m_kt:get(talent)) or ZERO_KILLS
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

local function unit_current_health(unit)
	local he = ScriptUnit.has_extension(unit, "health_system")
	if not he then return nil end
	local ok, h = pcall(function () return he:current_health() end)
	if ok and type(h) == "number" then return h end
	return nil
end

local function useful_extra(baseline, extra, H)
	if not H then return extra end
	local lo = math.min(baseline, H)
	local hi = math.min(baseline + extra, H)
	local u = hi - lo
	if u < 0 then u = 0 end
	if u > extra then u = extra end
	return u
end

local function is_server()
	return (Managers.state.network and Managers.state.network.is_server) and true or false
end

local function career_is_merc()
	local unit = local_player_unit()
	if not unit then return false end
	local ce = ScriptUnit.has_extension(unit, "career_system")
	if not ce then return false end
	local ok, name = pcall(function () return ce:career_name() end)
	return ok and name == MERC_CAREER_NAME
end

local function talent_equipped(unit, talent_name)
	local te = ScriptUnit.has_extension(unit, "talent_system")
	if not te then return false end
	local ok, res = pcall(function () return te:has_talent(talent_name) end)
	return ok and res or false
end

-- Sub-toggle defaults to on when unset (the tiered settings default nil -> true).
local function sub_on()
	local v = mod:get("show_level10_merc")
	if v == nil then return true end
	return v
end

-- Panel/simulation active only for Mercenary with the tier + sub toggle on.
local function active()
	return mod:get("show_level10") and sub_on() and career_is_merc()
end

-- ---------------------------------------------------------------------------
-- More the Merrier stack count: replicate the game's server broadphase query for
-- alive enemies within 3m (activate_buff_stacks_based_on_enemy_proximity). Same
-- computation whether or not the talent is equipped, so the live multiplier is
-- 0.05 * stacks in both the "not equipped" (simulate) and "equipped" (recompute
-- without) cases. HOST ONLY -- returns 0 on a pure client.
-- ---------------------------------------------------------------------------
local broadphase_results = {}
local function mtm_stacks()
	if not is_server() then return 0 end
	local unit = local_player_unit()
	if not unit then return 0 end
	local ok, n = pcall(function ()
		local side = Managers.state.side.side_by_unit[unit]
		if not side then return 0 end
		local ai_system = Managers.state.entity:system("ai_system")
		local broadphase = ai_system and ai_system.broadphase
		local pos = POSITION_LOOKUP[unit]
		if not broadphase or not pos then return 0 end
		local cats = side.enemy_broadphase_categories
		local num = Broadphase.query(broadphase, pos, MTM_RANGE, broadphase_results, cats)
		local alive = 0
		for i = 1, num do
			if HEALTH_ALIVE[broadphase_results[i]] then
				alive = alive + 1
				if alive >= MTM_MAX_STACKS then break end
			end
		end
		return alive
	end)
	return (ok and n) or 0
end

local function mtm_mult()
	return MTM_PER_STACK * mtm_stacks()
end

-- ---------------------------------------------------------------------------
-- Helborg's Tutelage: net crit damage of the guaranteed-crit cadence minus the
-- random crits it would suppress. Only credited when NOT equipped.
-- ---------------------------------------------------------------------------
local function recompute_crit(ctx, crit)
	local ok, v = pcall(ctx.func, ctx.damage_output, ctx.target_unit, ctx.attacker_unit,
		ctx.hit_zone_name, ctx.original_power_level, ctx.boost_curve, ctx.boost_damage_multiplier,
		crit, ctx.damage_profile, ctx.target_index, ctx.backstab_multiplier, ctx.damage_source)
	if ok and type(v) == "number" then return v end
	return ctx.final
end

-- Credit a Helborg record (Official or TB). `also_tb` credits both the Official and
-- TB records (forced-crit gains apply to both); a suppression event (sign=-1) passes
-- also_tb=false so it lands on Official only -- TB Merc keeps its random crits.
local function credit_helborg(base, extra, health, first, sign, also_tb)
	if extra <= 0 then return end
	local capped = useful_extra(base, extra, health)
	helborg.total_uncapped = helborg.total_uncapped + sign * extra
	helborg.total_dmg = helborg.total_dmg + sign * capped
	if first then
		helborg.first_dmg = helborg.first_dmg + sign * capped
	end
	if also_tb then
		helborg_tb.total_uncapped = helborg_tb.total_uncapped + sign * extra
		helborg_tb.total_dmg = helborg_tb.total_dmg + sign * capped
		if first then
			helborg_tb.first_dmg = helborg_tb.first_dmg + sign * capped
		end
	end
end

-- ctx = the calculate_damage context; final/health/first precomputed by on_hit.
local function account_helborg(ctx, final, health, first)
	if talent_equipped(ctx.attacker_unit, TALENT_HELBORG) then return end

	-- The counter increments once per ATTACK (first target only). Decide at the first
	-- target whether this whole attack is the guaranteed crit, then reuse that decision
	-- for the attack's cleaved targets (a crit crits every target it hits).
	if first then
		helborg_hits = helborg_hits + 1
		local forced = helborg_hits >= HELBORG_HIT_COUNT
		if forced then helborg_hits = 0 end
		cur_attack = { forced = forced }
	end
	local forced = cur_attack and cur_attack.forced
	local crit = ctx.is_critical_strike

	if forced then
		-- Guaranteed crit under Helborg. If the real hit was not already a crit, credit
		-- the crit delta; if it already crit (a random crit that Helborg would also make
		-- crit), net zero -- and do NOT subtract it as a suppressed random crit.
		if not crit then
			local c = recompute_crit(ctx, true)
			credit_helborg(final, c - final, health, first, 1, true)  -- gain: both variants
			-- Kill-aware: baseline = real (non-crit) hit, world = the forced crit. The
			-- gain applies to both variants (Official + TB).
			l10m_kt:add("helborg", final, c)
			l10m_kt:add("helborg_tb", final, c)
			dlog("HELBORG forced-crit zone=%s fin=%.2f crit=%.2f +%.2f", tostring(ctx.hit_zone_name), final, c, c - final)
		end
	elseif crit then
		-- A random crit on a non-forced attack: vanilla Helborg removes random crits, so
		-- taking it would have made this a normal hit -- subtract the crit's extra damage.
		-- Under TB, Merc keeps its random crits, so this suppression does NOT apply to TB.
		local base = recompute_crit(ctx, false)
		credit_helborg(base, final - base, health, first, -1, false)  -- suppression: Official only
		-- Kill-aware (Official only): the talent's world is the WEAKER, suppressed hit
		-- (with = base < without = the real crit), so it can only delay a kill, never
		-- pull one sooner. TB keeps random crits, so its variant is unaffected.
		l10m_kt:add("helborg", final, base)
		dlog("HELBORG suppress-crit zone=%s fin=%.2f base=%.2f -%.2f", tostring(ctx.hit_zone_name), final, base, final - base)
	end
end

-- ---------------------------------------------------------------------------
-- Per-hit crediting, forwarded from the level-15 calculate_damage hook.
-- ---------------------------------------------------------------------------
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
	if health and health <= 0 then          -- corpse contact, no real damage
		if l10m_kt then l10m_kt:forget(target) end
		return
	end
	local first = (ctx.target_index or 1) <= 1
	local is_melee = not dp.is_dot
		and (dp.charge_value == "light_attack" or dp.charge_value == "heavy_attack")

	-- Melee dedupe: defer to the level-15 single per-genuine-hit decision.
	if is_melee then
		if not (mod._l15_melee_credit and mod._l15_melee_credit(ctx)) then return end
	end

	-- Forced-cleave units (a boost's Force extended the real sweep to reach them):
	-- credit to EVERY boost whose own band the unit falls in, then STOP -- these
	-- hits would not land without a boost, so they must not feed the per-hit columns.
	-- MtM and LS are independent counterfactuals ("if I had this talent instead"),
	-- not mutually exclusive, so a unit inside both bands (LS's is the larger, since
	-- its 50% cleave mult dwarfs MtM's up-to-25%) must count for both -- crediting
	-- only one used to always let LS shadow MtM, since LS's band always contains
	-- MtM's.
	if is_melee and PowerBoost.is_forced_extra(target) then
		ls_boost:account_cleave_unit(target, final, health)
		mtm_boost:account_cleave_unit(target, final, health)
		return
	end

	-- Equipped boost measuring its OWN real extra cleave (e.g. Limb Splitter equipped):
	-- credit the real per-unit damage of hits that landed only because of the boost.
	-- This does NOT return -- the hit genuinely happened, so it still feeds MtM/Helborg.
	if is_melee then
		PowerBoost.account_natural_extra(target, final, health)
	end

	-- More the Merrier: extra damage from its +5%/stack power, all sources (the
	-- power_boost instance self-gates on active() and on whether it is equipped).
	local mtm_extra = mtm_boost:account_hit(ctx, is_melee, first, health)
	if mtm_extra and mtm_extra > 0 then
		-- Kill-aware: if MtM is equipped the boost is baked into `final` (baseline =
		-- final - extra); otherwise `final` IS the baseline and the boost adds on top.
		if talent_equipped(attacker, TALENT_MTM) then
			l10m_kt:add("mtm", final - mtm_extra, final)
		else
			l10m_kt:add("mtm", final, final + mtm_extra)
		end
	end
	-- Limb Splitter has NO per-hit damage component (pure cleave), so it is not
	-- credited here -- only via the forced-cleave path above / the sweep estimate.
	-- But sample this real melee cleave-hit (non-first target) damage to build a
	-- representative per-unit average, so the Force-off estimate can turn Limb
	-- Splitter's extra-unit COUNT into an extra-DAMAGE figure at draw time.
	if is_melee and not first then
		ls_est_sum = ls_est_sum + useful_extra(0, final, health)
		ls_est_uncap_sum = ls_est_uncap_sum + final
		ls_est_count = ls_est_count + 1
	end

	-- Helborg's Tutelage: crit cadence net, melee + ranged direct hits (not DoTs).
	if not dp.is_dot then
		account_helborg(ctx, final, health, first)
	end
end

-- ---------------------------------------------------------------------------
-- Init / wiring
-- ---------------------------------------------------------------------------
function M.init(owner_mod, ui_panel)
	mod = owner_mod
	ui = ui_panel

	-- Shared power-boost engine (owned + hooked by level 15, shared via mod._power_boost).
	PowerBoost = mod._power_boost

	-- Shared kill / Real-Total tracker (owned by level15, which inits first); own instance
	-- so this panel's Reset zeroes only its rows. More the Merrier / Helborg feed it.
	l10m_kt = mod._kill_tracker.new()

	-- More the Merrier: a variable-multiplier power boost (0.05 * nearby enemies),
	-- valued exactly like Enhanced Power (all-source extra damage + extra cleave).
	mtm_boost = PowerBoost.register(PowerBoost.new({
		mult = mtm_mult,   -- resolved live per hit / sweep
		talent_equipped = function (unit) return talent_equipped(unit, TALENT_MTM) end,
		gate = active,
		force_enabled = function () return mod:get("force_ep") end,  -- shared force-cleave button
	}))

	-- Limb Splitter: cleave-only +50% power boost. We never call its account_hit (no
	-- per-hit damage); the shared sweep/cleave hooks drive its extra-cleave measurement.
	ls_boost = PowerBoost.register(PowerBoost.new({
		mult = LS_CLEAVE_MULT,
		talent_equipped = function (unit) return talent_equipped(unit, TALENT_LS) end,
		gate = active,
		force_enabled = function () return mod:get("force_ep") end,
		-- Pure cleave (no per-hit column), so it can measure its own real extra cleave
		-- while equipped without double-counting.
		measure_equipped = true,
	}))

	M.reset()

	-- Forwarded by the level-15 module's single calculate_damage hook.
	mod._l10_merc_on_hit = function (ctx) pcall(on_hit, ctx) end
end

function M.update(dt)
	-- No per-frame simulation needed (all crediting is hit-driven).
end

-- ---------------------------------------------------------------------------
-- Display
-- ---------------------------------------------------------------------------
local T10M_TOTAL_COL = 190
local T10M_FIRST_COL = 300
local T10M_UNCAP_COL = 400
local T10M_CROSS_COL = 490   -- Helborg-only cross column (TB on vanilla / Official on TB)
local T10M_REAL_COL  = 580   -- Real Total: extra damage that actually pulled kills sooner
local PANEL_W_T10M   = 730

function M.wants_display()
	return active()
end

function M.log_state()
	if not DBG then return end
	dlog("L10M SNAP mtm total/first (uncap)=%.1f/%.1f (%.1f) cleave +%d/+%.1f | ls cleave +%d/+%.1f | helborg %.1f/%.1f (%.1f)",
		mtm_boost.total_dmg, mtm_boost.first_dmg, mtm_boost.total_uncapped,
		mtm_boost.extra_units_hit or 0, mtm_boost.extra_cleave_dmg or 0,
		ls_boost.extra_units_hit or 0, ls_boost.extra_cleave_dmg or 0,
		helborg.total_dmg, helborg.first_dmg, helborg.total_uncapped)
end

function M.reset_self()
	if M.log_state then pcall(M.log_state) end
	M.reset()
end

function M.draw(gui)
	local FONT_SIZE = ui.FONT_SIZE
	local small = FONT_SIZE - 6

	-- rows: title(0) header(1) MtM(2) LimbSplitter(3) Helborg(4) cleave note(5) host note(6)
	local x, top, row_y, collapsed, title_visible = ui.frame(gui, PANEL_W_T10M, 6, "l10m_pos_x", "l10m_pos_y", 0.20, 0.6, "l10m", M.reset_self)
	if not x then return end

	if title_visible then
		ui.text_bold(gui, "More the Merrier / Limb Splitter / Helborg:", x, row_y(0), FONT_SIZE, ui.yellow)
	end
	if collapsed then return end

	-- Under TB the primary Total is TB's Helborg (no crit suppression) and the cross
	-- column shows Official; on vanilla it's the reverse.
	local tb = tb_mod_active()
	local cross_header = tb and "Official" or "TB"

	ui.text(gui, "Extra Damage:", x, row_y(1), small, ui.grey)
	ui.text(gui, "Total", x + T10M_TOTAL_COL, row_y(1), small, ui.grey)
	ui.text(gui, "First Unit", x + T10M_FIRST_COL, row_y(1), small, ui.grey)
	ui.text(gui, "Uncapped", x + T10M_UNCAP_COL, row_y(1), small, ui.grey)
	ui.text(gui, cross_header, x + T10M_CROSS_COL, row_y(1), small, ui.grey)
	ui.text(gui, "Real Total", x + T10M_REAL_COL, row_y(1), small, ui.grey)

	local player_unit = local_player_unit()
	local ls_equipped = player_unit and talent_equipped(player_unit, TALENT_LS)
	local hb_equipped = player_unit and talent_equipped(player_unit, TALENT_HELBORG)

	local function row(i, name, total, first, uncap, dashed)
		local ry = row_y(i)
		ui.text(gui, name, x, ry, FONT_SIZE, ui.white)
		if dashed then
			ui.text(gui, "-", x + T10M_TOTAL_COL, ry, FONT_SIZE, ui.white)
			ui.text(gui, "-", x + T10M_FIRST_COL, ry, FONT_SIZE, ui.white)
			ui.text(gui, "-", x + T10M_UNCAP_COL, ry, FONT_SIZE, ui.white)
		else
			ui.text(gui, string.format("%.0f", total), x + T10M_TOTAL_COL, ry, FONT_SIZE, ui.white)
			ui.text(gui, string.format("%.0f", first), x + T10M_FIRST_COL, ry, FONT_SIZE, ui.white)
			ui.text(gui, string.format("%.0f", uncap), x + T10M_UNCAP_COL, ry, FONT_SIZE, ui.white)
		end
	end

	-- More the Merrier: per-hit extra + its extra cleave damage (like Enhanced Power).
	local mtm_total = mtm_boost.total_dmg + (mtm_boost.extra_cleave_dmg or 0)
	local mtm_uncap = mtm_boost.total_uncapped + (mtm_boost.extra_cleave_uncapped or 0)
	row(2, "More the Merrier", mtm_total, mtm_boost.first_dmg, mtm_uncap, false)
	-- Real Total (kill-aware, per-hit only -- the extra-cleave slice has no kill model).
	ui.text(gui, string.format("%.0f", kget("mtm").real_total), x + T10M_REAL_COL, row_y(2), FONT_SIZE, ui.white)

	-- Limb Splitter: pure cleave -- its Total/Uncapped ARE the extra-cleave damage,
	-- First has no meaning for cleave. Dashed while actually equipped (the real sweep
	-- already cleaves, so there is nothing to measure against).
	do
		-- Limb Splitter, pure cleave -- Total/Uncapped are its extra-cleave damage,
		-- First has no meaning for cleave.
		--   * EQUIPPED: measure the real sweep's own extra cleave (units the boosted
		--     sweep reached beyond the no-boost baseline mass) at their real damage.
		--   * NOT equipped + Force cleave ON: the extra units physically landed, use the
		--     measured extra-cleave damage.
		--   * NOT equipped + Force cleave OFF: extra units were only counted, so
		--     estimate their damage as extra_units x the run's average cleave-hit damage.
		local forced_cleave = mod:get("force_ep")
		local ls_total, ls_uncap
		if ls_equipped or forced_cleave then
			ls_total = ls_boost.extra_cleave_dmg or 0
			ls_uncap = ls_boost.extra_cleave_uncapped or 0
		else
			local n = ls_boost.extra_units_hit or 0
			local avg = ls_est_count > 0 and (ls_est_sum / ls_est_count) or 0
			local avg_u = ls_est_count > 0 and (ls_est_uncap_sum / ls_est_count) or 0
			ls_total = n * avg
			ls_uncap = n * avg_u
		end
		local ls_ry = row_y(3)
		ui.text(gui, "Limb Splitter", x, ls_ry, FONT_SIZE, ui.white)
		ui.text(gui, string.format("%.0f", ls_total), x + T10M_TOTAL_COL, ls_ry, FONT_SIZE, ui.white)
		ui.text(gui, "-", x + T10M_FIRST_COL, ls_ry, FONT_SIZE, ui.white)
		ui.text(gui, string.format("%.0f", ls_uncap), x + T10M_UNCAP_COL, ls_ry, FONT_SIZE, ui.white)
		-- Pure cleave (no per-hit kill model of its own), so no Real Total.
		ui.text(gui, "-", x + T10M_REAL_COL, ls_ry, FONT_SIZE, ui.white)
	end

	-- Helborg's Tutelage: net crit damage (may be negative). Dashed while equipped.
	-- Primary column is the current mode's variant; the cross column shows the other.
	-- TB variant keeps random crits (no suppression), so it reads >= Official.
	local hb_primary = tb and helborg_tb or helborg
	local hb_cross   = tb and helborg or helborg_tb
	local hb_ry = row_y(4)
	if hb_equipped then
		row(4, "Helborgs Tutelage", 0, 0, 0, true)
		ui.text(gui, "-", x + T10M_CROSS_COL, hb_ry, FONT_SIZE, ui.white)
		ui.text(gui, "-", x + T10M_REAL_COL, hb_ry, FONT_SIZE, ui.white)
	else
		row(4, "Helborgs Tutelage", hb_primary.total_dmg, hb_primary.first_dmg, hb_primary.total_uncapped, false)
		ui.text(gui, string.format("%.0f", hb_cross.total_dmg), x + T10M_CROSS_COL, hb_ry, FONT_SIZE, ui.white)
		-- Real Total uses the current mode's variant (TB keeps random crits -> its own
		-- kill record, tracked separately from Official).
		ui.text(gui, string.format("%.0f", kget(tb and "helborg_tb" or "helborg").real_total),
			x + T10M_REAL_COL, hb_ry, FONT_SIZE, ui.white)
	end

	-- Cleave summary: extra units the higher cleave power reached (measured when the
	-- Force cleave button is on, otherwise an estimate).
	local forced = mod:get("force_ep")
	local est = forced and "" or " (est)"
	-- Limb Splitter is measured (not estimated) while equipped, too.
	local ls_est = (forced or ls_equipped) and "" or " (est)"
	ui.text(gui, string.format("More the Merrier cleave: +%d units%s   |   Limb Splitter: +%d units%s",
		mtm_boost.extra_units_hit or 0, est, ls_boost.extra_units_hit or 0, ls_est),
		x, row_y(5), small, ui.grey)

	ui.text(gui, "Host-only (More the Merrier reads nearby enemies server-side).",
		x, row_y(6), small, ui.grey)
end

return M
