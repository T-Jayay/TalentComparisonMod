-- dot_sim.lua
-- ============================================================================
-- Reusable damage-over-time PROJECTION engine, shared by any talent group that
-- needs to value a DoT that a talent WOULD apply -- without actually applying it
-- (no gameplay change). It owns NO talent knowledge: the caller feeds it, per
-- application, the DoT's per-tick damage (already computed for that hit) and the
-- affected unit; the sim then projects ticks forward on that unit's own timeline,
-- exactly as the game's DoT scheduler would, until the unit dies.
--
-- THE MODEL (same spirit as the Lingering-Flames projection in level10_bw)
--   A stacking DoT is described by three static numbers: `tick_interval` (seconds
--   between ticks), `duration` (how long one application lasts) and `max_stacks`.
--   Each application (apply) adds one stack (capped at max_stacks) and refreshes
--   the whole DoT's expiry to now + duration (refresh_durations = true, the case
--   for weapon_bleed_dot_whc). While armed and non-empty, update() emits a tick
--   every `tick_interval`, each worth `tick_dmg * stacks` (all live stacks tick).
--   When the expiry passes with no re-application the stacks drop to 0. On the
--   unit's death / despawn the accumulated projected damage is banked.
--
--   Per unit we track the RAW projected sum and cap it against the unit's starting
--   HP so "Total" never over-counts past a kill (overkill removed); "Uncapped" is
--   the raw sum. Both are split by unit category (elite / special / mon / trash)
--   so a filter can sum any subset, exactly like attack_speed_sim.
--
--   This is an UPPER-BOUND ESTIMATE: it assumes every projected tick lands (the
--   real DoT can be cut short by the enemy dying to other damage, which the cap
--   partly captures, or by stacks expiring between re-applications, which the
--   timeline captures). It never touches gameplay, so it is equip-independent:
--   the value is the same whether or not the talent that grants the DoT is on.
--
-- One sim instance models one DoT template; the caller supplies tick_dmg per
-- application (it can vary per hit -- power/armour/breakpoints), and the sim uses
-- the latest supplied value for that unit's ongoing ticks.
-- ============================================================================

local M = {}
M.__index = M

local CATS = { "elite", "special", "mon", "trash" }
M.enabled_fn = function () return true end
function M.set_filter(fn) M.enabled_fn = fn or M.enabled_fn end

-- opts = { tick_interval, duration, max_stacks }
function M.new(opts)
	opts = opts or {}
	local self = setmetatable({}, M)
	self.tick_interval = opts.tick_interval or 0.75
	self.duration      = opts.duration or 2.0
	self.max_stacks    = opts.max_stacks or 1
	self:reset()
	return self
end

local function new_pair() return { total = 0, uncap = 0 } end
local function fresh_cat()
	return { elite = new_pair(), special = new_pair(), mon = new_pair(), trash = new_pair() }
end

function M:reset()
	self.units  = {}          -- unit -> per-unit projection state
	self.banked = fresh_cat() -- finished units' extra, per category
end

-- Register (or refresh) a DoT application on `unit`. `tick_dmg` is the per-tick,
-- per-stack damage for this application; `hp0` the unit's current/starting HP for
-- the overkill cap; `cat` its unit category; `now` game time.
function M:apply(unit, tick_dmg, now, hp0, cat)
	if not tick_dmg or tick_dmg <= 0 then return end
	local st = self.units[unit]
	if not st then
		st = { stacks = 0, expiry = 0, timer = 0, tick_dmg = tick_dmg,
			hp0 = hp0 or math.huge, cat = cat or "trash", sum = 0 }
		self.units[unit] = st
	end
	st.tick_dmg = tick_dmg
	st.cat = cat or st.cat
	if hp0 and hp0 > 0 then st.hp0 = hp0 end
	st.stacks = math.min(st.stacks + 1, self.max_stacks)
	st.expiry = now + self.duration
end

-- Advance every live projection by dt. `now` = game time; `alive_fn(unit)` returns
-- true while the unit is still alive (dead/despawned units are banked and dropped).
function M:update(dt, now, alive_fn)
	if not next(self.units) then return end
	for unit, st in pairs(self.units) do
		local alive = alive_fn(unit)
		if not alive then
			self:_bank(unit, st)
		else
			-- Expired (no re-application within `duration`): stacks fall off.
			if st.stacks > 0 and now >= st.expiry then
				st.stacks = 0
				st.timer = 0
			end
			if st.stacks > 0 and st.tick_dmg and st.tick_dmg > 0 then
				st.timer = st.timer + dt
				while st.timer >= self.tick_interval do
					st.timer = st.timer - self.tick_interval
					if st.sum < st.hp0 then
						st.sum = st.sum + st.tick_dmg * st.stacks
					end
				end
			end
		end
	end
end

function M:_bank(unit, st)
	self.units[unit] = nil
	local b = self.banked[st.cat]
	if not b then return end
	b.total = b.total + math.min(st.sum, st.hp0)
	b.uncap = b.uncap + st.sum
end

-- Drop a unit without banking (e.g. the caller detected a corpse contact).
function M:forget(unit)
	self.units[unit] = nil
end

-- Projected DoT damage this run over the filter-enabled categories: `total` is
-- overkill-capped (against each unit's HP), `uncap` is the raw sum. Includes both
-- banked (finished) units and the current live projections.
function M:totals()
	local total, uncap = 0, 0
	for _, c in ipairs(CATS) do
		if M.enabled_fn(c) then
			total = total + self.banked[c].total
			uncap = uncap + self.banked[c].uncap
		end
	end
	for _, st in pairs(self.units) do
		if M.enabled_fn(st.cat) then
			total = total + math.min(st.sum, st.hp0)
			uncap = uncap + st.sum
		end
	end
	return total, uncap
end

return M
