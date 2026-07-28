-- unit_filter.lua
-- ============================================================================
-- Shared per-unit-category bucketing + the global display filter, used by every
-- talent-comparison panel so a single set of filter buttons (on the control panel)
-- can switch ALL panels between showing only one enemy category or the sum.
--
-- FOUR tracked categories (each unit belongs to exactly one):
--   "elite"   -- Elites   (breed.elite)
--   "special" -- Specials (breed.special)
--   "mon"     -- Monsters + Bosses + Lords (breed.boss; lords are boss=true)
--   "trash"   -- everything else (clanrats, marauders, fanatics, ...)
--
-- Every running total in the value modules is stored as a per-category bucket
-- ({elite=,special=,mon=,trash=}) instead of a scalar; F.add routes a credit into
-- the slot for the hit's category, and F.read sums the slot(s) the current filter
-- selects. Storing one slot per category is unavoidable: the filter switches at
-- runtime, so all categories must be retained simultaneously.
--
-- The filter is now MULTI-SELECT: each category is an independent on/off toggle
-- (mod._filter_sel[cat]), so any combination can be shown at once and reads sum the
-- enabled categories. There is no "All" pseudo-value -- "all" is simply every
-- category toggled on (the default).
--
-- Filter state lives on `mod` (mod._filter_sel / mod._hide_all), each backed by a
-- persisted setting so it survives a relaunch. The control panel writes it; the
-- value modules only read it (indirectly, via F.read / F.enabled).
-- ============================================================================

local F = {}

local mod  -- set in init()

-- The tracked storage categories, in button/display order.
F.CATS    = { "elite", "special", "mon", "trash" }
F.LABELS  = { elite = "Elites", special = "Specials", mon = "Monsters", trash = "Trash" }

local function is_cat(c)
	return c == "elite" or c == "special" or c == "mon" or c == "trash"
end

function F.init(owner_mod)
	mod = owner_mod
	-- Load persisted per-category selection (comma-joined list of enabled cats) into
	-- the fast-access set. Missing/blank -> every category on (the default).
	local sel = {}
	local raw = mod:get("filter_sel")
	if type(raw) == "string" and raw ~= "" then
		for c in string.gmatch(raw, "[^,]+") do
			if is_cat(c) then sel[c] = true end
		end
	else
		for _, c in ipairs(F.CATS) do sel[c] = true end
	end
	-- Never leave the selection completely empty (nothing would ever display).
	local any = false
	for _, c in ipairs(F.CATS) do if sel[c] then any = true break end end
	if not any then for _, c in ipairs(F.CATS) do sel[c] = true end end
	mod._filter_sel = sel
	local h = mod:get("hide_all")
	mod._hide_all = h == true
end

-- Persist the current selection set as a comma-joined list.
local function persist_sel()
	local parts = {}
	for _, c in ipairs(F.CATS) do
		if mod._filter_sel[c] then parts[#parts + 1] = c end
	end
	mod:set("filter_sel", table.concat(parts, ","))
end

-- Is category `cat` currently displayed?
function F.enabled(cat)
	local sel = mod._filter_sel
	if not sel then return true end
	return sel[cat] == true
end

-- Toggle one category on/off. Refuses to turn off the last enabled category (so the
-- panels never go completely blank).
function F.toggle(cat)
	if not is_cat(cat) then return end
	local sel = mod._filter_sel
	if sel[cat] then
		-- Count remaining if we turned this off.
		local others = 0
		for _, c in ipairs(F.CATS) do
			if c ~= cat and sel[c] then others = others + 1 end
		end
		if others == 0 then return end  -- keep at least one on
		sel[cat] = nil
	else
		sel[cat] = true
	end
	persist_sel()
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
-- Return "elite" | "special" | "mon" | "trash" for a unit (nil / unknown -> "trash").
function F.cat_of_breed(breed)
	if not breed then return "trash" end
	if breed.boss then return "mon" end
	if breed.elite then return "elite" end
	if breed.special then return "special" end
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
	return { elite = 0, special = 0, mon = 0, trash = 0 }
end
F.fresh_bucket = fresh_bucket

-- Build a per-category set { elite=factory(), special=..., mon=..., trash=... }.
function F.new_cat_set(factory)
	local out = {}
	for _, c in ipairs(F.CATS) do out[c] = factory() end
	return out
end

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
	local sum = 0
	for _, c in ipairs(F.CATS) do
		if F.enabled(c) then sum = sum + (b[c] or 0) end
	end
	return sum
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

-- Merge the per-category record-sets the current filter selects into one read-only
-- set. `by_cat` is a table with elite/special/mon/trash entries (each a record set,
-- e.g. talent -> {total_dmg=, ...}). Sums exactly the enabled categories.
function F.merge_sets(by_cat)
	local list = {}
	for _, c in ipairs(F.CATS) do
		if F.enabled(c) and by_cat[c] then list[#list + 1] = by_cat[c] end
	end
	return deep_sum(list)
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
