-- kill_tracker.lua
-- ============================================================================
-- Reusable, talent-agnostic KILL / REAL-TOTAL tracking, extracted from the level-15
-- module so every damage panel (level 15 stagger talents, level 10 WHC, level 10 /
-- 20 Mercenary) can report the same three kill-aware figures per talent:
--   n          -- EARLY KILLS: units the talent's extra damage finished sooner than
--                 the no-talent world (latched once per unit).
--   saved_*    -- HITS SAVED/KILL: running average (over EVERY unit you actually killed)
--                 of how many fewer hits the talent's world needed vs reality -- the real
--                 hits-to-kill minus the hit at which the talent's cumulative damage would
--                 have finished it. A talent that changes nothing reads 0.00, so this is
--                 an unbiased, directly comparable measure (unlike hpk_*, which averaged
--                 only the self-selected subset of units the talent's world finished --
--                 flattering do-nothing talents and inflating strong ones; see below).
--   hpk_*      -- HITS/KILL (legacy, no longer displayed): running average hits-to-kill in
--                 the talent's world over only the units the talent's world reached.
--   real_total -- REAL TOTAL: of the extra damage banked into units, how much actually
--                 contributed to pulling a kill sooner (baseline-overkill discounted).
--
-- Each panel owns ONE tracker instance (M.new) holding its own per-talent `kills`
-- and per-unit accumulators, so a panel's Reset zeroes only its own rows.
--
-- CALIBRATION AGAINST REAL DAMAGE (shared queue). calculate_damage's return -- what
-- the callers model their without/with worlds from -- is BEFORE apply_buffs_to_damage
-- and the on_damage_dealt procs, so any post-calc attacker buff (e.g. Slayer stack
-- damage) is invisible to it. Kill-tracking is therefore DEFERRED: for each genuine
-- hit the level-15 calculate_damage hook opens a batch (M.begin_hit), every panel's
-- tracker appends its per-talent {without, with} pairs to it (tracker:add), and the
-- batch is committed (M.commit_hit). The health-extension add_damage hook then runs
-- with the REAL applied damage and calls M.on_real_damage, which pops the oldest batch
-- for that unit, scales every modeled world by K = real / model_final (talent-
-- independent, so exact) and runs the per-talent kill-tracking. Any batch whose real
-- add_damage never arrives (unhooked breed, 0-damage/immune hit) is stale-flushed at
-- K = 1 by M.update -- the raw-model fallback, so no hit is silently dropped.
--
-- The batch/queue is GLOBAL (one genuine hit -> one add_damage -> one batch), while the
-- `kills`/`unit_state` accumulators are PER INSTANCE, so several panels share the same
-- real-damage calibration without their totals interfering.
-- ============================================================================

local M = {}

-- Per-unit-category display filter. Set via M.set_filter to an enabled(cat)->bool
-- predicate so the read-side (:get) can merge the categories the multi-select filter
-- selects. Defaults to every category on until wired.
local function default_filter() return true end
M._filter = default_filter
function M.set_filter(fn) M._filter = fn or default_filter end

local CATS = { "elite", "special", "mon", "trash" }

local function game_time()
	local ok, t = pcall(function () return Managers.time:time("game") end)
	if ok and t then return t end
	return 0
end

local PENDING_STALE = 0.5   -- s; flush unmatched hits (K=1) if no add_damage arrives

-- Global pending queue: target_unit -> FIFO list of batches. A batch is
--   { target, model_final, health, t, entries = { {tracker, talent, without, with}, ... } }
local pending = {}
local cur_batch = nil   -- the batch currently being built (between begin_hit/commit_hit)

-- ---------------------------------------------------------------------------
-- Tracker instance (one per panel).
-- ---------------------------------------------------------------------------
local Tracker = {}
Tracker.__index = Tracker

function M.new()
	local self = setmetatable({}, Tracker)
	-- Kills partitioned by unit category: kills[cat][talent] -> {n,saved_sum,saved_n,hpk_sum,hpk_n,real_total}.
	-- Each unit belongs to exactly one category, so no double counting.
	self.kills = { elite = {}, special = {}, mon = {}, trash = {} }
	self.unit_state = {}  -- target_unit -> per-unit accumulators (see :track)
	return self
end

-- The kills record for `talent` in category `cat`, lazily created.
function Tracker:rec(cat, talent)
	local bucket = self.kills[cat] or self.kills.trash
	local r = bucket[talent]
	if not r then
		r = { n = 0, saved_sum = 0, saved_n = 0, hpk_sum = 0, hpk_n = 0, real_total = 0 }
		bucket[talent] = r
	end
	return r
end

-- Read-only accessor for draw: the talent's kills merged over the categories the
-- current filter selects. Always returns a record (zeros before any credit).
function Tracker:get(talent)
	local out = { n = 0, saved_sum = 0, saved_n = 0, hpk_sum = 0, hpk_n = 0, real_total = 0 }
	for _, cat in ipairs(CATS) do
		if M._filter(cat) then
			local r = self.kills[cat] and self.kills[cat][talent]
			if r then
				out.n = out.n + r.n
				out.saved_sum = out.saved_sum + r.saved_sum
				out.saved_n = out.saved_n + r.saved_n
				out.hpk_sum = out.hpk_sum + r.hpk_sum
				out.hpk_n = out.hpk_n + r.hpk_n
				out.real_total = out.real_total + r.real_total
			end
		end
	end
	return out
end

function Tracker:reset()
	self.kills = { elite = {}, special = {}, mon = {}, trash = {} }
	self.unit_state = {}
end

-- Drop a unit's accumulators (called when a hit finds it already dead, so its
-- earlier-kill state can never be credited again).
function Tracker:forget(target_unit)
	self.unit_state[target_unit] = nil
end

-- Accumulate one hit's damage for `talent` on `target_unit`. Does three things:
--  1. EARLY KILL: if this hit is the one that pulls the kill earlier than the
--     no-talent world (talent cumulative >= threshold while baseline still below),
--     credit an earlier kill and FREEZE the talent's hits-to-kill for this unit.
--  2. REAL TOTAL: at the talent-world killing hit, bank the extra that was actually
--     useful for pulling the kill sooner (baseline-overkill discounted).
--  3. HITS/KILL: when this is YOUR real killing blow on the unit (`real_kill`),
--     record hits-to-kill for the running average -- the unit's real hits to die,
--     but capped at the talent's frozen early-kill hit if the talent would have
--     finished it sooner. Latched once per unit per talent.
--   without_add : damage this hit deals in the talent's BASELINE world.
--   with_add    : damage this hit deals in the talent's world (baseline + extra).
--   health      : the target's real pre-hit HP (nil -> skip the crossing check,
--                 threshold unknown, but keep accumulating for later hits).
--   real_kill   : true if THIS hit is the real killing blow you landed on the unit.
--   model_extra : unused (kept for caller compatibility).
function Tracker:track(target_unit, talent, without_add, with_add, health, real_kill, cat, model_extra)
	local st = self.unit_state[target_unit]
	if not st then
		st = { init = health, cat = cat or "trash", with = {}, without = {}, counted = {}, hits = {},
			frozen = {}, real_counted = {} }
		self.unit_state[target_unit] = st
	end
	cat = cat or st.cat or "trash"
	if not st.init and health then st.init = health end
	local h = (st.hits[talent] or 0) + 1
	st.hits[talent] = h
	local w  = (st.with[talent] or 0) + with_add
	local wo = (st.without[talent] or 0) + without_add
	st.with[talent], st.without[talent] = w, wo
	local kills = self:rec(cat, talent)
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
			kills.n = kills.n + 1
		end
		-- REAL TOTAL: of the extra damage banked into this unit, how much actually
		-- contributed to killing it sooner -- the baseline shortfall at the talent-
		-- world killing hit, init - without_total. If the baseline also crosses on
		-- this hit (wo >= init, not an early kill) that's <= 0 -> nothing credited.
		-- On an early kill it is exactly the extra needed to bridge the gap, incl.
		-- the killing hit's own share (w >= init guarantees it never exceeds the
		-- w - wo actually banked), so every Early Kill credits a positive amount.
		local real = st.init - wo
		if real > 0 then
			kills.real_total = kills.real_total + real
		end
	end
	if real_kill and not st.real_counted[talent] then
		st.real_counted[talent] = true
		-- HITS SAVED/KILL, averaged over EVERY unit you actually killed (unbiased
		-- denominator). `h` is the real hits-to-kill (every talent is fed a pair on
		-- every hit, so its hit counter equals reality); `frozen[talent]` is the hit at
		-- which the talent's cumulative damage would have finished the unit. Units the
		-- talent's world did NOT finish sooner (frozen nil, or frozen == h) save 0 --
		-- we fall back to `h` so those kills still count in the average at 0, instead of
		-- being dropped. Dropping them (the old Hits/Kill column) let a do-nothing talent
		-- like Bulwark average only the easy few-hit kills its ~0 extra happened to cross
		-- and silently exclude the hard multi-hit units, reading a deceptively low value.
		local frozen = st.frozen[talent] or h
		local saved = h - frozen
		if saved < 0 then saved = 0 end
		kills.saved_sum = kills.saved_sum + saved
		kills.saved_n   = kills.saved_n + 1
		-- Legacy Hits/Kill (no longer displayed): kept for the DBG log / callers.
		local sample = st.frozen[talent]
		if sample then
			kills.hpk_sum = kills.hpk_sum + sample
			kills.hpk_n   = kills.hpk_n + 1
		end
	end
end

-- Append this hit's baseline/with pair for `talent` to the current batch (opened by
-- M.begin_hit). No-op if no batch is open (e.g. a duplicate/deduped calculate_damage
-- call for which the caller adds nothing).
function Tracker:add(talent, without, with)
	if not cur_batch then return end
	local e = cur_batch.entries
	e[#e + 1] = { tracker = self, talent = talent, without = without, ["with"] = with }
end

-- ---------------------------------------------------------------------------
-- Global batch / queue (driven by the level-15 hooks).
-- ---------------------------------------------------------------------------

-- Open a batch for one genuine hit. `model_final` is the calculate_damage return the
-- callers model from; `health` is the target's pre-hit HP.
function M.begin_hit(target_unit, model_final, health, cat)
	cur_batch = { target = target_unit, model_final = model_final, health = health,
		cat = cat or "trash", t = game_time(), entries = {} }
end

-- Close the current batch, enqueuing it (per target) only if any tracker added to it.
function M.commit_hit()
	local b = cur_batch
	cur_batch = nil
	if not b or #b.entries == 0 then return end
	local q = pending[b.target]
	if not q then q = {}; pending[b.target] = q end
	q[#q + 1] = b
end

-- Run kill-tracking for the oldest pending batch on `target_unit`, scaling every
-- modeled world by K = real_damage / model_final (talent-independent) so the kill
-- threshold crossing matches reality. real_damage nil (stale flush) -> K = 1.
local function flush(target_unit, real_damage)
	local q = pending[target_unit]
	if not q or #q == 0 then return false end
	local b = table.remove(q, 1)
	if #q == 0 then pending[target_unit] = nil end
	local K = 1
	if real_damage and b.model_final and b.model_final > 0 then
		K = real_damage / b.model_final
	end
	local real_kill = b.health and real_damage and (b.health - real_damage <= 0) or false
	for _, e in ipairs(b.entries) do
		e.tracker:track(target_unit, e.talent, e.without * K, e["with"] * K, b.health, real_kill, b.cat,
			e["with"] - e.without)
	end
	return true
end
M.flush = flush

-- Called from the health-extension add_damage hook with the REAL applied damage.
function M.on_real_damage(target_unit, real_damage)
	flush(target_unit, real_damage)
end

-- Stale-flush any batches whose real add_damage never arrived (K = 1, raw model).
function M.update(now)
	if not next(pending) then return end
	now = now or game_time()
	for target, q in pairs(pending) do
		while q[1] and (now - q[1].t) >= PENDING_STALE do
			flush(target, nil)
			if pending[target] ~= q then break end
		end
	end
end

-- Drop all queued batches (mission entry / global reset).
function M.clear_pending()
	for k in pairs(pending) do pending[k] = nil end
	cur_batch = nil
end

return M
