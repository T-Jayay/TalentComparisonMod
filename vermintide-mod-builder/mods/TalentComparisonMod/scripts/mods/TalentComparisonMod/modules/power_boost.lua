-- power_boost.lua
-- ============================================================================
-- Reusable valuation for any talent that MULTIPLIES the local player's power
-- level by (1 + mult). Centralises everything the level-15 "Enhanced Power"
-- column used to do inline, so a second talent can reuse it verbatim with a
-- different power value:
--   * extra damage the boost adds to every hit (all sources: melee/ranged/DoT),
--     with overkill removed (Total), first-unit-only (First) and raw (Uncapped);
--   * that extra split by source (melee / ranged / other);
--   * the extra CLEAVE the higher power opens up -- as a rough estimate, or, with
--     the general "force cleave" button on, by physically extending the real
--     sweep so the extra units are actually hit and their damage measured.
--
-- Two boosts currently use it:
--   Enhanced Power  (level 15) : mult 0.075, always active.
--   Reikland Reaper (level 20) : mult 0.15, active ONLY while base Paced Strikes
--                                is up (its proc gate), so its `gate` predicate
--                                returns false otherwise and nothing is credited.
--
-- The boost re-runs the game's own calculate_damage with its multiplier injected
-- on the SCALED power (via the level-15 ActionUtils.apply_buffs_to_power_level
-- hook + `M.recompute_mult`), exactly where a real "power_level" stat buff applies
-- (after the difficulty cap and diff-ratio compression), so results respect armour
-- breakpoints instead of being a naive flat +mult.
--
-- Ownership: the level-15 module dofiles this once and shares the single instance
-- registry via mod._power_boost; every boost registers itself with M.register so
-- the shared level-15 sweep/cleave hooks drive them all. Per-hit crediting is
-- called from each owning module (EP from level 15, Reaper from level 20) so each
-- keeps its own dedupe/gating.
-- ============================================================================

local M = {}

-- Registered boost instances, iterated by the shared sweep/cleave hooks.
M.instances = {}

-- Non-nil only while a boost re-runs calculate_damage; the level-15
-- apply_buffs_to_power_level hook multiplies the SCALED power by this. Only one
-- recompute runs at a time (a plain, non-reentrant pcall), so a single field is
-- safe and replaces the old ep_recompute_mult / mod._l20_power_mult pair.
M.recompute_mult = nil

-- Per-unit-category bucketing (set by the level-15 module in init). cat_fn maps a
-- unit -> "elite"|"special"|"mon"|"trash"; enabled_fn(cat) reports whether that
-- category is currently displayed (multi-select filter).
M.cat_fn = function () return "trash" end
M.enabled_fn = function () return true end
function M.set_category_fns(cat_fn, enabled_fn)
	M.cat_fn = cat_fn or M.cat_fn
	M.enabled_fn = enabled_fn or M.enabled_fn
end

local CATS = { "elite", "special", "mon", "trash" }
local function bkt() return { elite = 0, special = 0, mon = 0, trash = 0 } end
local function badd(b, cat, v) b[cat or "trash"] = (b[cat or "trash"] or 0) + (v or 0) end
-- Sum a bucket over the categories the current filter selects.
local function bread(b)
	if type(b) == "number" then return b end
	if not b then return 0 end
	local sum = 0
	for _, c in ipairs(CATS) do
		if M.enabled_fn(c) then sum = sum + (b[c] or 0) end
	end
	return sum
end

-- ---------------------------------------------------------------------------
-- Shared helpers (mirror the other modules).
-- ---------------------------------------------------------------------------
local function local_player_unit()
	if not Managers.player then return nil end
	local ok, player = pcall(function () return Managers.player:local_player() end)
	if not ok or not player then return nil end
	return player.player_unit
end

-- Overkill accounting: portion of `extra` that lands while the unit still had HP.
local function useful_extra(baseline, extra, H)
	if not H then return extra end
	local lo = math.min(baseline, H)
	local hi = math.min(baseline + extra, H)
	local u = hi - lo
	if u < 0 then u = 0 end
	if u > extra then u = extra end
	return u
end
M.useful_extra = useful_extra

-- Re-run calculate_damage with `mult` injected on the scaled power; returns the
-- recomputed final, or ctx.final on failure. ctx carries the unhooked `func` plus
-- every calculate_damage argument (built by the level-15 calculate_damage hook).
local function recompute(ctx, mult)
	M.recompute_mult = mult
	local ok, v = pcall(ctx.func, ctx.damage_output, ctx.target_unit, ctx.attacker_unit,
		ctx.hit_zone_name, ctx.original_power_level, ctx.boost_curve, ctx.boost_damage_multiplier,
		ctx.is_critical_strike, ctx.damage_profile, ctx.target_index, ctx.backstab_multiplier, ctx.damage_source)
	M.recompute_mult = nil
	if ok and type(v) == "number" then return v end
	return ctx.final
end

-- ---------------------------------------------------------------------------
-- Boost instance.
--   cfg = {
--     mult            = number,             -- e.g. 0.075 (EP) or 0.15 (Reaper)
--     buff_type       = string | nil,       -- has_buff_type() name -> "already equipped"
--     talent_equipped = function(unit)->bool| nil, -- equipped detector (defaults to buff_type)
--     gate            = function()->bool | nil,     -- boost currently in effect? (default true)
--     force_enabled   = function()->bool | nil,     -- is the general force-cleave button on?
--   }
-- ---------------------------------------------------------------------------
local Boost = {}
Boost.__index = Boost

function M.new(cfg)
	local self = setmetatable({}, Boost)
	-- `mult` may be a number or a function()->number (so a boost whose value
	-- depends on which balance mod is loaded -- e.g. Enhanced Power is 0.075
	-- vanilla / 0.10 under Tourney Balance -- can resolve it live per hit/sweep).
	self.mult = cfg.mult
	self.buff_type = cfg.buff_type
	self.force_enabled = cfg.force_enabled or function () return false end
	-- Cleave-only boosts (no per-hit account_hit) can opt in to measuring their OWN
	-- extra cleave while EQUIPPED -- the real sweep already ran wider, so we credit
	-- the real damage of units it reached beyond the no-boost baseline. Boosts with a
	-- per-hit column (Enhanced Power, More the Merrier) must NOT set this, or those
	-- units would be double-counted (per-hit delta + full cleave damage).
	self.measure_equipped = cfg.measure_equipped or false
	self.gate = cfg.gate or function () return true end
	self.talent_equipped = cfg.talent_equipped or function (unit)
		if not self.buff_type then return false end
		local be = ScriptUnit.has_extension(unit, "buff_system")
		return be and be:has_buff_type(self.buff_type) or false
	end
	self:reset()
	return self
end

function M.register(boost)
	M.instances[#M.instances + 1] = boost
	return boost
end

function Boost:reset()
	-- Extra damage (overkill-accounted / first / raw) and its source split. Each is a
	-- per-category bucket {elite,special,mon,trash}; reads go through Boost:rd (filter-aware).
	self.total_dmg = bkt()
	self.first_dmg = bkt()
	self.total_uncapped = bkt()
	self.src_melee = bkt()
	self.src_ranged = bkt()
	self.src_other = bkt()
	-- Extra cleave: units only this boost's higher power reached, and their damage.
	self.extra_units_hit = bkt()
	self.extra_cleave_dmg = bkt()
	self.extra_cleave_uncapped = bkt()
	-- Rough estimate of extra units (force-cleave OFF): no target unit is known, so it
	-- is category-agnostic and only surfaces under the "All" filter.
	self.extra_units_est = 0
	-- Per-sweep force-cleave state (armed by M.run_sweep, read by M.run_classify).
	self.base_mass = nil       -- no-boost cleave-mass budget for the current sweep
	self.cur_sweep = nil       -- the ActionSweep instance we forced
	self.budget = nil          -- this boost's own cleave-mass budget (for classify)
	self.extra_units = {}       -- unit -> true: reached ONLY via this boost's budget
	self.natural = nil         -- true when the boost is EQUIPPED and we are measuring
	                           -- the real (already-boosted) sweep's own extra cleave
end

-- Filter-aware read of a bucketed accumulator field (e.g. "total_dmg").
function Boost:rd(field)
	return bread(self[field])
end

-- Extra units this boost reached: the measured/forced count (filtered) plus, only
-- when EVERY category is enabled, the rough estimate (which has no unit category).
function Boost:units_hit()
	local n = bread(self.extra_units_hit)
	local all_on = true
	for _, c in ipairs(CATS) do if not M.enabled_fn(c) then all_on = false break end end
	if all_on then n = n + (self.extra_units_est or 0) end
	return n
end

-- Resolve the current multiplier (number, or a function evaluated live).
function Boost:cur_mult()
	if type(self.mult) == "function" then return self.mult() end
	return self.mult
end

-- Whether the boost's damage would currently apply to a hit by `attacker_unit`
-- (gate up, i.e. its proc condition met). Used by callers to skip crediting.
function Boost:active()
	return self.gate()
end

-- Credit this hit's extra damage. ctx = the calculate_damage context; is_melee /
-- first / health precomputed by the caller (which also owns melee dedupe). Returns
-- the uncapped extra (for the caller's debug logs), 0 if nothing credited.
function Boost:account_hit(ctx, is_melee, first, health)
	if not self.gate() then return 0 end
	local final = ctx.final
	if not final or final <= 0 then return 0 end
	local equipped = self.talent_equipped(ctx.attacker_unit)
	local mult = self:cur_mult()
	local base, extra
	if equipped then
		-- Boost is on: its power is already baked into `final`. Recompute WITHOUT
		-- it (x 1/(1+mult) on scaled power) and report the slice it added.
		base = recompute(ctx, 1.0 / (1.0 + mult))
		extra = final - base
	else
		-- Boost is off: recompute WITH it and report what equipping would add.
		base = final
		extra = recompute(ctx, 1.0 + mult) - final
	end
	if extra <= 0 then return 0 end
	local capped = useful_extra(base, extra, health)
	local cat = M.cat_fn(ctx.target_unit)
	badd(self.total_uncapped, cat, extra)
	badd(self.total_dmg, cat, capped)
	if first then badd(self.first_dmg, cat, capped) end
	if ctx.damage_profile.is_dot then
		badd(self.src_other, cat, capped)
	elseif is_melee then
		badd(self.src_melee, cat, capped)
	else
		badd(self.src_ranged, cat, capped)
	end
	return extra
end

-- If `target_unit` was reached ONLY by this boost's forced cleave, credit it to
-- the cleave counters and return true (caller must then skip its own per-hit
-- accounting for that unit). Callers dedupe melee before calling this.
function Boost:account_cleave_unit(target_unit, final, health)
	if not self.extra_units[target_unit] then return false end
	local cat = M.cat_fn(target_unit)
	badd(self.extra_units_hit, cat, 1)
	badd(self.extra_cleave_dmg, cat, useful_extra(0, final, health))
	badd(self.extra_cleave_uncapped, cat, final)
	return true
end

-- True if any registered boost forced the current sweep to reach `unit` (a unit
-- that would NOT be hit without a boost), so callers can skip crediting it to
-- non-cleave talents that measure only hits which would land anyway.
function M.is_forced_extra(unit)
	for _, b in ipairs(M.instances) do
		-- Only boosts that FORCED the sweep wider (not equipped) hide the unit from
		-- other talents. A `natural` (equipped) boost's extra units are real hits that
		-- happened in reality, so they must still feed every talent's per-hit columns.
		if not b.natural and b.extra_units[unit] then return true end
	end
	return false
end

-- Credit a genuine (already-landed, deduped) melee hit to any EQUIPPED boost that
-- reached this unit only via its own cleave power -- i.e. the real damage that boost
-- actually contributed this sweep. Does not skip other talents (the hit is real).
function M.account_natural_extra(target_unit, final, health)
	for _, b in ipairs(M.instances) do
		if b.natural then b:account_cleave_unit(target_unit, final, health) end
	end
end

-- ---------------------------------------------------------------------------
-- Shared sweep / cleave hooks (called once per sweep from the level-15 module,
-- for ALL registered boosts). Because several boosts could want to force the same
-- sweep to different budgets, the real sweep is extended to the OVERALL max and
-- each boost classifies only the units inside its OWN band (base < mass <= budget).
-- ---------------------------------------------------------------------------
function M.run_sweep(sweep, power_level, owner_unit, buff_ext)
	local dp = sweep._damage_profile
	local attack_type = dp and dp.charge_value
	if attack_type ~= "light_attack" and attack_type ~= "heavy_attack" then
		return false, nil
	end

	local difficulty_level = Managers.state.difficulty:get_difficulty()
	local cpl = ActionUtils.scale_power_levels(power_level, "cleave", owner_unit, difficulty_level)
	cpl = buff_ext:apply_buffs_to_value(cpl, "power_level_melee")
	-- No-boost baseline budget (deliberately no power_level_melee_cleave, so the
	-- baseline is "no power-boost talent" regardless of what is equipped).
	local base_attack = ActionUtils.get_max_targets(dp, cpl) or 1
	base_attack = buff_ext:apply_buffs_to_value(base_attack, "increased_max_targets")

	local max_attack, max_impact
	for _, b in ipairs(M.instances) do
		b.base_mass = nil
		b.cur_sweep = nil
		b.budget = nil
		b.natural = nil
		table.clear(b.extra_units)

		-- Skip a boost that is inactive.
		local equipped = b.talent_equipped(owner_unit)
		if b.gate() and equipped and b.measure_equipped then
			-- Boost IS equipped: the real sweep already cleaves at the boosted budget.
			-- Measure the boost's OWN contribution by classifying which of the real
			-- hits landed beyond the no-boost baseline mass -- those units only got hit
			-- because of this boost. No sweep extension (it already happened); budget is
			-- open (the real sweep already caps how far it reaches).
			b.base_mass = base_attack
			b.cur_sweep = sweep
			b.budget = math.huge
			b.natural = true
		elseif b.gate() and not equipped then
			local ua, ui2 = ActionUtils.get_max_targets(dp, cpl * (1 + b:cur_mult()))
			ua = buff_ext:apply_buffs_to_value(ua or 1, "increased_max_targets")
			ui2 = buff_ext:apply_buffs_to_value(ui2 or 1, "increased_max_targets")
			if b.force_enabled() then
				b.base_mass = base_attack
				b.cur_sweep = sweep
				b.budget = ua
				max_attack = math.max(max_attack or 0, ua)
				max_impact = math.max(max_impact or 0, ui2)
			else
				-- Hypothetical estimate: how many extra units this boost would reach.
				-- Rough (mass budgets read as unit counts; exact only for mass-1 foes).
				local extra = math.floor(ua) - math.floor(base_attack)
				if extra > 0 then b.extra_units_est = (b.extra_units_est or 0) + extra end
			end
		end
	end

	if max_attack then
		sweep._max_targets_attack = max_attack
		sweep._max_targets_impact = max_impact
		sweep._max_targets = math.max(max_attack, max_impact)
		return true, base_attack
	end
	return false, base_attack
end

-- ActionSweep._calculate_hit_mass classifier: mark units each boost reached ONLY
-- via its forced budget (base < pre-hit mass <= that boost's own budget).
function M.run_classify(sweep, hit_unit)
	local mass_before = sweep._amount_of_mass_hit
	if not mass_before then return end
	for _, b in ipairs(M.instances) do
		if sweep == b.cur_sweep and b.base_mass and b.budget
			and mass_before > b.base_mass
			and mass_before <= b.budget then
			b.extra_units[hit_unit] = true
		end
	end
end

M.local_player_unit = local_player_unit

return M
