-- level20_merc_talents.lua
-- ============================================================================
-- Talent group: Level-20 Mercenary (es_mercenary) talents. CAREER-SPECIFIC, like
-- the level-10 WHC panel -- the panel is hidden and NONE of the simulation runs
-- unless the LOCAL player is currently playing Mercenary.
--
-- The Mercenary passive is Paced Strikes: a light/heavy attack that hits >= 3
-- targets grants +10% attack speed for 6s (buff markus_mercenary_passive_proc,
-- multiplier 0.1; targets from markus_mercenary_passive.targets = 3). The level-20
-- row modifies that passive; a Merc picks 2 of these 3:
--   Reikland Reaper (markus_mercenary_passive_power_level_on_proc): the proc ALSO
--     grants +15% power for 6s (markus_mercenary_passive_power_level, 0.15). Attack
--     speed is unchanged (still base +10%). Valued like Enhanced Power: re-run each
--     real hit with x1.15 power and credit the delta, but only WHILE Paced Strikes
--     is up. Respects armour breakpoints (not a flat +15%).
--   Enhanced Training (markus_mercenary_passive_improved): the proc now needs >= 4
--     targets and grants +20% attack speed (multiplier 0.2, targets 4). It REPLACES
--     base Paced Strikes -- with it equipped a <4 hit grants nothing at all (see
--     buff_templates.lua gain_markus_mercenary_passive_proc), so its uptime can
--     actually be LOWER than base PS despite the bigger bonus. Valued via the shared
--     attack_speed_sim: run two ghost-swing sims over the same real melee swings --
--     base PS (+10% on >=3) and ET (+20% on >=4) -- and report the difference.
--   Strike Together (markus_mercenary_passive_group_proc): spreads the +10% Paced
--     Strikes proc to every living ally (buff_templates.lua group branch, server-
--     gated). FORCED like Flense: when not equipped we replicate the group spread on
--     each real >=3-target melee proc (the talent has buffs={} and gates on has_talent,
--     so it can't be forced by adding a buff). We only ever observe an ally's already-
--     sped-up swings, so value = down-sample: reconstruct each ally's swing stream from
--     their calculate_damage hits (segmented by time gap -- no ally swing hook on host),
--     feed the shared attack_speed_sim m<1 (1/1.1) for swings landed while they carried
--     Paced Strikes, and report real - ghost = the damage the spread bought. Ally whiffs
--     never call calculate_damage, so it is firmly an ESTIMATION and host only.
--
-- WHAT IS SHOWN
--   Enhanced Training : Extra Damage (ghost delta ET - base PS) and Extra DPS, plus
--     an uptime comparison (base PS %% vs ET %%) so you can see the trade of a
--     bigger bonus for a harder, less frequent proc.
--   Reikland Reaper   : Extra Damage Total / First / Uncapped from the +15% power
--     while Paced Strikes is up (same overkill model as the level-15 panel).
--   Strike Together   : aggregate Extra Damage across allies (ESTIMATION), with a
--     per-ally breakdown under Show Details.
--
-- HOW THE SWING STREAM IS OBTAINED
--   This module owns no hooks. The level-15 module's single DamageUtils.calculate_
--   damage hook forwards every local-player hit to mod._l20_on_hit, and its
--   ActionSweep.client_owner_start_action hook forwards each melee swing start to
--   mod._l20_on_swing_start (VMF ignores a duplicate hook on the same function from
--   the same mod, so we piggyback). Reaper's x1.15 power recompute reuses the level
--   15 ActionUtils.apply_buffs_to_power_level hook via the shared power_boost module
--   (PowerBoost.recompute_mult), the same engine Enhanced Power uses.
--
-- NOTE (host vs client): calculate_damage / ActionSweep resolve for the local owner
-- on the host; most accurate as host. Values are hypothetical ("what would this
-- talent have given"), computed from the local player's real swings regardless of
-- which level-20 talent is actually equipped.
-- ============================================================================

local M = {}

local mod   -- set in init()
local ui    -- shared ui_panel, set in init()
local F     -- unit_filter (mod._filter), set in init
local AttackSpeedSim  -- required in init()
local PowerBoost      -- shared power_boost module (from level 15, via mod._power_boost)
local reaper_boost    -- Reikland Reaper's power_boost instance (mult 0.15, gated on PS)
local l20_kt          -- shared kill-tracker instance (mod._kill_tracker.new(), created in init)

local DBG = false
local function dlog(fmt, ...)
	if DBG and mod then
		local ok, s = pcall(string.format, "[TCM20] " .. fmt, ...)
		if not ok then s = "[TCM20] (log format error) " .. fmt end
		mod:echo((s:gsub("%%", "%%%%")))
	end
end

-- Tourney Balance detection (same list/logic as the level-15 / THP panels). Under
-- TB the whole Merc level-20 row behaves differently (see the TB block near M.draw),
-- so a distinct "TB version" of the GUI is shown instead of the vanilla one.
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
-- Talent buff names for has_talent() detection (see talent_settings_markus.lua).
local TALENT_REAPER = "markus_mercenary_passive_power_level_on_proc"
local TALENT_ET     = "markus_mercenary_passive_improved"
local TALENT_ST     = "markus_mercenary_passive_group_proc"
-- The spread attack-speed buff itself (base Paced Strikes proc, +10% for 6s). It has
-- no buff_type, so allies are checked for it via buff_template_name (see unit_has_ps).
local PS_PROC_BUFF  = "markus_mercenary_passive_proc"

-- Paced Strikes numbers, straight from talent_settings_markus.lua buff_tweak_data.
local PS_DURATION       = 6.0
local BASE_PS_TARGETS   = 3      -- markus_mercenary_passive.targets
local BASE_PS_SPEED     = 0.10   -- markus_mercenary_passive_proc.multiplier
local ET_TARGETS        = 4      -- markus_mercenary_passive_improved.targets (vanilla)
local ET_TARGETS_TB     = 3      -- TB: "Target requirement decreased from 4 to 3"
local ET_SPEED          = 0.20   -- markus_mercenary_passive_improved.multiplier
local REAPER_POWER      = 0.15   -- markus_mercenary_passive_power_level.multiplier
local ST_SPEED          = 0.10   -- Strike Together spreads the base +10% attack speed
-- TB: "Proccing Paced Strikes now requires hitting only one enemy" -- with Strike
-- Together the PS proc threshold drops from 3 targets to 1.
local ST_TARGETS_TB     = 1
-- Ally swings have NO start hook on the host (client_owner_start_action is local
-- only), so their calculate_damage stream is segmented into swings by time gap:
-- consecutive hits from one ally within this window are the same swing.
local ALLY_SWING_GAP    = 0.3

-- calculate_damage fires 2+ times per real melee hit; dedupe per target by time,
-- exactly like the level-15 / level-10 modules.
local SWEEP_DEDUPE_WINDOW = 0.2
-- A melee swing with no further hits for this long is flushed (its last hit / whiff
-- finalised) so end-of-chain swings and idle are handled without a next swing.
local SWING_IDLE_FLUSH = 1.0

-- ---------------------------------------------------------------------------
-- Running state
-- ---------------------------------------------------------------------------
-- Two attack-speed tracks. Each holds a ghost-swing sim, its proc target threshold,
-- its speed bonus, and its simulated buff-expiry / accumulated active time.
-- base_track  = Paced Strikes proc @>=3 targets, +10% AS (the local player's own).
-- et_track    = Enhanced Training proc, +20% AS; threshold 4 vanilla / 3 under TB.
-- st_track    = TB-only Strike Together track: Paced Strikes proc @>=1 target, +10%.
--   Its uptime/extra vs base_track isolate the value of "proccing off a single enemy".
--   st_track.expiry doubles as the Merc's ST-proc window used to drive ally sims.
local base_track, et_track, st_track
-- Reaper's extra damage / source split / cleave live on reaper_boost (shared
-- power_boost instance), so no local record is needed.
-- Uptime denominator: real game-time integrated since the first melee swing.
local uptime_total
local first_swing_t
-- Current melee swing being accumulated (nil = none open).
local cur_swing   -- { dmg, targets, t, seen = {unit -> last credit time} }
-- Strike Together: per-ally reconstructed swing streams. unit ->
--   { sim, dmg, last_t, open, active (PS up at swing start), seen = {unit -> t} }.
local ally_tracks

local function new_track(targets, speed)
	return {
		sim = AttackSpeedSim.new(),
		targets = targets,
		speed = speed,
		expiry = nil,     -- simulated Paced-Strikes buff expiry (game time)
		active_time = 0,  -- integrated seconds this track's buff was up
	}
end

function M.reset()
	base_track = new_track(BASE_PS_TARGETS, BASE_PS_SPEED)
	-- TB decreases Enhanced Training's target requirement 4 -> 3.
	local et_targets = tb_mod_active() and ET_TARGETS_TB or ET_TARGETS
	et_track   = new_track(et_targets, ET_SPEED)
	-- TB Strike Together: PS procs off a single enemy (>=1 target).
	st_track   = new_track(ST_TARGETS_TB, ST_SPEED)
	if reaper_boost then reaper_boost:reset() end
	if l20_kt then l20_kt:reset() end
	uptime_total = 0
	first_swing_t = nil
	cur_swing = nil
	ally_tracks = {}
end

-- Kill-column record for `talent` from the shared tracker, or an all-zero default
-- before its first credit (Reikland Reaper only; the ghost-swing talents have none).
local ZERO_KILLS = { n = 0, saved_sum = 0, saved_n = 0, hpk_sum = 0, hpk_n = 0, real_total = 0 }
local function kget(talent)
	return (l20_kt and l20_kt:get(talent)) or ZERO_KILLS
end

-- ---------------------------------------------------------------------------
-- Helpers (mirror the other modules)
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

local function useful_extra(baseline, extra, H)
	if not H then return extra end
	local lo = math.min(baseline, H)
	local hi = math.min(baseline + extra, H)
	local u = hi - lo
	if u < 0 then u = 0 end
	if u > extra then u = extra end
	return u
end

local function career_is_merc()
	local unit = local_player_unit()
	if not unit then return false end
	local ce = ScriptUnit.has_extension(unit, "career_system")
	if not ce then return false end
	local ok, name = pcall(function () return ce:career_name() end)
	return ok and name == MERC_CAREER_NAME
end

-- Panel/simulation active only while playing Mercenary.
local function active()
	return career_is_merc()
end

local function talent_equipped(unit, talent_name)
	local te = ScriptUnit.has_extension(unit, "talent_system")
	if not te then return false end
	local ok, res = pcall(function () return te:has_talent(talent_name) end)
	return ok and res or false
end

local function is_melee(dp)
	return dp and not dp.is_dot
		and (dp.charge_value == "light_attack" or dp.charge_value == "heavy_attack")
end

-- --- Strike Together helpers -------------------------------------------------
local function is_server()
	return Managers.state.network and Managers.state.network.is_server
end

local function unit_alive(unit)
	local h = unit_current_health(unit)
	return h ~= nil and h > 0
end


-- Readable label for the per-ally detail lines; best-effort, falls back to "ally".
local function unit_name(unit)
	local ok, name = pcall(function ()
		local p = Managers.player and Managers.player:owner(unit)
		return p and p:name()
	end)
	if ok and name and name ~= "" then return tostring(name) end
	return "ally"
end

-- ---------------------------------------------------------------------------
-- Swing accumulation: a "swing" is one local-player melee light/heavy attack. We
-- open it on the ActionSweep start and sum the real damage of every distinct unit
-- it hits (a whiff stays a 0-damage swing so the ghost cadence is correct).
-- ---------------------------------------------------------------------------
local function feed_track(track, swing)
	-- Multiplier from the buff PRIOR swings left up (an attack-speed buff affects
	-- subsequent attacks, not the swing that procs it).
	local m = 1.0
	if track.expiry and swing.t < track.expiry then
		m = 1.0 + track.speed
	end
	track.sim:add_swing(swing.dmg, m)
	-- This swing (re)arms the buff only if it meets THIS track's target threshold.
	if swing.targets >= track.targets then
		track.expiry = swing.t + PS_DURATION
	end
end

local function finalize_swing()
	local swing = cur_swing
	cur_swing = nil
	if not swing then return end
	if not first_swing_t then first_swing_t = swing.t end
	feed_track(base_track, swing)
	feed_track(et_track, swing)
	-- st_track (the Merc's >=1-target PS window) is fed always; it drives both the
	-- local ST extra and the ally sims under TB. Harmless in vanilla mode (unused).
	feed_track(st_track, swing)

	-- Strike Together is NEVER forced onto allies now (vanilla or TB). The ally value
	-- is always an ESTIMATE off the Merc's own >=3 proc windows (base_track): we observe
	-- each ally's own un-sped swings and ghost-sim how much extra damage the +10%
	-- attack speed WOULD have given them during those windows. See finalize_ally_swing.

	dlog("SWING t=%.2f targets=%d dmg=%.1f | basePS m=%s ET m=%s",
		swing.t, swing.targets, (swing.dmg.elite + swing.dmg.special + swing.dmg.mon + swing.dmg.trash),
		(base_track.expiry and swing.t < base_track.expiry) and "on" or "off",
		(et_track.expiry and swing.t < et_track.expiry) and "on" or "off")
end

-- Called from the level-15 ActionSweep.client_owner_start_action hook for every
-- melee swing the local player starts.
local function on_swing_start(self, power_level)
	if not active() then return end
	local owner_unit = self.owner_unit
	if owner_unit ~= local_player_unit() then return end
	local dp = self._damage_profile
	if not is_melee(dp) then return end
	-- The previous swing is complete once the next one begins.
	finalize_swing()
	cur_swing = { dmg = { elite = 0, special = 0, mon = 0, trash = 0 }, targets = 0, t = game_time(), seen = {} }
end

-- ---------------------------------------------------------------------------
-- Reikland Reaper valuation. All of the "extra damage from +15% power" logic
-- (source split, overkill accounting, extra cleave) lives in the shared
-- power_boost module and is reused verbatim from Enhanced Power -- the only
-- differences are the power value (0.15) and the gate: Reaper's +15% applies ONLY
-- while base Paced Strikes is up (its proc), so reaper_gate below is the boost's
-- `gate`, and the shared engine credits nothing when it is down.
-- ---------------------------------------------------------------------------
-- True while Reaper's power boost would be in effect: Merc + panel on + base Paced
-- Strikes currently up. Used as the power_boost gate for both per-hit damage and
-- (at swing start) the forced-cleave decision.
local function reaper_gate()
	if not active() then return false end
	return base_track ~= nil and base_track.expiry ~= nil and game_time() < base_track.expiry
end

-- Called from the level-15 calculate_damage hook for every local-player hit.
local function on_hit(ctx)
	if not active() then return end
	if ctx.attacker_unit ~= local_player_unit() then return end
	local final = ctx.final
	if not final or final <= 0 then return end
	local dp = ctx.damage_profile
	if not dp then return end

	local target_unit = ctx.target_unit
	local health = unit_current_health(target_unit)
	if health and health <= 0 then          -- corpse contact, no real damage
		if l20_kt then l20_kt:forget(target_unit) end
		return
	end
	local first = (ctx.target_index or 1) <= 1
	local melee = is_melee(dp)

	-- Per-genuine-hit dedupe: defer to the level-15 module's single decision (shared
	-- with account_hit and the level-10 forward) so duplicate calculate_damage calls
	-- collapse to one while a dual-wield attack's two sweeps (left+right weapon) each
	-- still count toward this swing's damage. See level15 melee_should_credit.
	local now = game_time()
	local swing = cur_swing
	if melee then
		if not (mod._l15_melee_credit and mod._l15_melee_credit(ctx)) then
			return   -- duplicate/deduped call for a hit already counted this swing.
		end
		if not swing then
			swing = { dmg = { elite = 0, special = 0, mon = 0, trash = 0 }, targets = 0, t = now, seen = {} }
			cur_swing = swing
		end
	end

	-- Forced-cleave extra units (general force button extended this sweep). Credit
	-- Reaper's cleave counters if the unit is in its band, then STOP -- these hits
	-- would not happen without the boost, so they must not feed the attack-speed
	-- swing damage or Reaper's per-hit column.
	if melee and PowerBoost.is_forced_extra(target_unit) then
		reaper_boost:account_cleave_unit(target_unit, final, health)
		return
	end

	-- Accumulate this swing's real damage for the attack-speed sim (Enhanced Training),
	-- split by the unit category it landed on so ghost swings can be valued per category.
	if melee then
		local cat = ctx.cat or F.cat_of(target_unit)
		swing.dmg[cat] = (swing.dmg[cat] or 0) + final
		local idx = ctx.target_index or 1
		if idx > swing.targets then swing.targets = idx end
	end

	-- Reikland Reaper +15% power (all sources). The boost self-gates on reaper_gate
	-- (base Paced Strikes up) and on whether Reaper is already equipped.
	local r_extra = reaper_boost:account_hit(ctx, melee, first, health)
	if r_extra and r_extra > 0 then
		-- Kill-aware: if Reaper is equipped the +15% is baked into `final` (baseline =
		-- final - extra); otherwise `final` IS the baseline and the boost adds on top.
		if talent_equipped(ctx.attacker_unit, TALENT_REAPER) then
			l20_kt:add("reaper", final - r_extra, final)
		else
			l20_kt:add("reaper", final, final + r_extra)
		end
	end
end

-- ---------------------------------------------------------------------------
-- Strike Together: value the attack-speed the local Merc's spread gave ALLIES.
-- We only observe an ally's ACTUAL (already-sped-up) swings, so we down-sample:
-- for swings landed while the ally carried Paced Strikes, feed the sim m<1
-- (1 / (1 + 10%)) -- "without the spread they'd have landed fewer swings" -- and
-- report real - ghost as the extra damage the spread bought. Ally whiffs never call
-- calculate_damage, so cadence is slightly undercounted -> firmly an ESTIMATION.
-- ---------------------------------------------------------------------------
local function finalize_ally_swing(tr)
	if not tr.open then return end
	tr.open = false
	if tb_mod_active() then
		-- TB model: value = extra damage from the Merc proccing PS off a SINGLE enemy
		-- vs off >=3, spread to this ally. Feed the ally's observed swing to two ghost
		-- sims driven by the Merc's own proc windows (captured at swing start): the
		-- base timeline (Merc >=3 procs) and the ST timeline (Merc >=1 procs). Each
		-- applies +10% AS while its window is up; ST_extra - base_extra isolates the
		-- damage from the extra windows that a single-enemy proc buys (>=3 procs, which
		-- both timelines share, cancel out -- exactly "not counting the >=3 procs").
		tr.base_sim:add_swing(tr.dmg, tr.base_active and (1.0 + ST_SPEED) or 1.0)
		tr.st_sim:add_swing(tr.dmg, tr.st_active and (1.0 + ST_SPEED) or 1.0)
	else
		-- Vanilla estimate: the spread is NOT forced, so we observe the ally's OWN
		-- un-sped swings. Estimate how much extra damage the +10% attack speed WOULD
		-- have given them during the Merc's own >=3-target Paced-Strikes proc windows
		-- (base_track) -- the windows in which Strike Together would have spread the
		-- buff to this ally. Feed a ghost sim +10% while base_active; ghost - real =
		-- base_sim:extra() = the extra damage the spread would have bought.
		tr.base_sim:add_swing(tr.dmg, tr.base_active and (1.0 + ST_SPEED) or 1.0)
	end
end

-- Called (via the level-15 hook) for every ALLY player melee hit on the host.
local function on_ally_hit(ctx)
	if not active() then return end
	if not is_melee(ctx.damage_profile) then return end
	local unit = ctx.attacker_unit
	local final = ctx.final
	if not final or final <= 0 then return end
	if not unit_alive(ctx.target_unit) then return end   -- corpse contact

	local now = game_time()
	local tr = ally_tracks[unit]
	if not tr then
		tr = {
			base_sim = AttackSpeedSim.new(),   -- vanilla + TB: Merc >=3 proc timeline
			st_sim = AttackSpeedSim.new(),     -- TB: Merc >=1 proc timeline
			dmg = { elite = 0, special = 0, mon = 0, trash = 0 }, last_t = nil, open = false, seen = {},
		}
		ally_tracks[unit] = tr
	end
	-- Gap-segment: a new swing begins once the previous one has been idle a while.
	if tr.open and tr.last_t and (now - tr.last_t) > ALLY_SWING_GAP then
		finalize_ally_swing(tr)
	end
	if not tr.open then
		tr.open = true
		tr.dmg = { elite = 0, special = 0, mon = 0, trash = 0 }
		tr.seen = {}
		tr.base_active = base_track.expiry ~= nil and now < base_track.expiry  -- Merc >=3 window
		tr.st_active   = st_track.expiry ~= nil and now < st_track.expiry      -- TB: Merc >=1 window
	end
	-- Per-target dedupe (calculate_damage runs 2+ times per real hit).
	local seen_t = tr.seen[ctx.target_unit]
	if seen_t and (now - seen_t) < SWEEP_DEDUPE_WINDOW then return end
	tr.seen[ctx.target_unit] = now

	local cat = ctx.cat or F.cat_of(ctx.target_unit)
	tr.dmg[cat] = (tr.dmg[cat] or 0) + final
	tr.last_t = now
end

-- Per-ally extra damage the spread bought this run (mode-dependent).
local function ally_extra(tr)
	if tb_mod_active() then
		-- ST timeline vs base timeline: damage from the extra single-enemy proc windows.
		return tr.st_sim:extra() - tr.base_sim:extra()
	end
	-- Vanilla estimate: extra damage the +10% spread would give during Merc >=3 windows.
	return tr.base_sim:extra()
end

local function ally_swung(tr)
	if tb_mod_active() then return tr.st_sim.real_swings > 0 end
	return tr.base_sim.real_swings > 0
end

-- Sum of the extra damage Strike Together bought all allies this run. Under TB the
-- local player's OWN extra single-enemy-proc damage is included too ("you and your
-- allies") -- st_track (>=1) vs base_track (>=3) on the local swing stream.
local function st_total()
	local sum = 0
	if tb_mod_active() then
		sum = sum + (st_track.sim:extra() - base_track.sim:extra())
	end
	if not ally_tracks then return sum end
	for _, tr in pairs(ally_tracks) do
		sum = sum + ally_extra(tr)
	end
	return sum
end

-- Per-ally { name, extra } lines for the detail view (only allies that have swung).
local function st_ally_lines()
	local lines = {}
	if not ally_tracks then return lines end
	for unit, tr in pairs(ally_tracks) do
		if ally_swung(tr) then
			lines[#lines + 1] = { name = unit_name(unit), extra = ally_extra(tr) }
		end
	end
	return lines
end

-- ---------------------------------------------------------------------------
-- Hooks / wiring
-- ---------------------------------------------------------------------------
function M.init(owner_mod, ui_panel)
	mod = owner_mod
	ui = ui_panel
	F = mod._filter
	AttackSpeedSim = mod:dofile("scripts/mods/TalentComparisonMod/modules/attack_speed_sim")
	-- Ghost swings value only the selected unit category's hits.
	AttackSpeedSim.set_filter(F.enabled)

	-- Reikland Reaper reuses Enhanced Power's power_boost engine (same damage /
	-- source / cleave logic) with its own +15% power and its Paced-Strikes gate.
	-- The level-15 module owns the single shared instance registry (mod._power_boost)
	-- and installs the hooks that drive every registered boost; it inits first.
	PowerBoost = mod._power_boost

	-- Shared kill / Real-Total tracker (owned by level15, which inits first); own instance
	-- so this panel's Reset zeroes only its rows. Reikland Reaper feeds it.
	l20_kt = mod._kill_tracker.new()

	reaper_boost = PowerBoost.register(PowerBoost.new({
		mult = REAPER_POWER,
		talent_equipped = function (unit) return talent_equipped(unit, TALENT_REAPER) end,
		gate = reaper_gate,
		force_enabled = function () return mod._gameplay_on("force_ep") end,  -- gameplay-gated force-cleave
	}))
	M.reset()

	-- Forwarded by the level-15 module (shared hooks; see its init).
	mod._l20_on_hit = function (ctx) pcall(on_hit, ctx) end
	mod._l20_on_swing_start = function (self, power_level) pcall(on_swing_start, self, power_level) end
	mod._l20_on_ally_hit = function (ctx) pcall(on_ally_hit, ctx) end
end

-- ---------------------------------------------------------------------------
-- Update: integrate uptime and flush a swing after an idle gap.
-- ---------------------------------------------------------------------------
function M.update(dt)
	-- Strike Together is no longer force-spread onto allies -- its value is always an
	-- estimate off the Merc's own proc windows -- so this panel never modifies gameplay.
	if mod._gameplay_live then
		mod._gameplay_live.force_st_spread = false
	end
	if not active() then return end
	local now = game_time()

	-- Flush an open swing that has seen no further hits for a while (end of a chain
	-- or a whiff) so it is fed to the sims and idle stops advancing the cadence.
	if cur_swing and (now - cur_swing.t) > SWING_IDLE_FLUSH then
		finalize_swing()
	end

	-- Flush ally swings that have gone idle (end of a chain / no next hit to segment on).
	if ally_tracks then
		for _, tr in pairs(ally_tracks) do
			if tr.open and tr.last_t and (now - tr.last_t) > SWING_IDLE_FLUSH then
				finalize_ally_swing(tr)
			end
		end
	end

	-- Integrate uptime for both tracks (only after the first swing, matching when
	-- the ghost timeline starts).
	if first_swing_t then
		uptime_total = uptime_total + dt
		if base_track.expiry and now < base_track.expiry then
			base_track.active_time = base_track.active_time + dt
		end
		if et_track.expiry and now < et_track.expiry then
			et_track.active_time = et_track.active_time + dt
		end
		if st_track.expiry and now < st_track.expiry then
			st_track.active_time = st_track.active_time + dt
		end
	end
end

-- ---------------------------------------------------------------------------
-- Display
-- ---------------------------------------------------------------------------
-- Total moved right of the (long) talent names so they no longer overlap; the
-- First column was removed at the user's request.
local L20_TOTAL_COL = 200
local L20_UNCAP_COL = 330
local L20_REAL_COL  = 450   -- Real Total: extra damage that actually pulled kills sooner
local PANEL_W_T20   = 600
local ui_red = Color(255, 255, 60, 60)

function M.wants_display()
	return active()
end

-- Enhanced Training's real attack-speed buff (+20% on a >=4-target proc) changes
-- the LOCAL PLAYER's actual swing cadence. Reikland Reaper's power_boost recompute
-- assumes hits land at the base Paced-Strikes cadence (its gate only tracks the
-- simulated >=3-target proc window) -- with ET actually equipped, real hits are
-- faster/denser than that assumption, so Reaper's Total is contaminated by ET's
-- real speed and is no longer a clean measurement. Rather than fight this by
-- forcibly swapping the real talent (unsafe: has_talent is server-authoritative
-- and mutating it is a full loadout respec -- see level20-merc-attackspeed memory),
-- we just tell the player to unequip ET for this panel's numbers to be trustworthy.
local function player_has_et()
	local owner = local_player_unit()
	return owner ~= nil and talent_equipped(owner, TALENT_ET)
end

local function uptime_pct(track)
	if not uptime_total or uptime_total <= 0 then return 0 end
	return track.active_time / uptime_total * 100
end

-- Whether the extra breakdown lines (Reaper sources / Reaper cleave) show;
-- toggled by the panel's Details button. Defaults on, like the level-15 panel.
local function extra_shown()
	local v = mod:get("show_l20_extra")
	if v == nil then return true end
	return v
end

function M.log_state()
	if not DBG then return end
	dlog("L20 SNAP ET extra=%.1f | basePS up=%.1f%% ET up=%.1f%% | reaper %.1f (%.1f) | cleave +%d units +%.1f dmg | src m=%.1f r=%.1f o=%.1f",
		et_track.sim:extra() - base_track.sim:extra(),
		uptime_pct(base_track), uptime_pct(et_track),
		reaper_boost:rd("total_dmg"), reaper_boost:rd("total_uncapped"),
		reaper_boost:units_hit(), reaper_boost:rd("extra_cleave_dmg"),
		reaper_boost:rd("src_melee"), reaper_boost:rd("src_ranged"), reaper_boost:rd("src_other"))
	dlog("L20 SNAP ST total=%.1f allies=%d", st_total(), #st_ally_lines())
end

function M.reset_self()
	if M.log_state then pcall(M.log_state) end
	M.reset()
end

-- Vanilla (non-TB) GUI: Reaper / Enhanced Training / Strike Together with the base
-- Paced-Strikes-vs-Enhanced-Training uptime comparison.
local function draw_vanilla(gui)
	local FONT_SIZE = ui.FONT_SIZE
	local small = FONT_SIZE - 6

	local show_extra = extra_shown()
	local warn = player_has_et()
	local off = warn and 1 or 0   -- shift every row down 1 when the ET warning is shown

	-- rows: [warn(0)] title header(1+) Reaper ET Strike Together uptime. Details add
	-- Reaper sources, Reaper cleave and one line per ally.
	local ally_lines = show_extra and st_ally_lines() or nil
	local content_rows = 6 + off
	if show_extra then content_rows = 8 + off + math.max(#ally_lines, 1) end
	local x, top, row_y, collapsed, title_visible = ui.frame(gui, PANEL_W_T20, content_rows, "l20_pos_x", "l20_pos_y", 0.03, 0.45, "l20", M.reset_self,
		{
			extra_btn = {
				label = show_extra and "Hide Details" or "Show Details",
				on_click = function () mod:set("show_l20_extra", not show_extra) end,
			},
		})
	if not x then return end

	if collapsed then
		if title_visible then
			ui.text_bold(gui, "Reaper / ET / Strike Together:", x, row_y(0), FONT_SIZE, ui.yellow)
		end
		return
	end

	if warn then
		ui.text_bold(gui, "Unequip Enhanced Training to see accurate stats for this panel!",
			x, row_y(0), FONT_SIZE, ui_red)
	end

	ui.text_bold(gui, "Reaper / ET / Strike Together:", x, row_y(0 + off), FONT_SIZE, ui.yellow)

	-- Reikland Reaper: extra damage from +15% power during Paced Strikes. Its
	-- Total/Uncapped include its extra cleave damage (like Enhanced Power).
	ui.text(gui, "Extra Damage:", x, row_y(1 + off), small, ui.grey)
	ui.text(gui, "Total", x + L20_TOTAL_COL, row_y(1 + off), small, ui.grey)
	ui.text(gui, "Uncapped", x + L20_UNCAP_COL, row_y(1 + off), small, ui.grey)
	ui.text(gui, "Real Total", x + L20_REAL_COL, row_y(1 + off), small, ui.grey)

	local r_total = reaper_boost:rd("total_dmg") + reaper_boost:rd("extra_cleave_dmg")
	local r_uncap = reaper_boost:rd("total_uncapped") + reaper_boost:rd("extra_cleave_uncapped")
	ui.text(gui, "Reikland Reaper", x, row_y(2 + off), FONT_SIZE, ui.white)
	ui.text(gui, string.format("%.0f", r_total), x + L20_TOTAL_COL, row_y(2 + off), FONT_SIZE, ui.white)
	ui.text(gui, string.format("%.0f", r_uncap), x + L20_UNCAP_COL, row_y(2 + off), FONT_SIZE, ui.white)
	-- Real Total (kill-aware, per-hit only -- the extra-cleave slice has no kill model).
	ui.text(gui, string.format("%.0f", kget("reaper").real_total), x + L20_REAL_COL, row_y(2 + off), FONT_SIZE, ui.white)

	-- Enhanced Training: ghost-swing extra damage (ET timeline vs base PS timeline).
	local et_extra = et_track.sim:extra() - base_track.sim:extra()
	ui.text(gui, "Enhanced Training", x, row_y(3 + off), FONT_SIZE, ui.white)
	ui.text(gui, string.format("%.0f", et_extra), x + L20_TOTAL_COL, row_y(3 + off), FONT_SIZE, ui.white)
	ui.text(gui, "ESTIMATION", x + L20_UNCAP_COL, row_y(3 + off), small, ui.grey)
	-- Ghost-swing attack-speed estimate: no per-hit kill model, so no Real Total.
	ui.text(gui, "-", x + L20_REAL_COL, row_y(3 + off), FONT_SIZE, ui.white)

	-- Strike Together: extra ally damage from the spread +10% attack speed. The spread
	-- is never forced -- this is an ESTIMATE of how much extra damage the +10% would
	-- have given allies during the Merc's own >=3-target Paced-Strikes proc windows,
	-- measured against each ally's own un-sped swing stream (host only). When ST is
	-- ALREADY equipped the game is already spreading it, so we don't estimate -- the
	-- ally swings we observe are already sped up and the counterfactual is meaningless.
	local owner = local_player_unit()
	local st_equipped = owner and talent_equipped(owner, TALENT_ST)
	ui.text(gui, st_equipped and "Strike Together (equipped)" or "Strike Together",
		x, row_y(4 + off), FONT_SIZE, ui.white)
	ui.text(gui, st_equipped and "-" or string.format("%.0f", st_total()),
		x + L20_TOTAL_COL, row_y(4 + off), FONT_SIZE, ui.white)
	ui.text(gui, st_equipped and "-" or "ESTIMATION", x + L20_UNCAP_COL, row_y(4 + off), small, ui.grey)
	ui.text(gui, "-", x + L20_REAL_COL, row_y(4 + off), FONT_SIZE, ui.white)

	-- Uptime comparison: base Paced Strikes vs Enhanced Training's harder proc.
	ui.text(gui, string.format("Paced Strikes uptime: base %.0f%%  vs  ET %.0f%%",
		uptime_pct(base_track), uptime_pct(et_track)), x, row_y(5 + off), small, ui.grey)

	if not show_extra then return end

	-- Reikland Reaper extra damage by source (overkill-accounted; sums to Reaper
	-- Total minus the extra-cleave slice below), mirroring the EP sources line.
	ui.text(gui, string.format("Reaper sources: Melee +%.0f  Ranged +%.0f  Other +%.0f dmg",
		reaper_boost:rd("src_melee"), reaper_boost:rd("src_ranged"), reaper_boost:rd("src_other")),
		x, row_y(6 + off), small, ui.grey)

	-- Reikland Reaper extra-cleave summary (forced via the shared force button, or
	-- estimated), mirroring the EP cleave line.
	local r_line
	if mod._gameplay_on("force_ep") then
		r_line = string.format("Reaper cleave: +%d units, +%.0f dmg  (without +cleave: %.0f)",
			reaper_boost:units_hit(), reaper_boost:rd("extra_cleave_dmg"), reaper_boost:rd("total_dmg"))
	else
		r_line = string.format("Reaper cleave (est): +%d units  (without +cleave: %.0f)",
			reaper_boost:units_hit(), reaper_boost:rd("total_dmg"))
	end
	ui.text(gui, r_line, x, row_y(7 + off), small, ui.grey)

	-- Strike Together per-ally breakdown (extra damage from each ally's spread +10%).
	if st_equipped then
		ui.text(gui, "Strike Together: equipped -- game already spreads it, no estimate.",
			x, row_y(8 + off), small, ui.grey)
	elseif #ally_lines == 0 then
		ui.text(gui, "Strike Together: no ally hits recorded yet (host only).",
			x, row_y(8 + off), small, ui.grey)
	else
		for i = 1, #ally_lines do
			ui.text(gui, string.format("ST %s: +%.0f dmg", ally_lines[i].name, ally_lines[i].extra),
				x, row_y(7 + off + i), small, ui.grey)
		end
	end
end

-- Tourney Balance GUI. TB reworks the Merc level-20 row:
--   * Enhanced Training procs at >=3 targets (was 4) -- same threshold as base Paced
--     Strikes, so Reaper + ET both value the +bonus over the >=3 proc window.
--   * The base passive now spreads Paced Strikes to allies on its own, and Strike
--     Together makes the proc fire off a SINGLE enemy. So Strike Together's value is
--     the extra damage YOU AND YOUR ALLIES get from those single-enemy (>=1) proc
--     windows over the base >=3 windows -- NOT the >=3 procs themselves (those are
--     free from the base passive and cancel in st - base).
-- Hence the uptime comparison switches from base-vs-ET to base-vs-Strike-Together.
local function draw_tb(gui)
	local FONT_SIZE = ui.FONT_SIZE
	local small = FONT_SIZE - 6

	local show_extra = extra_shown()
	local warn = player_has_et()
	local off = warn and 1 or 0

	local ally_lines = show_extra and st_ally_lines() or nil
	-- rows: [warn] title, Extra-Damage header, Reaper, ET, Strike Together, uptime = 6.
	-- extra adds: Reaper sources, Reaper cleave, ST you/allies split, ally lines.
	local content_rows = 6 + off
	if show_extra then content_rows = 9 + off + math.max(#ally_lines, 1) end
	local x, top, row_y, collapsed, title_visible = ui.frame(gui, PANEL_W_T20, content_rows, "l20_pos_x", "l20_pos_y", 0.03, 0.45, "l20", M.reset_self,
		{
			extra_btn = {
				label = show_extra and "Hide Details" or "Show Details",
				on_click = function () mod:set("show_l20_extra", not show_extra) end,
			},
		})
	if not x then return end

	if collapsed then
		if title_visible then
			ui.text_bold(gui, "Reaper / ET / Strike Together (TB):", x, row_y(0), FONT_SIZE, ui.yellow)
		end
		return
	end

	if warn then
		ui.text_bold(gui, "Unequip Enhanced Training to see accurate stats for this panel!",
			x, row_y(0), FONT_SIZE, ui_red)
	end

	ui.text_bold(gui, "Reaper / ET / Strike Together (TB):", x, row_y(0 + off), FONT_SIZE, ui.yellow)

	-- Reikland Reaper: unchanged under TB (+15% power during Paced Strikes uptime).
	ui.text(gui, "Extra Damage:", x, row_y(1 + off), small, ui.grey)
	ui.text(gui, "Total", x + L20_TOTAL_COL, row_y(1 + off), small, ui.grey)
	ui.text(gui, "Uncapped", x + L20_UNCAP_COL, row_y(1 + off), small, ui.grey)
	ui.text(gui, "Real Total", x + L20_REAL_COL, row_y(1 + off), small, ui.grey)

	local r_total = reaper_boost:rd("total_dmg") + reaper_boost:rd("extra_cleave_dmg")
	local r_uncap = reaper_boost:rd("total_uncapped") + reaper_boost:rd("extra_cleave_uncapped")
	ui.text(gui, "Reikland Reaper", x, row_y(2 + off), FONT_SIZE, ui.white)
	ui.text(gui, string.format("%.0f", r_total), x + L20_TOTAL_COL, row_y(2 + off), FONT_SIZE, ui.white)
	ui.text(gui, string.format("%.0f", r_uncap), x + L20_UNCAP_COL, row_y(2 + off), FONT_SIZE, ui.white)
	ui.text(gui, string.format("%.0f", kget("reaper").real_total), x + L20_REAL_COL, row_y(2 + off), FONT_SIZE, ui.white)

	-- Enhanced Training: +20% AS on a >=3-target proc (TB threshold) vs base +10%@>=3.
	local et_extra = et_track.sim:extra() - base_track.sim:extra()
	ui.text(gui, "Enhanced Training", x, row_y(3 + off), FONT_SIZE, ui.white)
	ui.text(gui, string.format("%.0f", et_extra), x + L20_TOTAL_COL, row_y(3 + off), FONT_SIZE, ui.white)
	ui.text(gui, "ESTIMATION", x + L20_UNCAP_COL, row_y(3 + off), small, ui.grey)
	ui.text(gui, "-", x + L20_REAL_COL, row_y(3 + off), FONT_SIZE, ui.white)

	-- Strike Together: extra damage (you + allies) from single-enemy PS procs over >=3.
	ui.text(gui, "Strike Together", x, row_y(4 + off), FONT_SIZE, ui.white)
	ui.text(gui, string.format("%.0f", st_total()), x + L20_TOTAL_COL, row_y(4 + off), FONT_SIZE, ui.white)
	ui.text(gui, "ESTIMATION", x + L20_UNCAP_COL, row_y(4 + off), small, ui.grey)
	ui.text(gui, "-", x + L20_REAL_COL, row_y(4 + off), FONT_SIZE, ui.white)

	-- Uptime comparison: base Paced Strikes (>=3) vs Strike Together's single-enemy proc.
	ui.text(gui, string.format("Paced Strikes uptime: base %.0f%%  vs  Strike Together %.0f%%",
		uptime_pct(base_track), uptime_pct(st_track)), x, row_y(5 + off), small, ui.grey)

	if not show_extra then return end

	ui.text(gui, string.format("Reaper sources: Melee +%.0f  Ranged +%.0f  Other +%.0f dmg",
		reaper_boost:rd("src_melee"), reaper_boost:rd("src_ranged"), reaper_boost:rd("src_other")),
		x, row_y(6 + off), small, ui.grey)

	local r_line
	if mod._gameplay_on("force_ep") then
		r_line = string.format("Reaper cleave: +%d units, +%.0f dmg  (without +cleave: %.0f)",
			reaper_boost:units_hit(), reaper_boost:rd("extra_cleave_dmg"), reaper_boost:rd("total_dmg"))
	else
		r_line = string.format("Reaper cleave (est): +%d units  (without +cleave: %.0f)",
			reaper_boost:units_hit(), reaper_boost:rd("total_dmg"))
	end
	ui.text(gui, r_line, x, row_y(7 + off), small, ui.grey)

	-- Strike Together split: your own single-enemy-proc damage vs the allies' share.
	local you = st_track.sim:extra() - base_track.sim:extra()
	local allies = st_total() - you
	ui.text(gui, string.format("Strike Together: you +%.0f dmg  allies +%.0f dmg", you, allies),
		x, row_y(8 + off), small, ui.grey)

	-- Per-ally breakdown (extra damage each ally got from the single-enemy proc windows).
	if #ally_lines == 0 then
		ui.text(gui, "Strike Together: no ally hits recorded yet (host only).",
			x, row_y(9 + off), small, ui.grey)
	else
		for i = 1, #ally_lines do
			ui.text(gui, string.format("ST %s: +%.0f dmg", ally_lines[i].name, ally_lines[i].extra),
				x, row_y(8 + off + i), small, ui.grey)
		end
	end
end

-- Show the TB version of the GUI when the Tourney Balance mod is running, else the
-- vanilla one.
function M.draw(gui)
	if tb_mod_active() then
		draw_tb(gui)
	else
		draw_vanilla(gui)
	end
end

return M
