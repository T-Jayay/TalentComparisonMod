-- attack_speed_sim.lua
-- ============================================================================
-- Reusable attack-speed "ghost swing" simulator, shared by any talent group that
-- needs to value an attack-speed change as extra (or lost) damage. It owns NO
-- talent knowledge: the caller feeds it the local player's real melee swings and,
-- per swing, the hypothetical attack-speed multiplier for the talent being modeled.
--
-- THE MODEL (index-domain zero-order-hold resample)
--   A talent that makes you attack faster does not change any hit's damage -- it
--   only lets more swings happen in the same time. So over a run its value is the
--   EXTRA swings it buys, each worth a representative real swing. We reconstruct
--   that as a resample of the real swing stream:
--
--     Keep a float cursor `pos`. Each real swing with speed multiplier m
--     (m = 1 + attack_speed_bonus; 1.0 = no change) advances the ghost timeline
--     by m and emits a ghost swing for every integer position in [pos, pos + m),
--     each valued at THAT swing's damage. Then pos += m.
--
--   Worked example (m = 1.2 throughout), real swings 10,5,8,0,20:
--     [0.0,1.2) -> 2 ghosts x10   [1.2,2.4) -> 1 x5   [2.4,3.6) -> 1 x8
--     [3.6,4.8) -> 1 x0           [4.8,6.0) -> 1 x20
--     ghost = 10,10,5,8,0,20 = 53 vs real 43  ->  extra = +10.
--
--   Properties that fall out for free:
--     * m = 1  -> exactly one ghost per swing -> zero extra (buff was down).
--     * No swing (idle) -> no advance -> NO phantom damage. Ghosts only ever
--       accrue in proportion to swings that actually happened, so an attack-speed
--       buff registers as extra damage only from the first real swing onward.
--     * m < 1 (attack-speed DECREASE) -> some windows contain no integer -> those
--       swings are dropped, so the same code yields the (negative) inverse case.
--     * Front-loaded exactly like the timeline model: the extra swing early in a
--       burst carries the value held at that point, not the burst's last value.
--
--   Assumption (documented): every swing's freed time is spent on another swing of
--   representative value -- i.e. 100% attack utilization. This makes the extra an
--   UPPER BOUND on the attack-speed talent's value, in the same spirit as the THP
--   panel's Decayed column. Over a long sample the per-swing values average out.
--
-- The sim is damage/target agnostic: `damage` is the swing's TOTAL real damage
-- across everything it cleaved (whiffs are 0-damage swings, which still advance the
-- cadence). One sim instance models one hypothetical talent; run several in
-- parallel over the same swing stream to compare talents.
-- ============================================================================

local M = {}
M.__index = M

-- Per-unit-category support. Each swing's damage is split by the category of the
-- unit(s) it hit (es / mon / trash), so a ghost swing carries only the damage on the
-- selected category -- "only records the hits on each specific unit type". The
-- CADENCE (how many ghosts a swing spawns) is category-agnostic; only the damage each
-- ghost carries is split. extra() sums the categories the active filter selects.
local CATS = { "es", "mon", "trash" }
M.filter_fn = function () return "all" end
function M.set_filter(fn) M.filter_fn = fn or M.filter_fn end

-- Integers j with a <= j < b (the half-open window). Epsilon guards the float
-- boundaries so an exact integer edge lands in exactly one window, never both.
local EPS = 1e-9
local function count_int(a, b)
	return math.ceil(b - EPS) - math.ceil(a - EPS)
end

function M.new()
	local self = setmetatable({}, M)
	self:reset()
	return self
end

function M:reset()
	self.pos = 0.0          -- ghost-timeline cursor, in real-swing units
	self.real_dmg = { es = 0, mon = 0, trash = 0 }   -- real swing damage by category
	self.ghost_dmg = { es = 0, mon = 0, trash = 0 }  -- ghost (resampled) damage by category
	self.real_swings = 0
	self.ghost_swings = 0
end

-- Feed one real swing. `damage` = its real damage: either a number (all attributed
-- to "trash") or a per-category table {es=,mon=,trash=} split by the units it hit.
-- `m` = the speed multiplier this instance models for this swing (1.0 = buff down).
function M:add_swing(damage, m)
	m = m or 1
	if m <= 0 then m = 1e-3 end
	local ghosts = count_int(self.pos, self.pos + m)
	if ghosts < 0 then ghosts = 0 end
	self.pos = self.pos + m
	self.real_swings = self.real_swings + 1
	self.ghost_swings = self.ghost_swings + ghosts
	if type(damage) == "table" then
		for _, c in ipairs(CATS) do
			local d = damage[c] or 0
			self.real_dmg[c] = self.real_dmg[c] + d
			self.ghost_dmg[c] = self.ghost_dmg[c] + ghosts * d
		end
	else
		local d = damage or 0
		self.real_dmg.trash = self.real_dmg.trash + d
		self.ghost_dmg.trash = self.ghost_dmg.trash + ghosts * d
	end
end

-- Extra damage the modeled attack speed would have added this run (ghost - real),
-- summed over the categories the active filter selects. Negative for a decrease.
function M:extra()
	local f = M.filter_fn()
	local g, r = 0, 0
	for _, c in ipairs(CATS) do
		if f == "all" or f == c then
			g = g + self.ghost_dmg[c]
			r = r + self.real_dmg[c]
		end
	end
	return g - r
end

return M
