-- unit_filter.lua
-- ============================================================================
-- Shared per-unit-category bucketing + the global display filter, used by every
-- talent-comparison panel so a single set of filter buttons (on the control panel)
-- can switch ALL panels between showing only one enemy category or the sum.
--
-- THREE tracked categories (each unit belongs to exactly one):
--   "es"    -- Elites + Specials  (breed.elite or breed.special)
--   "mon"   -- Monsters + Bosses + Lords (breed.boss; lords are boss=true)
--   "trash" -- everything else (clanrats, marauders, fanatics, ...)
--
-- Every running total in the value modules is stored as a 3-slot bucket
-- ({es=,mon=,trash=}) instead of a scalar; F.add routes a credit into the slot
-- for the hit's category, and F.read sums the slot(s) the current filter selects.
-- Storing 3x the numbers is unavoidable: the filter switches at runtime, so all
-- categories must be retained simultaneously.
--
-- Filter state lives on `mod` (mod._unit_filter / mod._hide_all), each backed by a
-- persisted setting so it survives a relaunch. The control panel writes it; the
-- value modules only read it (indirectly, via F.read).
-- ============================================================================

local F = {}

local mod  -- set in init()

-- The valid filter values, in button order (control panel mirrors this).
F.FILTERS = { "all", "es", "mon", "trash" }
F.LABELS  = { all = "All", es = "Elites+Specials", mon = "Monsters", trash = "Trash" }

function F.init(owner_mod)
	mod = owner_mod
	-- Load persisted filter / hide state into the fast-access mod fields.
	local uf = mod:get("unit_filter")
	if uf ~= "all" and uf ~= "es" and uf ~= "mon" and uf ~= "trash" then uf = "all" end
	mod._unit_filter = uf
	local h = mod:get("hide_all")
	mod._hide_all = h == true
end

-- Persist + cache the current filter selection.
function F.set_filter(f)
	if f ~= "all" and f ~= "es" and f ~= "mon" and f ~= "trash" then return end
	mod._unit_filter = f
	mod:set("unit_filter", f)
end

function F.get_filter()
	return mod._unit_filter or "all"
end

-- Persist + cache the hide-all toggle.
function F.set_hidden(v)
	mod._hide_all = v and true or false
	mod:set("hide_all", mod._hide_all)
end

function F.toggle_hidden()
	F.set_hidden(not mod._hide_all)
end

function F.is_hidden()
	return mod._hide_all == true
end

-- ---------------------------------------------------------------------------
-- Category classification.
-- ---------------------------------------------------------------------------
-- Return "es" | "mon" | "trash" for a unit (nil / unknown breed -> "trash").
function F.cat_of_breed(breed)
	if not breed then return "trash" end
	if breed.boss then return "mon" end
	if breed.elite or breed.special then return "es" end
	return "trash"
end

function F.cat_of(unit)
	if not unit then return "trash" end
	local ok, breed = pcall(function () return AiUtils.unit_breed(unit) end)
	if not ok then return "trash" end
	return F.cat_of_breed(breed)
end

-- ---------------------------------------------------------------------------
-- Bucketed field storage.
-- ---------------------------------------------------------------------------
local function fresh_bucket()
	return { es = 0, mon = 0, trash = 0 }
end
F.fresh_bucket = fresh_bucket

-- Add `v` into rec[field]'s slot for category `cat` (lazily creating the bucket).
-- `cat` nil -> "trash".
function F.add(rec, field, cat, v)
	if not v or v == 0 then
		-- Still ensure the bucket exists so reads don't miss (cheap).
	end
	local b = rec[field]
	if not b then b = fresh_bucket(); rec[field] = b end
	b[cat or "trash"] = (b[cat or "trash"] or 0) + (v or 0)
end

-- Sum rec[field] over the slot(s) selected by the current filter. Missing -> 0.
-- Accepts a raw bucket table too (pass field=nil).
function F.read(rec, field)
	local b = field and (rec and rec[field]) or rec
	if not b then return 0 end
	-- Support a plain scalar left over from un-migrated code (defensive).
	if type(b) == "number" then return b end
	local f = mod._unit_filter or "all"
	if f == "all" then
		return (b.es or 0) + (b.mon or 0) + (b.trash or 0)
	end
	return b[f] or 0
end

-- ---------------------------------------------------------------------------
-- Category-keyed record SETS (the low-churn path used by the value modules).
-- Each module keeps three independent copies of its existing `totals` structure,
-- one per category, and routes crediting into the copy for the hit's category (a
-- pointer swap -- no per-field changes). At draw time it merges the copies the
-- current filter selects into one read-only set via F.merge_sets.
-- ---------------------------------------------------------------------------

-- Deep element-wise sum of a list of like-shaped tables: numbers add, nested
-- tables recurse, other values take the first seen. Returns a fresh table.
local function deep_sum(list)
	local out = {}
	for _, t in ipairs(list) do
		if type(t) == "table" then
			for k, v in pairs(t) do
				if type(v) == "number" then
					out[k] = (out[k] or 0) + v
				elseif type(v) == "table" then
					local sub = out[k]
					if type(sub) ~= "table" then sub = {}; out[k] = sub end
					-- Merge this nested table into the accumulator.
					out[k] = deep_sum({ sub, v })
				elseif out[k] == nil then
					out[k] = v
				end
			end
		end
	end
	return out
end
F.deep_sum = deep_sum

-- Merge the {es=, mon=, trash=} record-sets the current filter selects into one
-- read-only set. `by_cat` is a table with es/mon/trash entries (each a record set,
-- e.g. talent -> {total_dmg=, ...}). "all" sums all three; else just that one.
function F.merge_sets(by_cat)
	local f = mod._unit_filter or "all"
	if f ~= "all" then
		return by_cat[f] or {}
	end
	return deep_sum({ by_cat.es, by_cat.mon, by_cat.trash })
end

-- Read a single category's slot regardless of the active filter (for panels that
-- want to show a fixed category, e.g. debugging). Missing -> 0.
function F.read_cat(rec, field, cat)
	local b = field and (rec and rec[field]) or rec
	if not b then return 0 end
	if type(b) == "number" then return b end
	return b[cat] or 0
end

return F
