-- level15_talents.lua
-- ============================================================================
-- Talent group: Level-15 damage talents.
--
-- Shows, per talent, the EXTRA damage it would have added this run vs. running
-- no level-15 talent -- as a RUNNING DAMAGE TOTAL (never DPS):
--     Total    : extra damage across all targets, with OVERKILL removed -- the
--                portion of each hit's extra that lands while the unit still has
--                HP (if a talent would add 100 but the unit only had 10 HP left
--                over the no-talent hit, only 10 counts). Includes EP's extra
--                cleave units and the ally damage from your Bulwark aura.
--     First    : the same overkill-accounted extra, first unit only (idx 1).
--     Uncapped : Total without overkill removal (the raw hypothetical extra).
--
-- Overkill model (per hit): each hypothetical talent replaces "no level-15
-- talent", so its damage is base_no_talent + extra. Against the unit's real
-- pre-hit health H, the useful part of `extra` is
--     min(base_no_talent + extra, H) - min(base_no_talent, H)
-- clamped to [0, extra]. H is read from the target's health_system extension in
-- the calculate_damage hook (a prediction that runs before add_damage), so it is
-- the unit's HP before this hit landed -- a proxy for the hypothetical world's HP.
--
-- Talents (the L15 row offers 3 options; the player picks exactly ONE -- two career
-- stagger talents, or Enhanced Power, which is always one of the three choices):
--   Smiter / Mainstay / Assassin -- pure stagger-number talents. Derived by
--     inverting each real hit back to its base damage, then re-applying the
--     talent's stagger-number rule. (See account_hit.)
--   Bulwark (tank_unbalance) -- its stagger-damage clause is the SAME base
--     scaling everyone gets (not a stagger-number perk), so its only delta vs.
--     no talent is its aura: enemies YOU stagger get +0.10 unbalanced_damage_taken
--     for 2s. That stat is a stacking_bonus (no multiplier), so calculate_damage
--     adds +0.10 FLAT to the stagger bonus term -> per-hit delta = base_damage*0.10
--     (NOT 10% of the whole hit; the tooltip's "10% more melee damage" is loose).
--     Self only -- allies benefiting from the same debuff are not modeled.
--   Enhanced Power -- +7.5% total power level. Extra damage from ALL sources
--     (melee, ranged, DoTs) via re-running calculate_damage with the buff's
--     x1.075 injected on the SCALED power (apply_buffs_to_power_level hook),
--     matching where the real power_level stat buff applies.
--     A "Force Enhanced Power" setting additionally makes real extra cleave
--     happen so we can count the extra units hit and the damage dealt to them.
--
-- Game mechanics (scripts/helpers/damage_utils.lua, calculate_damage ~line 525
-- and apply_buffs_to_stagger_damage ~line 392):
--   final = base * (min_coeff + S * stagger_damage_multiplier), where S (0..2)
--   is the target's stagger number and the bonus term is scaled by the target's
--   `unbalanced_damage_taken`. The stagger-number perks modify S BEFORE that:
--     smiter_stagger_damage   : first target (idx<=1) -> S = max(1, S)
--     linesman_stagger_damage : S>0 -> S + 1              (Mainstay)
--     finesse_stagger_damage  : crit OR head/neck -> S=2  (Assassin)
-- The base stagger-damage scaling applies to EVERYONE regardless of talent, so
-- "no level-15 talent" is the S=base_sn case -- our comparison baseline.
--
-- NOTE (host vs client): calculate_damage / ActionSweep run for the local owner
-- on the host. On a pure client some own hits resolve server-side, so this panel
-- is most accurate when you are the host.
-- ============================================================================

local M = {}

local mod   -- set in init()
local ui    -- shared ui_panel, set in init()

-- Debug logging: per-hit inputs + per-talent outputs so the stagger-number
-- model / EP recompute can be verified by hand. Flip DBG off to silence.
local DBG = false
local function dlog(fmt, ...)
	if DBG and mod then
		local ok, s = pcall(string.format, "[TCM] " .. fmt, ...)
		if not ok then s = "[TCM] (log format error) " .. fmt end
		-- mod:echo re-runs string.format on its argument, so literal % must be
		-- re-escaped or VMF crashes on e.g. "dec%:".
		mod:echo((s:gsub("%%", "%%%%")))
	end
end

-- ---------------------------------------------------------------------------
-- Tourney Balance awareness. When the TB mod is loaded+enabled the game is
-- already applying TB's reworked level-15 talents, so every value this panel
-- shows must switch to TB's numbers (single reality column -- unlike the THP
-- panel there is no cross-mod estimate here, since the stagger number S we read
-- off the target blackboard is the loaded mod's real S). TB's changes
-- (scripts/mods/TourneyBalance/changes/thp_stagger_changes.lua):
--   * Mainstay (linesman_unbalance) -- RE-ADDED in TB v37 with a NEW mechanic: a
--     melee hit MARKS the target (rebaltourn_mainstay_stagger_mark_buff, a
--     `dummy_stagger` +1 per stack, max 2 stacks, 2s, refreshed per hit); on the
--     first 5 targets the stagger number reads base_sn + stacks (capped at 2). The
--     mark is applied AFTER the causing hit's damage, so the first hit on a target
--     gets nothing and repeated hits build toward +2 -- unlike vanilla Mainstay
--     (S>0 -> S+1 immediately). Modeled per-target via `mainstay_marks`.
--   * Assassin (finesse_unbalance) -- S=2 on head/neck ONLY; crit no longer procs.
--   * Bulwark (tank_unbalance_buff) -- bonus 0.15->0.10, duration 5s->10s (v37;
--     was 0.15/5s in the previous TB). Plus a self +10% power_level_impact (stagger
--     strength) that we do not model, mirroring vanilla Bulwark's unmodeled self buff.
--   * Enhanced Power (power_level_unbalance) -- +7.5% -> +10% power.
--   * Smiter -- unchanged.
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

local ENHANCED_POWER_POWER_BONUS    = 0.075  -- vanilla; TB uses 0.10
local ENHANCED_POWER_POWER_BONUS_TB = 0.10
local function ep_power_bonus()
	return tb_mod_active() and ENHANCED_POWER_POWER_BONUS_TB or ENHANCED_POWER_POWER_BONUS
end

-- Bulwark aura: window it lasts + flat bonus it adds to the stagger term.
local BULWARK_WINDOW           = 2.0   -- seconds the aura lasts (vanilla)
local BULWARK_WINDOW_TB         = 10.0  -- TB v37 duration (was 5s)
local BULWARK_DAMAGE_TAKEN     = 0.10  -- vanilla +0.10 flat to the stagger bonus term
local BULWARK_DAMAGE_TAKEN_TB  = 0.10  -- TB v37 bonus (was 0.15)
local function bulwark_window()       return tb_mod_active() and BULWARK_WINDOW_TB or BULWARK_WINDOW end
local function bulwark_damage_taken() return tb_mod_active() and BULWARK_DAMAGE_TAKEN_TB or BULWARK_DAMAGE_TAKEN end

-- TB v37 Mainstay: the mark buff adds +1 stagger per stack (max 2), 2s duration,
-- applied to the first 5 targets. Simulated per-target in `mainstay_marks`.
local MAINSTAY_MARK_DUR   = 2.0
local MAINSTAY_MAX_STACKS = 2
local function mainstay_is_tb() return tb_mod_active() end

-- Assassin (finesse) triggers S=2 on crit only in vanilla; TB drops the crit
-- branch (head/neck weakspot only).
local function assassin_uses_crit() return not tb_mod_active() end

-- Talent keys in display order.
local TALENTS15 = { "smiter", "mainstay", "bulwark", "assassin", "enhanced" }
-- Stagger-number talents accounted per hit (Bulwark/EP handled separately).
local STAGGER_TALENTS = { "smiter", "mainstay", "assassin" }
local TALENT15_NAMES = {
	smiter   = "Smiter",
	mainstay = "Mainstay",
	bulwark  = "Bulwark",
	assassin = "Assassin",
	enhanced = "EP",
}

-- ---------------------------------------------------------------------------
-- Running totals
-- ---------------------------------------------------------------------------
local totals   -- ACTIVE per-talent record set: points at totals_cat[cat] during
               -- crediting (set per hit) and at a merged view during draw.
local totals_cat  -- { elite=, special=, mon=, trash= }, each a full fresh_totals() set.
local F        -- unit_filter (mod._filter), set in init
-- Enhanced Power is now valued by a shared power_boost.lua instance (extra damage,
-- source split and cleave), reused by the level-20 Reikland Reaper module. Set in init.
local PowerBoost    -- the shared module (dofiled once, shared via mod._power_boost)
local enhanced_boost -- EP's power_boost instance (mult 0.075)
local bulwark_marks = {}   -- target_unit -> game-time expiry of the +10% aura
local mainstay_marks = {}  -- target_unit -> { exp, stacks } TB Mainstay stagger mark
-- calculate_damage runs 2+ times per real melee hit (a prediction in
-- ActionSweep._play_character_impact line 1289, then the actual application in
-- server_apply_hit), so melee crediting must be deduped per unit. The duplicate
-- calls land at (nearly) the same game time, so dedupe by timestamp rather than
-- per-sweep clearing -- the sweep-start hook can miss some chained attacks,
-- and a stale "seen" flag would then silently drop a whole real hit.
local SWEEP_DEDUPE_WINDOW = 0.2
local sweep_seen = {}   -- unit -> game time last credited (client fallback only)
-- HOST ONLY: window for the LOCAL player's own melee hit, opened around the real
-- server_apply_hit application (driven from the THP module's server_apply_hit hook,
-- since VMF ignores a duplicate hook from this mod). Each genuine hit -> one
-- server_apply_hit -> one credit; dual-wield weapons fire TWO sweeps (left+right)
-- at the same target, giving two server_apply_hit calls, so BOTH now count instead
-- of the second being swallowed by the time-window dedupe. `credited` skips the
-- "torso" recompute inside add_damage_network_player.
local self_ctx = nil
-- Ally-Bulwark tracking (HOST ONLY): while server_apply_hit is applying a melee
-- hit dealt by a NON-local ally (human client or bot), this holds that hit's
-- attacker/target so the calculate_damage hook can credit exactly the one real
-- damage computation (server_apply_hit -> add_damage_network_player calls
-- calculate_damage once for the real hit_zone, then again on "torso" for proc
-- data -- `credited` de-dupes so only the first, real call counts).
local ally_ctx = nil

local function new_record()
	-- total_dmg / first_dmg : overkill-accounted extra (all / first unit).
	-- total_uncapped        : the same extra WITHOUT overkill removed.
	return { total_dmg = 0, first_dmg = 0, total_uncapped = 0 }
end

local function fresh_totals()
	local t = {}
	for _, k in ipairs(TALENTS15) do
		t[k] = new_record()
	end
	-- Bulwark: the ally-only portion of its Total (extra damage allies dealt to
	-- units thanks to YOUR +10% aura). total_dmg/first_dmg include this; ally_dmg
	-- is the ally slice alone.
	t.bulwark.ally_dmg = 0
	return t
end

-- Independent record sets, one per unit category (elite / special / mon / trash).
-- (Inline literal, not F.new_cat_set: this runs at module load, before F is set.)
local function fresh_totals_cat()
	return { elite = fresh_totals(), special = fresh_totals(),
		mon = fresh_totals(), trash = fresh_totals() }
end

totals_cat = fresh_totals_cat()
totals = totals_cat.trash

-- ---------------------------------------------------------------------------
-- Earlier-kill tracking. Per talent, count units that would have died EARLIER
-- this run PURELY because of the talent's extra damage -- i.e. the talent's
-- hypothetical cumulative damage on a unit crosses that unit's death threshold
-- while the no-talent (baseline) world's cumulative damage has NOT yet. Latched
-- once per unit (a unit can only be credited an "earlier kill" once, even though
-- the mod never actually applies the damage and the real unit may live on).
--   For each tracked unit we keep, per talent, two running sums: `with` (baseline
-- + that talent's extra) and `without` (the talent's own baseline), plus a hit
-- counter. The death threshold `init` is the unit's real HP when we first credit
-- a hit on it. Kill credited when: not yet counted, with >= init, without < init.
-- `hits[talent]` at that moment feeds the average-hits-to-kill figure.
-- Each row uses its OWN baseline: the stagger talents (Smiter/Mainstay/Assassin)
-- and Bulwark compare against "no level-15 talent" (base_no_talent); EP compares
-- against reality-without-EP. So this is a per-row "how many kills did this talent
-- pull earlier than not having it" -- consistent with the panel's other columns.
-- This panel's talents that carry kill-aware columns (Early Kills / Hits/Kill / Real
-- Total). Kill / Real-Total tracking now lives in the shared kill_tracker.lua module:
-- this panel owns one tracker instance (l15_kt, created in init) holding its per-talent
-- accumulators, while the module's global batch/queue DEFERS crediting from account_hit
-- (which runs at calculate_damage time, before the hit lands) to the health-extension
-- add_damage hook, calibrating every modeled world against the REAL applied damage
-- (K = real/model -- see modules/kill_tracker.lua). Shared with the level-10/20 panels.
local KILL_TALENTS = { "smiter", "mainstay", "bulwark", "assassin", "enhanced" }
local KillTracker   -- shared module (dofiled in init, shared via mod._kill_tracker)
local l15_kt        -- this panel's tracker instance

local function game_time()
	local ok, t = pcall(function () return Managers.time:time("game") end)
	if ok and t then return t end
	return 0
end

-- Kill-column record for `talent` from the shared tracker, or an all-zero default
-- before its first credit (so draw/log never index nil).
local ZERO_KILLS = { n = 0, saved_sum = 0, saved_n = 0, hpk_sum = 0, hpk_n = 0, real_total = 0 }
local function kget(talent)
	return (l15_kt and l15_kt:get(talent)) or ZERO_KILLS
end

-- kill_track / enqueue / flush now live in the shared kill_tracker.lua module.
-- account_hit adds each talent's {without, with} pair via l15_kt:add(...) (batched by
-- the calculate_damage hook's begin_hit/commit_hit), and the add_damage hook flushes
-- them against the real applied damage via KillTracker.on_real_damage.

function M.reset()
	totals_cat = fresh_totals_cat()
	totals = totals_cat.trash
	if l15_kt then l15_kt:reset() end
	if KillTracker then KillTracker.clear_pending() end
	table.clear(bulwark_marks)
	table.clear(mainstay_marks)
	if enhanced_boost then enhanced_boost:reset() end
	table.clear(sweep_seen)
	ally_ctx = nil
	self_ctx = nil
end

-- Stale-flush any queued kill-credits whose real-damage add_damage never arrived
-- (unhooked breed, 0-damage/immune hit) at K=1 -- the raw-model fallback.
function M.update(dt)
	if KillTracker then KillTracker.update(game_time()) end
end

local function local_player_unit()
	if not Managers.player then return nil end
	local ok, player = pcall(function () return Managers.player:local_player() end)
	if not ok or not player then return nil end
	return player.player_unit
end

-- Are we the host (server)? On the host, server_apply_hit runs and is the single
-- authoritative application per genuine hit, so melee crediting can key off its
-- window (see the self_ctx path in account_hit). On a pure client it never runs,
-- so we fall back to time-window dedupe of the client-side prediction.
local function is_host()
	return (Managers.player and Managers.player.is_server) and true or false
end

-- True if `buff_ext` has any of the named buff types (equipped-talent detection;
-- the TB variants keep the same buff_type name as vanilla, but we pass both to be safe).
local function has_buff_type_any(buff_ext, ...)
	if not buff_ext then return false end
	for i = 1, select("#", ...) do
		local name = select(i, ...)
		local ok, r = pcall(function () return buff_ext:has_buff_type(name) end)
		if ok and r then return true end
	end
	return false
end

-- Is `unit` a player-controlled unit (human or bot)? Used to pick out ally
-- attackers whose hits benefit from the local player's Bulwark aura.
local function is_player_unit(unit)
	if not unit or not Managers.player then return false end
	local ok, res = pcall(function () return Managers.player:is_player_unit(unit) end)
	return ok and res or false
end

-- Target's current health (health - damage) before this hit is applied, or nil
-- if unavailable (then overkill capping is skipped -- extra counts in full).
local function unit_current_health(unit)
	local he = ScriptUnit.has_extension(unit, "health_system")
	if not he then return nil end
	local ok, h = pcall(function () return he:current_health() end)
	if ok and type(h) == "number" then return h end
	return nil
end

-- Overkill accounting: given the unit's pre-hit health H, the damage it would
-- take WITHOUT this talent (baseline), and the uncapped extra the talent adds on
-- top, return the portion of `extra` that lands while the unit still had HP.
-- H == nil (health unknown) -> no cap, the full `extra` counts.
local function useful_extra(baseline, extra, H)
	if not H then return extra end
	local lo = math.min(baseline, H)
	local hi = math.min(baseline + extra, H)
	local u = hi - lo
	if u < 0 then u = 0 end
	if u > extra then u = extra end
	return u
end

-- Decide ONCE per calculate_damage call whether this is the single authoritative
-- credit for a genuine melee hit. The game calls calculate_damage 2+ times per real
-- hit (prediction in ActionSweep._play_character_impact, the real application in
-- add_damage_network_player, plus a "torso" recompute for proc data), so those
-- duplicates must collapse to one -- BUT a dual-wield attack fires two sweeps
-- (left+right weapon) at the SAME target, and those are two real hits that must
-- BOTH count.
--   Host: server_apply_hit is the one authoritative application per genuine hit; a
--     per-target window (self_ctx) is open only inside it (opened from the THP
--     module's server_apply_hit hook). Credit the first call of that window, skip
--     the torso recompute, and ignore calls OUTSIDE any window (the client-side
--     prediction that also runs on the host). The two dual-wield sweeps arrive as
--     two separate windows -> both count.
--   Client: server_apply_hit does not run, so only the prediction is seen -> fall
--     back to time-window dedupe (dual-wield hits on one target can't be told apart
--     here, an accepted client-side limitation).
-- The decision is cached on ctx so account_hit AND the level-10/20 forwards all see
-- the same answer and the window / time-dedupe state is consumed exactly once.
local function melee_should_credit(ctx)
	if ctx._melee_credit ~= nil then return ctx._melee_credit end
	local target_unit = ctx.target_unit
	local decision
	if is_host() then
		if self_ctx and self_ctx.target == target_unit and not self_ctx.credited then
			self_ctx.credited = true
			decision = true
		else
			decision = false
		end
	else
		local now = game_time()
		local seen_t = sweep_seen[target_unit]
		if seen_t and (now - seen_t) < SWEEP_DEDUPE_WINDOW then
			decision = false
		else
			sweep_seen[target_unit] = now
			decision = true
		end
	end
	ctx._melee_credit = decision
	return decision
end

-- ---------------------------------------------------------------------------
-- Stagger-number models
-- ---------------------------------------------------------------------------

-- Hypothetical stagger number for a given talent (mirrors apply_buffs_to_stagger_damage).
local function talent_stagger_number(talent, base_sn, target_index, crit, weakspot)
	if talent == "smiter" then
		if target_index and target_index <= 1 then
			return math.max(1, base_sn)
		end
		return base_sn
	elseif talent == "mainstay" then
		if base_sn > 0 then
			return base_sn + 1
		end
		return base_sn
	elseif talent == "assassin" then
		if (crit and assassin_uses_crit()) or weakspot then
			return 2
		end
		return base_sn
	end
	-- bulwark / enhanced: no stagger-number change.
	return base_sn
end

-- Stagger number the CURRENTLY-equipped talent produced, so we can invert the
-- real hit back to its pre-stagger base damage.
local function equipped_stagger_number(buff_ext, base_sn, target_index, crit, weakspot, target_buff_ext)
	if not buff_ext then return base_sn end
	local mainstay = buff_ext:has_buff_perk("linesman_stagger_damage")
	local finesse  = buff_ext:has_buff_perk("finesse_stagger_damage")
	local smiter   = buff_ext:has_buff_perk("smiter_stagger_damage")
	if mainstay then
		-- TB v37: read the REAL dummy_stagger mark the game applied to this target
		-- (first 5 targets only), so the inversion matches the damage that landed.
		if mainstay_is_tb() then
			if target_buff_ext and target_index and target_index <= 5 then
				return math.min(target_buff_ext:apply_buffs_to_value(base_sn, "dummy_stagger"), 2)
			end
			return base_sn
		end
		-- Vanilla Mainstay: S>0 -> S+1 immediately.
		if base_sn > 0 then return base_sn + 1 end
		return base_sn
	elseif ((crit and assassin_uses_crit()) or weakspot) and finesse then
		return 2
	elseif smiter then
		if target_index and target_index <= 1 then
			return math.max(1, base_sn)
		end
		return base_sn
	end
	return base_sn
end

local function difficulty_settings()
	local ok, ds = pcall(function ()
		return Managers.state.difficulty:get_difficulty_settings()
	end)
	if ok and ds then return ds end
	return { min_stagger_damage_coefficient = 1, stagger_damage_multiplier = 0.2 }
end

-- ---------------------------------------------------------------------------
-- Per-hit accounting. `ctx` is the shared calculate_damage context (unhooked
-- `func` + every argument + the real `final`). Enhanced Power is valued through
-- the shared power_boost instance (which re-runs `func` with x1.075 on the scaled
-- power); the stagger talents + Bulwark are derived here from the stagger-number
-- model as before.
-- ---------------------------------------------------------------------------
local function account_hit(ctx)
	local attacker_unit = ctx.attacker_unit
	if attacker_unit ~= local_player_unit() then return end
	local damage_profile = ctx.damage_profile
	if not damage_profile then return end

	local target_unit = ctx.target_unit
	local hit_zone_name = ctx.hit_zone_name
	local is_critical_strike = ctx.is_critical_strike
	local target_index = ctx.target_index or 1
	local final_damage = ctx.final
	local first = target_index <= 1

	-- Pre-hit health of the target, for overkill accounting (nil -> no cap).
	local health = unit_current_health(target_unit)
	-- Sweeps still run calculate_damage on corpses they clip; those hits deal no
	-- real damage and must not be credited anywhere (they'd inflate Uncapped --
	-- corpse contacts always look like a first-target S=0 hit, i.e. a Smiter proc).
	if health and health <= 0 then
		-- Unit is dead: free its earlier-kill state (it can never be credited again).
		l15_kt:forget(target_unit)
		dlog("DEAD-SKIP unit=%s idx=%d fin=%.2f",
			tostring((AiUtils.unit_breed(target_unit) or {}).name), target_index, final_damage)
		return
	end

	-- Route all crediting for this hit into the target's unit-category record set.
	local cat = ctx.cat or F.cat_of(target_unit)
	totals = totals_cat[cat]

	-- Is THIS hit the real killing blow you landed? (health is pre-hit HP; final_damage
	-- is the real damage this hit applies.) Drives the hits-per-kill running average.
	local real_kill = (health ~= nil) and (health - final_damage <= 0) or false

	local player_buff_ext = ScriptUnit.has_extension(attacker_unit, "buff_system")

	local is_melee = not damage_profile.is_dot
		and (damage_profile.charge_value == "light_attack" or damage_profile.charge_value == "heavy_attack")

	-- Dedupe: credit each GENUINE hit exactly once (see melee_should_credit). Applies
	-- to melee AND ranged attacks -- calculate_damage runs 2+ times per real hit
	-- regardless of damage source (prediction + application), so ranged needs the
	-- same guard melee has always had. DoT ticks are excluded: they never route
	-- through server_apply_hit's self_ctx window (a separate DoT tick call path), so
	-- gating them here would silently drop every tick instead of deduping it.
	-- Shared with the level-10/20/crit forwards so all agree on which call to count.
	if not damage_profile.is_dot and not melee_should_credit(ctx) then return end

	-- Forced-cleave units: a melee hit that reached a unit ONLY because the general
	-- force-cleave button extended a power boost's cleave (classified by pre-hit
	-- cleave MASS in the _calculate_hit_mass hook). Credit it to Enhanced Power's
	-- cleave counters if it lies in EP's own band, then STOP -- it must NOT feed the
	-- stagger talents or EP's per-hit column (those measure only hits that would land
	-- without a boost). A unit reached only by a bigger boost's budget (e.g. Reaper)
	-- is skipped here and credited to that boost by its own module.
	if is_melee and PowerBoost.is_forced_extra(target_unit) then
		enhanced_boost:account_cleave_unit(target_unit, final_damage, health)
		dlog("FORCE-CLEAVE unit=%s idx=%d fin=%.2f (forced-cleave extra, stagger talents skipped)",
			tostring((AiUtils.unit_breed(target_unit) or {}).name), target_index, final_damage)
		return
	end

	-- Enhanced Power: extra damage its +7.5% power level adds, ALL sources
	-- (melee + ranged + DoT), via the shared power_boost instance (re-runs
	-- calculate_damage with x1.075 on the scaled power, respecting armour breakpoints).
	local ep_extra = enhanced_boost:account_hit(ctx, is_melee, first, health)

	-- Whether Enhanced Power is really equipped (its power is then baked into
	-- final_damage). Used to strip it from the no-L15 baseline below, and to value
	-- its Early Kills / Hits/Kill on that SAME baseline (in the melee section, melee
	-- only, so those two columns are comparable with the stagger talents).
	local ep_equipped = enhanced_boost.talent_equipped(attacker_unit)

	-- The stagger talents + Bulwark aura are melee attack properties; melee only.
	if not is_melee then
		if ep_extra > 0 then
			dlog("EP-RANGED src=%s idx=%d fin=%.2f ep+=%.2f",
				tostring(damage_profile.charge_value or (damage_profile.is_dot and "dot")),
				target_index, final_damage, ep_extra)
		end
		-- Real Total / kill-tracking still needs this ranged/DoT hit as a SHARED
		-- baseline: it reduces the enemy's HP identically in every talent's world, so
		-- without it a unit that dies (mostly) to ranged/staff never has its melee
		-- stagger extra tip it over the kill threshold -- every stagger row would read
		-- Real Total 0 for a ranged-heavy playstyle. Feed each talent the same
		-- no-L15 base with zero melee extra (EP still gets its real all-source extra),
		-- so cumulative damage tracks reality and a later melee stagger hit crosses
		-- correctly. The batch (opened by the calculate_damage hook) is flushed against
		-- the REAL applied damage by the add_damage hook, so real_kill detection works
		-- for ranged kills too.
		local ranged_base = ep_equipped and (final_damage - ep_extra) or final_damage
		for _, talent in ipairs(STAGGER_TALENTS) do
			-- Mainstay is melee-only; ranged/DoT hits feed it a zero-extra baseline
			-- (same as smiter/assassin) so cumulative damage tracks reality.
			l15_kt:add(talent, ranged_base, ranged_base)
		end
		l15_kt:add("bulwark", ranged_base, ranged_base)
		l15_kt:add("enhanced", ranged_base, ranged_base + ep_extra)
		return
	end
	local attack_type = damage_profile.charge_value

	local ds = difficulty_settings()
	local coeff = ds.min_stagger_damage_coefficient or 1
	local mult  = ds.stagger_damage_multiplier

	local no_reduction = damage_profile.no_stagger_damage_reduction_ranged
	local base_sn = 0
	local bb = rawget(_G, "BLACKBOARDS") and BLACKBOARDS[target_unit]
	if bb then
		base_sn = bb.is_climbing and 2 or math.min(bb.stagger or 0, 2)
	end
	if no_reduction then
		base_sn = math.max(1, base_sn)
	end

	local target_buff_ext = ScriptUnit.has_extension(target_unit, "buff_system")
	local weakspot = hit_zone_name == "head" or hit_zone_name == "neck"

	-- Is the EQUIPPED Bulwark aura on this target right now? The game applies its flat
	-- +unbalanced_damage_taken debuff ONLY when Bulwark is really equipped, and only on
	-- units you staggered within the window (the same mark we track). When so, the real
	-- hit's stagger bonus already carries that flat +bw_amt, so it must be stripped from
	-- the no-L15 baseline exactly like an equipped EP's boost or stagger bonus.
	local mark = bulwark_marks[target_unit]
	local bw_active = mark and mark >= game_time()
	local bw_amt = bulwark_damage_taken()
	local bulwark_equipped = has_buff_type_any(player_buff_ext, "tank_unbalance", "rebaltourn_tank_unbalance")
	local equipped_aura = (bulwark_equipped and bw_active and not no_reduction) and bw_amt or 0

	-- bonus_damage_percentage for a stagger number, incl. the target's
	-- unbalanced_damage_taken scaling (matches calculate_damage lines 549-555).
	local function bonus_for(sn)
		if not mult then return 0 end
		local b = sn * mult
		if target_buff_ext and not no_reduction then
			b = target_buff_ext:apply_buffs_to_value(b, "unbalanced_damage_taken")
		end
		return b
	end
	-- Same, but with an equipped Bulwark's own aura removed -- the stagger bonus in a
	-- world with NO level-15 talent. Used for the baseline and the stagger deltas; the
	-- real-hit inversion (denom) keeps the aura, since that is what actually landed.
	local function bonus_no_aura(sn)
		return bonus_for(sn) - equipped_aura
	end

	-- Invert the real hit: final = base * (coeff + bonus(equipped_sn)), aura included.
	local eq_sn = no_reduction and base_sn
		or equipped_stagger_number(player_buff_ext, base_sn, target_index, is_critical_strike, weakspot, target_buff_ext)
	local denom = coeff + bonus_for(eq_sn)
	if denom <= 0 then denom = 1 end
	-- Strip the EQUIPPED level-15 talent's own extra damage so the baseline is a TRUE
	-- "no level-15 talent" hit, in BOTH Official and Tourney Balance (the player always
	-- picks exactly one of the three: two stagger options or Enhanced Power). Whichever
	-- was picked, its contribution is taken out: (final - ep_extra) removes an equipped
	-- EP's boost; dividing by denom removes an equipped stagger talent's bonus; and
	-- bonus_no_aura removes an equipped Bulwark's aura. Every talent's extra then sits
	-- on the same no-L15 base, so the columns (incl. Early Kills / Hits/Kill) are
	-- directly comparable instead of being inflated by whatever is actually equipped.
	local final_no_l15 = ep_equipped and (final_damage - ep_extra) or final_damage
	local base_damage = final_no_l15 / denom

	-- "No level-15 talent" reference bonus (aura stripped) and the damage the unit takes
	-- with no level-15 talent -- the overkill baseline every talent's extra sits on top of.
	local base_bonus = bonus_no_aura(base_sn)
	local base_no_talent = base_damage * (coeff + base_bonus)

	local function credit(talent, extra)
		if extra <= 0 then return end
		local rec = totals[talent]
		local capped = useful_extra(base_no_talent, extra, health)
		rec.total_uncapped = rec.total_uncapped + extra
		rec.total_dmg = rec.total_dmg + capped
		if first then
			rec.first_dmg = rec.first_dmg + capped
		end
	end

	-- Per-talent baseline/with pairs for kill-tracking are added to the current batch
	-- (opened by the calculate_damage hook's begin_hit) via l15_kt:add, then flushed
	-- against the REAL applied damage by the add_damage hook (see kill_tracker.lua).

	-- Stagger-number talents (Smiter / Mainstay / Assassin). Mainstay's stagger
	-- model differs between vanilla (S>0 -> S+1 on THIS hit) and TB v37 (a target
	-- mark that builds +1 stagger per repeated hit, first 5 targets only). Under TB
	-- we read the PRIOR mark stacks for this hit, then bump the mark afterwards.
	local ms_stacks = 0
	if mainstay_is_tb() then
		local m = mainstay_marks[target_unit]
		ms_stacks = (m and m.exp >= game_time()) and m.stacks or 0
	end
	local extras = {}
	for _, talent in ipairs(STAGGER_TALENTS) do
		local sn
		if talent == "mainstay" and mainstay_is_tb() then
			sn = (target_index and target_index <= 5)
				and math.min(base_sn + ms_stacks, 2) or base_sn
		else
			sn = no_reduction and base_sn
				or talent_stagger_number(talent, base_sn, target_index, is_critical_strike, weakspot)
		end
		extras[talent] = base_damage * (bonus_no_aura(sn) - base_bonus)
		credit(talent, extras[talent])
		-- Earlier-kill: baseline = no-talent damage, world = baseline + this extra.
		l15_kt:add(talent, base_no_talent, base_no_talent + extras[talent])
	end

	-- TB v37 Mainstay: mark/refresh this target AFTER the hit (game applies the
	-- mark post-damage, so the causing hit uses only prior stacks). Melee direct
	-- hits only -- we are already in the melee branch and past the dedupe gate.
	if mainstay_is_tb() then
		local m = mainstay_marks[target_unit]
		if m and m.exp >= game_time() then
			m.stacks = math.min(m.stacks + 1, MAINSTAY_MAX_STACKS)
			m.exp = game_time() + MAINSTAY_MARK_DUR
		else
			mainstay_marks[target_unit] = { stacks = 1, exp = game_time() + MAINSTAY_MARK_DUR }
		end
	end

	-- Bulwark: on units the player staggered within the aura window, its aura adds
	-- a flat bonus to the target's `unbalanced_damage_taken` (a stacking_bonus, no
	-- multiplier), which in calculate_damage adds that FLAT to the stagger bonus
	-- term. So the exact per-hit delta is base_damage * bonus, independent of the
	-- stagger number. Vanilla: +0.10 for 2s; Tourney Balance: +0.15 for 5s. Self
	-- only -- allies benefiting from the same debuff are not modeled, per design.
	-- (mark / bw_active / bw_amt were computed above for the baseline aura strip.)
	local bw_extra = bw_active and (base_damage * bw_amt) or 0
	if bw_active then
		credit("bulwark", bw_extra)
	end
	-- Earlier-kill for Bulwark: accumulate every melee hit (extra 0 when the aura
	-- is down) so cumulative damage carries across hits; a kill only counts on a
	-- hit whose aura pushed cumulative past the threshold the no-aura world hadn't.
	l15_kt:add("bulwark", base_no_talent, base_no_talent + bw_extra)

	-- Enhanced Power earlier-kill on the SAME no-L15 base as the stagger talents
	-- (melee only), so its bigger per-hit boost crosses the kill threshold sooner and
	-- it reads the LOWEST Hits/Kill -- consistent with also having the most Early Kills.
	l15_kt:add("enhanced", base_no_talent, base_no_talent + ep_extra)

	-- One line per credited melee hit with every input the model used, so each
	-- talent's extra can be recomputed by hand from the log.
	local br = AiUtils.unit_breed(target_unit)
	dlog("HIT %s zone=%s idx=%d crit=%s hp=%.1f rk=%s | Sb=%s Se=%s coeff=%.2f mult=%.2f den=%.3f fin=%.2f base=%.2f bnt=%.2f | sm=%.2f ms=%.2f as=%.2f bw=%s ep=%.2f epEq=%s noRed=%s",
		tostring(br and br.name), tostring(hit_zone_name), target_index,
		tostring(is_critical_strike), health or -1, tostring(real_kill),
		tostring(base_sn), tostring(eq_sn),
		coeff, mult or 0, denom, final_damage, base_damage, base_no_talent,
		extras.smiter or 0, extras.mainstay or 0, extras.assassin or 0,
		bw_active and string.format("%.2f", base_damage * bw_amt) or "off",
		ep_extra, tostring(enhanced_boost.talent_equipped(attacker_unit)), tostring(no_reduction or false))
end

-- Bulwark, ALLY hits (HOST ONLY). An ally's melee hit on a unit the local player
-- staggered benefits from the same +10% unbalanced_damage_taken aura, so it deals
-- base_damage * 0.10 extra -- exactly as the self case, just with the ally's own
-- equipped stagger number driving the base-damage inversion. Credited to Bulwark's
-- Total/First (shared with self) AND to a dedicated ally-only counter.
--
-- Only the stagger-bonus term matters, so we invert the ally's final damage the
-- same way account_hit inverts the local player's, using the ally's stagger perks.
local function account_ally_bulwark(target_unit, attacker_unit, hit_zone_name, is_critical_strike, damage_profile, target_index, final_damage)
	if not damage_profile then return end
	local is_melee = not damage_profile.is_dot
		and (damage_profile.charge_value == "light_attack" or damage_profile.charge_value == "heavy_attack")
	if not is_melee then return end

	target_index = target_index or 1
	local mark = bulwark_marks[target_unit]
	if not (mark and mark >= game_time()) then return end

	local ds = difficulty_settings()
	local coeff = ds.min_stagger_damage_coefficient or 1
	local mult  = ds.stagger_damage_multiplier

	local no_reduction = damage_profile.no_stagger_damage_reduction_ranged
	local base_sn = 0
	local bb = rawget(_G, "BLACKBOARDS") and BLACKBOARDS[target_unit]
	if bb then
		base_sn = bb.is_climbing and 2 or math.min(bb.stagger or 0, 2)
	end
	if no_reduction then
		base_sn = math.max(1, base_sn)
	end

	local target_buff_ext = ScriptUnit.has_extension(target_unit, "buff_system")
	local attacker_buff_ext = ScriptUnit.has_extension(attacker_unit, "buff_system")
	local weakspot = hit_zone_name == "head" or hit_zone_name == "neck"

	-- Invert the ally's real hit back to its base damage: the target's current
	-- unbalanced_damage_taken (which already includes YOUR aura if Bulwark is truly
	-- equipped) is folded into the bonus term, matching calculate_damage.
	local eq_sn = no_reduction and base_sn
		or equipped_stagger_number(attacker_buff_ext, base_sn, target_index, is_critical_strike, weakspot)
	local b = eq_sn * (mult or 0)
	if target_buff_ext and not no_reduction then
		b = target_buff_ext:apply_buffs_to_value(b, "unbalanced_damage_taken")
	end
	local denom = coeff + b
	if denom <= 0 then denom = 1 end
	local base_damage = final_damage / denom

	local extra = base_damage * bulwark_damage_taken()
	if extra <= 0 then return end

	-- The ally's real final_damage already includes your +10% aura, so the no-aura
	-- baseline is final_damage - extra; overkill-cap the extra against the unit's HP.
	-- Corpse contacts (health already 0) deal no real damage -- skip entirely.
	local health = unit_current_health(target_unit)
	if health and health <= 0 then return end
	local cat = F.cat_of(target_unit)
	totals = totals_cat[cat]
	-- Earlier-kill: this ally hit's extra shares Bulwark's per-unit pool with the
	-- self hits, so an ally finishing a unit early thanks to YOUR aura counts too.
	l15_kt:track(target_unit, "bulwark", final_damage - extra, final_damage, health, nil, cat)
	local capped = useful_extra(final_damage - extra, extra, health)

	local rec = totals.bulwark
	rec.total_uncapped = rec.total_uncapped + extra
	rec.total_dmg = rec.total_dmg + capped
	rec.ally_dmg = rec.ally_dmg + capped
	if target_index <= 1 then
		rec.first_dmg = rec.first_dmg + capped
	end

	local br = AiUtils.unit_breed(target_unit)
	dlog("ALLY-BW unit=%s idx=%d Se=%s den=%.3f fin=%.2f extra=%.2f cap=%.2f",
		tostring(br and br.name), target_index, tostring(eq_sn), denom, final_damage, extra, capped)
end

-- ---------------------------------------------------------------------------
-- Per-sweep cleave accounting. Delegated to the shared power_boost module, which
-- runs ALL registered boosts (Enhanced Power here, Reikland Reaper from level 20)
-- over the same sweep: each computes its no-boost baseline and boosted cleave-mass
-- budget, and either adds a hypothetical extra-units estimate (force button OFF)
-- or extends the real sweep to its budget so the extra units are actually hit and
-- classified (force button ON). Only the local player's own melee swings count.
-- ---------------------------------------------------------------------------
local function account_sweep(self, power_level)
	local owner_unit = self.owner_unit
	if owner_unit ~= local_player_unit() then return end
	local dp = self._damage_profile
	if not dp then return end
	local attack_type = dp.charge_value
	if attack_type ~= "light_attack" and attack_type ~= "heavy_attack" then
		dlog("SWEEP skip type=%s", tostring(attack_type))
		return
	end

	local buff_ext = ScriptUnit.has_extension(owner_unit, "buff_system")
	if not buff_ext then return end

	-- New local-player melee swing: reset the per-sweep melee dedupe.
	table.clear(sweep_seen)

	local forced = PowerBoost.run_sweep(self, power_level, owner_unit, buff_ext)
	dlog("SWEEP type=%s forced=%s", tostring(attack_type), tostring(forced))
end

-- Called by the THP module's server_apply_hit hook when the player staggers a
-- unit, so Bulwark can open its +10% window on that unit.
local function on_player_stagger(target_unit, t)
	bulwark_marks[target_unit] = (t or game_time()) + bulwark_window()
end

-- ---------------------------------------------------------------------------
-- Hooks
-- ---------------------------------------------------------------------------
function M.init(owner_mod, ui_panel)
	mod = owner_mod
	ui = ui_panel
	F = mod._filter

	-- Shared power-boost engine: valued once here for Enhanced Power, and shared
	-- via mod._power_boost so the level-20 Reikland Reaper module registers its own
	-- instance with the SAME registry (the sweep/cleave hooks below drive them all).
	PowerBoost = mod:dofile("scripts/mods/TalentComparisonMod/modules/power_boost")
	mod._power_boost = PowerBoost

	-- Shared kill / Real-Total tracker: this panel owns one instance; the level-10/20
	-- panels create their own from the SAME module (mod._kill_tracker), so all share the
	-- global batch/queue that calibrates modeled worlds against the real applied damage.
	KillTracker = mod:dofile("scripts/mods/TalentComparisonMod/modules/kill_tracker")
	mod._kill_tracker = KillTracker
	l15_kt = KillTracker.new()

	-- Wire per-unit-category bucketing into the shared engines: kill_tracker merges
	-- kills by the active filter; power_boost buckets its extra-damage by target.
	KillTracker.set_filter(F.enabled)
	PowerBoost.set_category_fns(F.cat_of, F.enabled)

	enhanced_boost = PowerBoost.register(PowerBoost.new({
		mult = ep_power_bonus,   -- 0.075 vanilla / 0.10 under Tourney Balance (resolved live)
		buff_type = "power_level_unbalance",           -- "already equipped" detector
		force_enabled = function () return mod._gameplay_on("force_ep") end,  -- gameplay-gated force-cleave
	}))

	mod._on_player_stagger = on_player_stagger

	-- Shared per-genuine-hit melee decision so the level-10/20 modules dedupe exactly
	-- as this module does (fixes dual-wield weapons dropping the second sweep's hit).
	mod._l15_melee_credit = melee_should_credit

	-- Power-boost simulation point: a real "power_level" stat buff (Enhanced Power,
	-- Reikland Reaper) applies to the post-cap, post-compression power inside
	-- ActionUtils.scale_power_levels via this function. While a boost re-runs
	-- calculate_damage it sets PowerBoost.recompute_mult so the same multiplier is
	-- injected here, matching the talent exactly instead of the damped pre-scale value.
	mod:hook(ActionUtils, "apply_buffs_to_power_level", function (func, unit, power_level)
		local result = func(unit, power_level)
		if PowerBoost.recompute_mult then
			result = result * PowerBoost.recompute_mult
		end
		return result
	end)

	-- Per-hit damage accounting. Wrap calculate_damage to read the real final
	-- damage and derive each talent's hypothetical value from it.
	mod:hook(DamageUtils, "calculate_damage", function (func,
		damage_output, target_unit, attacker_unit, hit_zone_name, original_power_level,
		boost_curve, boost_damage_multiplier, is_critical_strike, damage_profile,
		target_index, backstab_multiplier, damage_source)

		local final = func(damage_output, target_unit, attacker_unit, hit_zone_name,
			original_power_level, boost_curve, boost_damage_multiplier, is_critical_strike,
			damage_profile, target_index, backstab_multiplier, damage_source)

		if type(final) == "number" and final > 0 and attacker_unit == local_player_unit() then
			-- Build the shared hit context once (the unhooked `func` + every
			-- calculate_damage argument + the real `final`). Enhanced Power values
			-- itself by re-running `func` through it (the power_boost instance toggles
			-- the x1.075 on the SCALED power via the apply_buffs_to_power_level hook,
			-- respecting armour breakpoints); the level-10/20 modules reuse the same ctx.
			local ctx = {
				func = func,
				damage_output = damage_output,
				target_unit = target_unit,
				attacker_unit = attacker_unit,
				hit_zone_name = hit_zone_name,
				original_power_level = original_power_level,
				boost_curve = boost_curve,
				boost_damage_multiplier = boost_damage_multiplier,
				is_critical_strike = is_critical_strike,
				damage_profile = damage_profile,
				target_index = target_index,
				backstab_multiplier = backstab_multiplier,
				damage_source = damage_source,
				final = final,
			}

			-- Open a kill-tracking batch for THIS genuine hit: account_hit and the
			-- level-10/20 forwards each add their per-talent {without, with} pairs to
			-- it (l15_kt:add / their own trackers), and it is committed below for a
			-- deferred flush against the real applied damage (the add_damage hook). One
			-- batch per genuine hit; duplicate/deduped calculate_damage calls add nothing
			-- and the empty batch is dropped by commit_hit.
			ctx.cat = mod._filter.cat_of(target_unit)
			KillTracker.begin_hit(target_unit, final, unit_current_health(target_unit), ctx.cat)

			pcall(account_hit, ctx)

			-- Forward the same local-player hit to the level-10 WHC module and the
			-- level-20 Mercenary module (neither can add its own calculate_damage
			-- hook -- VMF ignores a duplicate from this mod). Both recompute from the
			-- unhooked `func`, so they read every argument off ctx.
			if mod._l10_on_hit then mod._l10_on_hit(ctx) end
			if mod._l10_merc_on_hit then mod._l10_merc_on_hit(ctx) end
			if mod._l10_bw_on_hit then mod._l10_bw_on_hit(ctx) end
			if mod._l10_ws_on_hit then mod._l10_ws_on_hit(ctx) end
			if mod._l20_on_hit then mod._l20_on_hit(ctx) end
			if mod._l30_bh_on_hit then mod._l30_bh_on_hit(ctx) end
			if mod._crit_on_hit then mod._crit_on_hit(ctx) end

			KillTracker.commit_hit()
		elseif type(final) == "number" and final > 0
			and ally_ctx and not ally_ctx.credited
			and ally_ctx.attacker == attacker_unit and ally_ctx.target == target_unit then
			-- Ally Bulwark: this is the one real damage computation inside the ally's
			-- server_apply_hit. Credit once; the later "torso" recompute is skipped.
			ally_ctx.credited = true
			pcall(account_ally_bulwark, target_unit, attacker_unit, hit_zone_name,
				is_critical_strike, damage_profile, target_index, final)
		end

		-- Strike Together (level-20 Merc): forward ALLY player melee hits so the L20
		-- module can reconstruct each ally's swing stream and value the spread Paced
		-- Strikes. Host only (ally hits only run calculate_damage on the server); the
		-- handler self-gates on the Merc panel being active, so this is a cheap no-op
		-- otherwise.
		if mod._l20_on_ally_hit and type(final) == "number" and final > 0
			and attacker_unit ~= local_player_unit() and is_player_unit(attacker_unit) then
			mod._l20_on_ally_hit({
				attacker_unit = attacker_unit,
				target_unit = target_unit,
				damage_profile = damage_profile,
				target_index = target_index,
				final = final,
			})
		end

		return final
	end)

	-- Real applied damage -> deferred kill-tracking. calculate_damage's return (what
	-- account_hit models from) understates the real hit by any post-calc attacker
	-- buff (e.g. Slayer stack damage via on_damage_dealt / apply_buffs_to_damage).
	-- The health-extension add_damage runs just after, with the REAL damage, so we
	-- flush the matching queued hit here and scale its kill-tracking by K=real/model.
	-- Covers the common enemy health extensions; anything else falls back to the
	-- stale flush in M.update (K=1, i.e. the previous raw-model behaviour).
	local function on_real_damage(self, attacker_unit, damage_amount)
		if attacker_unit ~= local_player_unit() then return end
		local unit = self.unit or (self.get_unit and self:get_unit())
		if unit then KillTracker.on_real_damage(unit, damage_amount) end
	end
	for _, cls_name in ipairs({ "GenericHealthExtension", "BeastmenStandardHealthExtension" }) do
		local cls = rawget(_G, cls_name)
		if cls then
			mod:hook_safe(cls, "add_damage", function (self, attacker_unit, damage_amount)
				on_real_damage(self, attacker_unit, damage_amount)
			end)
		end
	end

	-- Ally-Bulwark context (HOST ONLY -- server_apply_hit does not run on a pure
	-- client). We cannot add a second mod:hook on DamageUtils.server_apply_hit --
	-- the THP module already hooks it, and VMF silently ignores a duplicate hook
	-- from the same mod. So the THP hook calls these open/close helpers around its
	-- own func() call instead. `open` marks the window during which an ALLY's melee
	-- hit is really applied, so the calculate_damage hook above credits exactly the
	-- one real damage computation inside it (the later "torso" recompute is skipped
	-- via `credited`). Local-player hits go through account_hit and are excluded.
	mod._l15_open_ally_ctx = function (attacker_unit, target_unit, damage_profile, blocking)
		-- Save & restore BOTH windows: the ally-Bulwark ctx and the local-player self
		-- ctx (used by account_hit's host-only per-genuine-hit crediting).
		local prev = { ally = ally_ctx, self = self_ctx }
		local is_melee = damage_profile
			and (damage_profile.charge_value == "light_attack" or damage_profile.charge_value == "heavy_attack")
		-- Local-player window: opened for ANY real hit (melee or ranged) -- server_apply_hit
		-- is one call per genuine hit regardless of damage source, and calculate_damage
		-- runs multiple times (prediction + application) for ranged too, so ranged
		-- crediting needs the same dedupe melee already had (was previously melee-only,
		-- which let every ranged hit be counted 2-3x, e.g. inflating Headshot Rate).
		if not blocking and attacker_unit == local_player_unit() then
			self_ctx = { target = target_unit, credited = false }
		elseif not blocking and is_melee and is_player_unit(attacker_unit) then
			-- Ally-Bulwark window stays melee only -- the aura only benefits melee hits.
			ally_ctx = { attacker = attacker_unit, target = target_unit, credited = false }
		end
		return prev
	end
	mod._l15_close_ally_ctx = function (prev)
		if prev then
			ally_ctx = prev.ally
			self_ctx = prev.self
		end
	end

	-- Power-boost cleave accounting, per melee swing start (Enhanced Power + any
	-- other registered boost, e.g. Reikland Reaper).
	mod:hook_safe(ActionSweep, "client_owner_start_action", function (self, new_action, t, chain_action_data, power_level)
		local ok, err = pcall(account_sweep, self, power_level)
		if not ok then dlog("SWEEP ERROR %s", tostring(err)) end
		-- Forward each melee swing start to the level-20 module (shared hook; it uses
		-- swing boundaries to aggregate per-swing damage for the attack-speed sim).
		if mod._l20_on_swing_start then mod._l20_on_swing_start(self, power_level) end
		if mod._l10_ws_on_swing_start then mod._l10_ws_on_swing_start(self) end
		-- Forward to the crit tracker: self._is_critical_strike is already set by the
		-- unhooked func by the time this hook_safe callback runs, so it can count this
		-- swing attempt (hit or not) as a melee crit roll.
		if mod._crit_on_melee_swing then mod._crit_on_melee_swing(self) end
	end)

	-- Forced-cleave extra-unit classification. _calculate_hit_mass runs exactly once
	-- per enemy per sweep (units are deduped via _hit_units) and holds the real
	-- pre-hit mass: the game DAMAGES a target iff _amount_of_mass_hit BEFORE the
	-- target's own mass is added is <= _max_targets_attack (action_sweep.lua:510).
	-- NOTE the sweep keeps HITTING units well past the attack budget (it stops at
	-- _max_targets = max(attack, impact), line 965) -- those extra units are
	-- staggered but damaged at power 0 (server_apply_hit line 3678). They are hit
	-- with or without a boost, so they are NOT "cleaved because of it".
	--
	-- Each registered boost classifies units in its OWN band (base < mass_before <=
	-- that boost's budget); PowerBoost.run_classify does this for all of them.
	mod:hook(ActionSweep, "_calculate_hit_mass", function (func, self, difficulty_rank, actual_hit_target_index, shield_blocked, current_action, breed, hit_unit_id, hit_unit)
		PowerBoost.run_classify(self, hit_unit)
		return func(self, difficulty_rank, actual_hit_target_index, shield_blocked, current_action, breed, hit_unit_id, hit_unit)
	end)
end

-- ---------------------------------------------------------------------------
-- Display
-- ---------------------------------------------------------------------------
-- Column x-offsets shared with the Level 10 panel so the two line up visually
-- (and the Total column lines up with the Temp Health panel's first column).
local T15_TOTAL_COL = 150
local T15_FIRST_COL = 230
local T15_UNCAP_COL = 320
local T15_KILLS_COL = 430   -- units this talent would have killed EARLIER
local T15_HPK_COL   = 520   -- average hits-to-kill in that talent's world
local T15_REAL_COL  = 610   -- extra damage that actually pulled kills sooner
local PANEL_W_T15   = 740

-- Whether the extra breakdown lines (Bulwark ally / EP sources / EP cleave) are
-- shown; toggled by the panel's "Details" button. Defaults on.
local function extra_shown()
	local v = mod:get("show_l15_extra")
	if v == nil then return true end
	return v
end

function M.wants_display()
	return true
end

-- Full snapshot of every displayed value; called by reset_all just before the
-- totals are cleared (Reset button, keybind, and mission-entry reset).
function M.log_state()
	if not DBG then return end
	local totals = F.merge_sets(totals_cat)
	local ep = enhanced_boost
	dlog("L15 SNAP total/first (uncap): sm=%.1f/%.1f (%.1f) ms=%.1f/%.1f (%.1f) bw=%.1f/%.1f (%.1f, ally %.1f) as=%.1f/%.1f (%.1f) ep=%.1f/%.1f (%.1f) | ep cleave +%d units +%.1f dmg (uncap %.1f)",
		totals.smiter.total_dmg, totals.smiter.first_dmg, totals.smiter.total_uncapped,
		totals.mainstay.total_dmg, totals.mainstay.first_dmg, totals.mainstay.total_uncapped,
		totals.bulwark.total_dmg, totals.bulwark.first_dmg, totals.bulwark.total_uncapped, totals.bulwark.ally_dmg or 0,
		totals.assassin.total_dmg, totals.assassin.first_dmg, totals.assassin.total_uncapped,
		ep:rd("total_dmg"), ep:rd("first_dmg"), ep:rd("total_uncapped"),
		ep:units_hit(), ep:rd("extra_cleave_dmg"), ep:rd("extra_cleave_uncapped"))
	dlog("L15 SNAP ep sources (capped): melee=%.1f ranged=%.1f other=%.1f",
		ep:rd("src_melee"), ep:rd("src_ranged"), ep:rd("src_other"))
	local function hpk(t) local k = kget(t) return k.hpk_n > 0 and k.hpk_sum / k.hpk_n or 0 end
	dlog("L15 SNAP early kills (n) / hits-per-kill / real-total: sm=%d/%.1f/%.0f ms=%d/%.1f/%.0f bw=%d/%.1f/%.0f as=%d/%.1f/%.0f ep=%d/%.1f/%.0f",
		kget("smiter").n, hpk("smiter"), kget("smiter").real_total,
		kget("mainstay").n, hpk("mainstay"), kget("mainstay").real_total,
		kget("bulwark").n, hpk("bulwark"), kget("bulwark").real_total,
		kget("assassin").n, hpk("assassin"), kget("assassin").real_total,
		kget("enhanced").n, hpk("enhanced"), kget("enhanced").real_total)
end

-- Reset just this group (its panel's Reset button), snapshotting first.
function M.reset_self()
	if M.log_state then pcall(M.log_state) end
	M.reset()
end

function M.draw(gui)
	local FONT_SIZE = ui.FONT_SIZE
	local small = FONT_SIZE - 6

	-- Merge the category record sets the current filter selects into one read view.
	local totals = F.merge_sets(totals_cat)

	local show_extra = extra_shown()
	local tb = tb_mod_active()

	-- Displayed talents: all five in both modes (TB v37 re-added Mainstay).
	local disp = {}
	for _, t in ipairs(TALENTS15) do
		disp[#disp + 1] = t
	end
	local n = #disp

	-- rows: title (0) + "Extra Damage" header (1) + n talents (2..n+1). With details
	-- on, three more breakdown lines follow. content_rows = the last used row, so
	-- the Reset button sits directly beneath with no dead space.
	local content_rows = show_extra and (n + 4) or (n + 1)
	local x, top, row_y, collapsed, title_visible = ui.frame(gui, PANEL_W_T15, content_rows, "l15_pos_x", "l15_pos_y", 0.03, 0.95, "l15", M.reset_self,
		{
			extra_btn = {
				label = show_extra and "Hide Details" or "Show Details",
				on_click = function () mod:set("show_l15_extra", not show_extra) end,
			},
		})
	if not x then return end

	if title_visible then
		-- Flag the unequipped-row mode in the title: every column is then a true
		-- hypothetical over the same no-talent baseline.
		local title = tb and "Stagger Talents (TB):" or "Stagger Talents:"
		if mod._gameplay_live and mod._gameplay_live.unequip_l15 then
			title = title .. "  [row unequipped]"
		end
		ui.text_bold(gui, title, x, row_y(0), FONT_SIZE, ui.yellow)
	end
	if collapsed then return end

	ui.text(gui, "Extra Damage:", x, row_y(1), small, ui.grey)
	ui.text(gui, "Total", x + T15_TOTAL_COL, row_y(1), small, ui.grey)
	ui.text(gui, "First Unit", x + T15_FIRST_COL, row_y(1), small, ui.grey)
	ui.text(gui, "Uncapped", x + T15_UNCAP_COL, row_y(1), small, ui.grey)
	ui.text(gui, "Early Kills", x + T15_KILLS_COL, row_y(1), small, ui.grey)
	ui.text(gui, "Hits Saved", x + T15_HPK_COL, row_y(1), small, ui.grey)
	ui.text(gui, "Real Total", x + T15_REAL_COL, row_y(1), small, ui.grey)

	for i, talent in ipairs(disp) do
		local ry = row_y(i + 1)
		ui.text(gui, TALENT15_NAMES[talent], x, ry, FONT_SIZE, ui.white)
		-- EP is valued by the shared power_boost instance; its Total/Uncapped include
		-- its extra cleave damage (overkill-accounted for Total, raw for Uncapped).
		-- The stagger talents come from `totals` and have no cleave component.
		local total, first, uncapped
		if talent == "enhanced" then
			total = enhanced_boost:rd("total_dmg") + enhanced_boost:rd("extra_cleave_dmg")
			first = enhanced_boost:rd("first_dmg")
			uncapped = enhanced_boost:rd("total_uncapped") + enhanced_boost:rd("extra_cleave_uncapped")
		else
			local rec = totals[talent]
			total, first, uncapped = rec.total_dmg, rec.first_dmg, rec.total_uncapped
		end
		ui.text(gui, string.format("%.0f", total), x + T15_TOTAL_COL, ry, FONT_SIZE, ui.white)
		ui.text(gui, string.format("%.0f", first), x + T15_FIRST_COL, ry, FONT_SIZE, ui.white)
		ui.text(gui, string.format("%.0f", uncapped), x + T15_UNCAP_COL, ry, FONT_SIZE, ui.white)

		-- Early Kills = units this talent finished sooner; Hits Saved = average hits
		-- fewer to kill (real hits minus the talent's kill hit), over EVERY unit you
		-- killed -- 0.00 for a talent that never pulls a kill sooner (see kill_tracker).
		local k = kget(talent)
		ui.text(gui, string.format("%d", k.n), x + T15_KILLS_COL, ry, FONT_SIZE, ui.white)
		ui.text(gui, k.saved_n > 0 and string.format("%.2f", k.saved_sum / k.saved_n) or "-",
			x + T15_HPK_COL, ry, FONT_SIZE, ui.white)
		-- Real Total: extra damage that actually pulled kills sooner (kill-aware,
		-- baseline-overkill discounted -- see kill_track).
		ui.text(gui, string.format("%.0f", k.real_total), x + T15_REAL_COL, ry, FONT_SIZE, ui.white)
	end

	if not show_extra then return end

	-- Bulwark ally-extra summary: the slice of Bulwark's Total that allies dealt
	-- thanks to YOUR +10% aura (host only; stays 0 as a pure client).
	ui.text(gui, string.format("Bulwark ally extra: +%.0f dmg (of Total)", totals.bulwark.ally_dmg or 0),
		x, row_y(n + 2), small, ui.grey)

	-- Enhanced Power extra damage by source (overkill-accounted; sums to EP Total
	-- minus the extra-cleave slice below).
	local ep = enhanced_boost
	ui.text(gui, string.format("EP sources: Melee +%.0f  Ranged +%.0f  Other +%.0f dmg",
		ep:rd("src_melee"), ep:rd("src_ranged"), ep:rd("src_other")),
		x, row_y(n + 3), small, ui.grey)

	-- Enhanced Power extra-cleave summary.
	local ep_line
	if mod._gameplay_on("force_ep") then
		ep_line = string.format("EP cleave: +%d units, +%.0f dmg  (without +cleave: %.0f)",
			ep:units_hit(), ep:rd("extra_cleave_dmg"), ep:rd("total_dmg"))
	else
		ep_line = string.format("EP cleave (est): +%d units  (without +cleave: %.0f)",
			ep:units_hit(), ep:rd("total_dmg"))
	end
	ui.text(gui, ep_line, x, row_y(n + 4), small, ui.grey)
end

return M
