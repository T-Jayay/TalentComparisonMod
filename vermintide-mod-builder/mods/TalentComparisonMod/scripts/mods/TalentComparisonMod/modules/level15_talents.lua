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
--   * Mainstay REMOVED  -- no TB career can equip it, so the row is hidden.
--   * Assassin (finesse_unbalance) -- S=2 on head/neck ONLY; crit no longer procs.
--   * Bulwark (tank_unbalance_buff) -- bonus 0.10->0.15, duration 2s->5s.
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
local BULWARK_WINDOW_TB        = 5.0   -- TB duration
local BULWARK_DAMAGE_TAKEN     = 0.10  -- vanilla +0.10 flat to the stagger bonus term
local BULWARK_DAMAGE_TAKEN_TB  = 0.15  -- TB bonus
local function bulwark_window()       return tb_mod_active() and BULWARK_WINDOW_TB or BULWARK_WINDOW end
local function bulwark_damage_taken() return tb_mod_active() and BULWARK_DAMAGE_TAKEN_TB or BULWARK_DAMAGE_TAKEN end

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
local totals   -- per-talent { total_dmg, first_dmg } for the stagger talents
-- Enhanced Power is now valued by a shared power_boost.lua instance (extra damage,
-- source split and cleave), reused by the level-20 Reikland Reaper module. Set in init.
local PowerBoost    -- the shared module (dofiled once, shared via mod._power_boost)
local enhanced_boost -- EP's power_boost instance (mult 0.075)
local bulwark_marks = {}   -- target_unit -> game-time expiry of the +10% aura
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

totals = fresh_totals()

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
local KILL_TALENTS = { "smiter", "mainstay", "bulwark", "assassin", "enhanced" }
-- talent -> { n = <earlier kills>, hpk_sum, hpk_n = running hits-per-kill }
local kills
local unit_state   -- target_unit -> per-unit accumulators (see kill_track)
-- Kill-tracking is DEFERRED from account_hit (which runs at calculate_damage time,
-- BEFORE the hit is applied) to the health-extension add_damage hook, where the
-- REAL applied damage is known. calculate_damage's return understates the real hit
-- by any post-calc attacker buff (e.g. Slayer's stack damage via on_damage_dealt /
-- apply_buffs_to_damage) -- a talent-independent factor K = real/model. Scaling
-- every hypothetical world by K makes the kill-threshold crossing match reality, so
-- a hit that really one-shot an enemy no longer looks like a talent-provided early
-- kill. pending_credit[target] is a FIFO of hits awaiting their real damage.
local pending_credit = {}
local PENDING_STALE = 0.5   -- s; flush unmatched hits (K=1) if no add_damage arrives

local function game_time()
	local ok, t = pcall(function () return Managers.time:time("game") end)
	if ok and t then return t end
	return 0
end

local function fresh_kills()
	local k = {}
	for _, t in ipairs(KILL_TALENTS) do k[t] = { n = 0, hpk_sum = 0, hpk_n = 0, real_total = 0 } end
	return k
end

kills = fresh_kills()
unit_state = {}

-- Accumulate one hit's damage for `talent` on `target_unit`. Does two things:
--  1. EARLY KILL: if this hit is the one that pulls the kill earlier than the
--     no-talent world (talent cumulative >= threshold while baseline still below),
--     credit an earlier kill and FREEZE the talent's hits-to-kill for this unit.
--  2. HITS/KILL: when this is YOUR real killing blow on the unit (`real_kill`),
--     record hits-to-kill for the running average -- the unit's real hits to die,
--     but capped at the talent's frozen early-kill hit if the talent would have
--     finished it sooner (so once the talent kills it early we stop counting the
--     extra real hits it kept taking). Latched once per unit per talent.
--   without_add : damage this hit deals in the talent's BASELINE world.
--   with_add    : damage this hit deals in the talent's world (baseline + extra).
--   health      : the target's real pre-hit HP (nil -> skip the crossing check,
--                 threshold unknown, but keep accumulating for later hits).
--   real_kill   : true if THIS hit is the real killing blow you landed on the unit.
local function kill_track(target_unit, talent, without_add, with_add, health, real_kill)
	local st = unit_state[target_unit]
	if not st then
		st = { init = health, with = {}, without = {}, counted = {}, hits = {},
			frozen = {}, real_counted = {} }
		unit_state[target_unit] = st
	end
	if not st.init and health then st.init = health end
	local h = (st.hits[talent] or 0) + 1
	st.hits[talent] = h
	local w  = (st.with[talent] or 0) + with_add
	local wo = (st.without[talent] or 0) + without_add
	st.with[talent], st.without[talent] = w, wo
	-- Talent-world kill: the hit at which this talent's cumulative damage would have
	-- finished the unit. Recorded for EVERY unit the talent would kill (`with` crosses
	-- the threshold), latched once -- this is the hits-to-kill in the talent's world,
	-- always <= the real hits. If, additionally, the no-talent world had NOT yet
	-- crossed on this hit (`without < init`), the talent pulled the kill a full hit
	-- earlier -> count an Early Kill.
	if not st.counted[talent] and st.init and w >= st.init then
		st.counted[talent] = true
		st.frozen[talent] = h
		if wo < st.init then
			kills[talent].n = kills[talent].n + 1
			dlog("EARLYKILL %s unit=%s hit=%d init=%.2f | with=%.2f (this+%.2f) without=%.2f (this+%.2f)",
				talent, tostring((AiUtils.unit_breed(target_unit) or {}).name), h, st.init,
				w, with_add, wo, without_add)
		end
		-- REAL TOTAL: of the extra damage banked into this unit, how much actually
		-- contributed to killing it sooner. At the talent-world killing hit K, the
		-- extra banked over hits 1..K-1 is (with_{K-1} - without_{K-1}); the killing
		-- hit's own extra is discarded (the unit dies on this hit regardless). If the
		-- baseline damage alone OVERKILLS the talent-world remaining HP on hit K, that
		-- overkill margin means some of the banked extra was unnecessary and is
		-- subtracted. Clamped to >= 0. (See the two worked examples in the header.)
		local prev_with    = w - with_add          -- with_{K-1}
		local prev_without = wo - without_add       -- without_{K-1}
		local e_before     = prev_with - prev_without
		local remaining    = st.init - prev_with    -- talent-world HP before killing hit
		local overkill     = without_add - remaining
		if overkill < 0 then overkill = 0 end
		local real = e_before - overkill
		if real > 0 then
			kills[talent].real_total = kills[talent].real_total + real
		end
	end
	if real_kill and not st.real_counted[talent] then
		st.real_counted[talent] = true
		-- Hits to kill in this talent's world (frozen when the talent would have
		-- finished it); fall back to real hits if the talent never reached the kill.
		local sample = st.frozen[talent] or h
		local k = kills[talent]
		k.hpk_sum = k.hpk_sum + sample
		k.hpk_n   = k.hpk_n + 1
	end
end

-- Enqueue one credited melee hit's per-talent baseline/with pairs so kill-tracking
-- can be run later against the REAL applied damage. `entries` is a list of
-- { talent, without, with } (the UNSCALED model damages); `model_final` is the
-- calculate_damage return used to derive the scale factor K = real/model_final.
local function enqueue_kill_credit(target_unit, model_final, health, entries)
	local q = pending_credit[target_unit]
	if not q then q = {}; pending_credit[target_unit] = q end
	q[#q + 1] = { model_final = model_final, health = health, entries = entries,
		t = game_time() }
end

-- Run kill-tracking for the oldest pending hit on `target_unit`, scaling every
-- modeled damage by K = real_damage / model_final (talent-independent) so the
-- kill-threshold crossing matches what actually happened in-game. real_damage nil
-- (stale flush) -> K = 1, i.e. fall back to the raw model.
local function flush_kill_credit(target_unit, real_damage)
	local q = pending_credit[target_unit]
	if not q or #q == 0 then return false end
	local rec = table.remove(q, 1)
	if #q == 0 then pending_credit[target_unit] = nil end
	local K = 1
	if real_damage and rec.model_final and rec.model_final > 0 then
		K = real_damage / rec.model_final
	end
	local real_kill = rec.health and real_damage and (rec.health - real_damage <= 0) or false
	for _, e in ipairs(rec.entries) do
		kill_track(target_unit, e.talent, e.without * K, e["with"] * K, rec.health, real_kill)
	end
	dlog("FLUSH unit=%s real=%s model=%.2f K=%.3f rk=%s",
		tostring((AiUtils.unit_breed(target_unit) or {}).name),
		tostring(real_damage), rec.model_final or -1, K, tostring(real_kill))
	return true
end

function M.reset()
	totals = fresh_totals()
	kills = fresh_kills()
	table.clear(unit_state)
	table.clear(bulwark_marks)
	table.clear(pending_credit)
	if enhanced_boost then enhanced_boost:reset() end
	table.clear(sweep_seen)
	ally_ctx = nil
	self_ctx = nil
end

-- Flush any queued kill-credits whose real-damage add_damage never arrived (enemy
-- uses a health extension we don't hook, hit dealt no damage, etc.). These flush at
-- K=1 -- the previous raw-model behaviour -- so no hit is ever silently dropped.
function M.update(dt)
	if not next(pending_credit) then return end
	local now = game_time()
	for target, q in pairs(pending_credit) do
		while q[1] and (now - q[1].t) >= PENDING_STALE do
			flush_kill_credit(target, nil)
			if pending_credit[target] ~= q then break end
		end
	end
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
local function equipped_stagger_number(buff_ext, base_sn, target_index, crit, weakspot)
	if not buff_ext then return base_sn end
	local mainstay = buff_ext:has_buff_perk("linesman_stagger_damage")
	local finesse  = buff_ext:has_buff_perk("finesse_stagger_damage")
	local smiter   = buff_ext:has_buff_perk("smiter_stagger_damage")
	if mainstay and base_sn > 0 then
		return base_sn + 1
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
		unit_state[target_unit] = nil
		dlog("DEAD-SKIP unit=%s idx=%d fin=%.2f",
			tostring((AiUtils.unit_breed(target_unit) or {}).name), target_index, final_damage)
		return
	end

	-- Is THIS hit the real killing blow you landed? (health is pre-hit HP; final_damage
	-- is the real damage this hit applies.) Drives the hits-per-kill running average.
	local real_kill = (health ~= nil) and (health - final_damage <= 0) or false

	local player_buff_ext = ScriptUnit.has_extension(attacker_unit, "buff_system")

	local is_melee = not damage_profile.is_dot
		and (damage_profile.charge_value == "light_attack" or damage_profile.charge_value == "heavy_attack")

	-- Melee dedupe: credit each GENUINE hit exactly once (see melee_should_credit).
	-- Shared with the level-10/20 forwards so all three agree on which call to count.
	if is_melee and not melee_should_credit(ctx) then return end

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
		or equipped_stagger_number(player_buff_ext, base_sn, target_index, is_critical_strike, weakspot)
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

	-- Per-talent baseline/with pairs for kill-tracking, collected here and enqueued
	-- for a DEFERRED flush against the real applied damage (see enqueue_kill_credit).
	local kt_entries = {}

	-- Stagger-number talents (Smiter / Mainstay / Assassin). TB removed Mainstay,
	-- so it credits nothing while the TB mod is loaded (its row is hidden too).
	local skip_mainstay = tb_mod_active()
	local extras = {}
	for _, talent in ipairs(STAGGER_TALENTS) do
		if not (talent == "mainstay" and skip_mainstay) then
		local sn = no_reduction and base_sn
			or talent_stagger_number(talent, base_sn, target_index, is_critical_strike, weakspot)
		extras[talent] = base_damage * (bonus_no_aura(sn) - base_bonus)
		credit(talent, extras[talent])
		-- Earlier-kill: baseline = no-talent damage, world = baseline + this extra.
		kt_entries[#kt_entries + 1] = { talent = talent, without = base_no_talent,
			["with"] = base_no_talent + extras[talent] }
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
	kt_entries[#kt_entries + 1] = { talent = "bulwark", without = base_no_talent,
		["with"] = base_no_talent + bw_extra }

	-- Enhanced Power earlier-kill on the SAME no-L15 base as the stagger talents
	-- (melee only), so its bigger per-hit boost crosses the kill threshold sooner and
	-- it reads the LOWEST Hits/Kill -- consistent with also having the most Early Kills.
	kt_entries[#kt_entries + 1] = { talent = "enhanced", without = base_no_talent,
		["with"] = base_no_talent + ep_extra }

	-- Enqueue the collected pairs for a deferred flush against the real applied
	-- damage (the health-extension add_damage hook), so the kill-threshold crossing
	-- uses reality, not the post-calc-buff-understated calculate_damage return.
	enqueue_kill_credit(target_unit, final_damage, health, kt_entries)

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
	-- Earlier-kill: this ally hit's extra shares Bulwark's per-unit pool with the
	-- self hits, so an ally finishing a unit early thanks to YOUR aura counts too.
	kill_track(target_unit, "bulwark", final_damage - extra, final_damage, health)
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

	-- Shared power-boost engine: valued once here for Enhanced Power, and shared
	-- via mod._power_boost so the level-20 Reikland Reaper module registers its own
	-- instance with the SAME registry (the sweep/cleave hooks below drive them all).
	PowerBoost = mod:dofile("scripts/mods/TalentComparisonMod/modules/power_boost")
	mod._power_boost = PowerBoost
	enhanced_boost = PowerBoost.register(PowerBoost.new({
		mult = ep_power_bonus,   -- 0.075 vanilla / 0.10 under Tourney Balance (resolved live)
		buff_type = "power_level_unbalance",           -- "already equipped" detector
		force_enabled = function () return mod:get("force_ep") end,  -- general force-cleave button
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

			pcall(account_hit, ctx)

			-- Forward the same local-player hit to the level-10 WHC module and the
			-- level-20 Mercenary module (neither can add its own calculate_damage
			-- hook -- VMF ignores a duplicate from this mod). Both recompute from the
			-- unhooked `func`, so they read every argument off ctx.
			if mod._l10_on_hit then mod._l10_on_hit(ctx) end
			if mod._l10_merc_on_hit then mod._l10_merc_on_hit(ctx) end
			if mod._l20_on_hit then mod._l20_on_hit(ctx) end
			if mod._crit_on_hit then mod._crit_on_hit(ctx) end
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
		if unit then flush_kill_credit(unit, damage_amount) end
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
		if not blocking and is_melee then
			if attacker_unit == local_player_unit() then
				-- Local player's real melee application: one window per genuine hit, so a
				-- dual-wield attack's two sweeps each get counted (see account_hit).
				-- Opened regardless of show_level15 so totals keep accumulating while
				-- the panel is hidden.
				self_ctx = { target = target_unit, credited = false }
			elseif mod:get("show_level15") and is_player_unit(attacker_unit) then
				ally_ctx = { attacker = attacker_unit, target = target_unit, credited = false }
			end
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
	return mod:get("show_level15")
end

-- Full snapshot of every displayed value; called by reset_all just before the
-- totals are cleared (Reset button, keybind, and mission-entry reset).
function M.log_state()
	if not DBG then return end
	local ep = enhanced_boost
	dlog("L15 SNAP total/first (uncap): sm=%.1f/%.1f (%.1f) ms=%.1f/%.1f (%.1f) bw=%.1f/%.1f (%.1f, ally %.1f) as=%.1f/%.1f (%.1f) ep=%.1f/%.1f (%.1f) | ep cleave +%d units +%.1f dmg (uncap %.1f)",
		totals.smiter.total_dmg, totals.smiter.first_dmg, totals.smiter.total_uncapped,
		totals.mainstay.total_dmg, totals.mainstay.first_dmg, totals.mainstay.total_uncapped,
		totals.bulwark.total_dmg, totals.bulwark.first_dmg, totals.bulwark.total_uncapped, totals.bulwark.ally_dmg or 0,
		totals.assassin.total_dmg, totals.assassin.first_dmg, totals.assassin.total_uncapped,
		ep.total_dmg, ep.first_dmg, ep.total_uncapped,
		ep.extra_units_hit or 0, ep.extra_cleave_dmg or 0, ep.extra_cleave_uncapped or 0)
	dlog("L15 SNAP ep sources (capped): melee=%.1f ranged=%.1f other=%.1f",
		ep.src_melee or 0, ep.src_ranged or 0, ep.src_other or 0)
	local function hpk(t) return kills[t].hpk_n > 0 and kills[t].hpk_sum / kills[t].hpk_n or 0 end
	dlog("L15 SNAP early kills (n) / hits-per-kill / real-total: sm=%d/%.1f/%.0f ms=%d/%.1f/%.0f bw=%d/%.1f/%.0f as=%d/%.1f/%.0f ep=%d/%.1f/%.0f",
		kills.smiter.n, hpk("smiter"), kills.smiter.real_total,
		kills.mainstay.n, hpk("mainstay"), kills.mainstay.real_total,
		kills.bulwark.n, hpk("bulwark"), kills.bulwark.real_total,
		kills.assassin.n, hpk("assassin"), kills.assassin.real_total,
		kills.enhanced.n, hpk("enhanced"), kills.enhanced.real_total)
end

-- Reset just this group (its panel's Reset button), snapshotting first.
function M.reset_self()
	if M.log_state then pcall(M.log_state) end
	M.reset()
end

function M.draw(gui)
	local FONT_SIZE = ui.FONT_SIZE
	local small = FONT_SIZE - 6

	local show_extra = extra_shown()
	local tb = tb_mod_active()

	-- Displayed talents: TB removed Mainstay, so drop that row while TB is loaded.
	local disp = {}
	for _, t in ipairs(TALENTS15) do
		if not (t == "mainstay" and tb) then disp[#disp + 1] = t end
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
		ui.text_bold(gui, tb and "Stagger Talents (TB):" or "Stagger Talents:", x, row_y(0), FONT_SIZE, ui.yellow)
	end
	if collapsed then return end

	ui.text(gui, "Extra Damage:", x, row_y(1), small, ui.grey)
	ui.text(gui, "Total", x + T15_TOTAL_COL, row_y(1), small, ui.grey)
	ui.text(gui, "First Unit", x + T15_FIRST_COL, row_y(1), small, ui.grey)
	ui.text(gui, "Uncapped", x + T15_UNCAP_COL, row_y(1), small, ui.grey)
	ui.text(gui, "Early Kills", x + T15_KILLS_COL, row_y(1), small, ui.grey)
	ui.text(gui, "Hits/Kill", x + T15_HPK_COL, row_y(1), small, ui.grey)
	ui.text(gui, "Real Total", x + T15_REAL_COL, row_y(1), small, ui.grey)

	for i, talent in ipairs(disp) do
		local ry = row_y(i + 1)
		ui.text(gui, TALENT15_NAMES[talent], x, ry, FONT_SIZE, ui.white)
		-- EP is valued by the shared power_boost instance; its Total/Uncapped include
		-- its extra cleave damage (overkill-accounted for Total, raw for Uncapped).
		-- The stagger talents come from `totals` and have no cleave component.
		local total, first, uncapped
		if talent == "enhanced" then
			total = enhanced_boost.total_dmg + (enhanced_boost.extra_cleave_dmg or 0)
			first = enhanced_boost.first_dmg
			uncapped = enhanced_boost.total_uncapped + (enhanced_boost.extra_cleave_uncapped or 0)
		else
			local rec = totals[talent]
			total, first, uncapped = rec.total_dmg, rec.first_dmg, rec.total_uncapped
		end
		ui.text(gui, string.format("%.0f", total), x + T15_TOTAL_COL, ry, FONT_SIZE, ui.white)
		ui.text(gui, string.format("%.0f", first), x + T15_FIRST_COL, ry, FONT_SIZE, ui.white)
		ui.text(gui, string.format("%.0f", uncapped), x + T15_UNCAP_COL, ry, FONT_SIZE, ui.white)

		-- Early Kills = units this talent finished sooner; Hits/Kill = running average
		-- hits-to-kill over every unit you killed (capped at the talent's early kill).
		local k = kills[talent]
		ui.text(gui, string.format("%d", k.n), x + T15_KILLS_COL, ry, FONT_SIZE, ui.white)
		ui.text(gui, k.hpk_n > 0 and string.format("%.1f", k.hpk_sum / k.hpk_n) or "-",
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
		ep.src_melee or 0, ep.src_ranged or 0, ep.src_other or 0),
		x, row_y(n + 3), small, ui.grey)

	-- Enhanced Power extra-cleave summary.
	local ep_line
	if mod:get("force_ep") then
		ep_line = string.format("EP cleave: +%d units, +%.0f dmg  (without +cleave: %.0f)",
			ep.extra_units_hit, ep.extra_cleave_dmg, ep.total_dmg)
	else
		ep_line = string.format("EP cleave (est): +%d units  (without +cleave: %.0f)",
			ep.extra_units_hit, ep.total_dmg)
	end
	ui.text(gui, ep_line, x, row_y(n + 4), small, ui.grey)
end

return M
