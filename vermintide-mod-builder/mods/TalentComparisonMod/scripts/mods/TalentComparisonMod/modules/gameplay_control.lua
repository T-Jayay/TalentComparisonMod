-- gameplay_control.lua
-- ============================================================================
-- Central switchboard for everything in the mod that AFFECTS GAMEPLAY (as
-- opposed to just measuring it). One master consent setting, `allow_gameplay`
-- (default OFF), gates every gameplay-affecting feature; each feature also has
-- its own sub-toggle:
--
--   force_ep        -- force extra cleave for power-level talents (EP / Reikland
--                      Reaper / Limb Splitter) so real cleave can be measured.
--   force_flense    -- grant the WHC Flense bleed buff so its real DoT ticks can
--                      be measured (L10 WHC panel).
--   force_st_spread -- replicate Strike Together's ally Paced-Strikes spread so
--                      ally gains can be measured (L20 Merc panel, vanilla mode).
--   unequip_l15     -- REMOVE the equipped level-15 talent's buffs entirely, so
--                      every L15 column is a clean hypothetical over a true
--                      no-talent baseline (this module implements it, below).
--
-- With the master OFF the mod is guaranteed measure-only: no buffs granted, no
-- sweeps widened, no talents removed -- every panel falls back to estimates or
-- opportunistic measurement. The control panel shows a status line listing the
-- modifications currently LIVE (runtime flags in mod._gameplay_live, written by
-- the owning modules; this module maintains the unequip_l15 flag itself).
--
-- Level-15 row unequip: TalentExtension applies talent buffs from
-- get_talent_ids() (talent_extension.lua apply_buffs_from_talents) and
-- talents_changed() cleanly removes + reapplies them (_clear_buffs_from_talents
-- tracks every id). So we hook get_talent_ids on the LOCAL player's extension to
-- filter out any talent whose buff list is one of the five L15 "unbalance"
-- templates, and call talents_changed() whenever the desired state flips. The
-- filtered list is also what has_talent()/rpc_sync_talents see, so detection in
-- our own modules (has_buff_type) and on other clients stays consistent: with
-- the row unequipped, ALL FIVE columns become true hypotheticals over the same
-- no-talent base (the L15 module's equipped-talent stripping naturally no-ops).
-- Gameplay-affecting, modded realm only. Restored on toggle-off / mod disable.
-- ============================================================================

local M = {}

local mod  -- set in init()

-- The five level-15 "unbalance" buff templates (buff_templates.lua); a talent
-- whose `buffs` list contains one of these IS a level-15 row talent. Values are
-- the display names, used in the control panel's status line.
local UNBALANCE = {
	smiter_unbalance = "Smiter",
	linesman_unbalance = "Mainstay",
	finesse_unbalance = "Assassin",
	tank_unbalance = "Bulwark",
	power_level_unbalance = "Enhanced Power",
}

-- ---------------------------------------------------------------------------
-- The one gate every gameplay-affecting call site asks. Master must be on AND
-- the feature's own sub-toggle (nil -> its data.lua default, all true except
-- unequip_l15 -- but read defensively: nil counts as ON for the force_* subs
-- and OFF for unequip_l15, matching the widget defaults).
-- ---------------------------------------------------------------------------
function M.on(feature)
	if not mod:get("allow_gameplay") then return false end
	local v = mod:get(feature)
	if v == nil then
		return feature ~= "unequip_l15"
	end
	return v == true
end

-- ---------------------------------------------------------------------------
-- Level-15 row unequip.
-- ---------------------------------------------------------------------------
local unequip_applied = false   -- state last enforced via talents_changed()
local restore_override = false  -- forces the hook transparent during restore()

-- Returns the display name of the L15 talent (nil if not an L15 row talent).
local function l15_talent_name(hero_name, talent_id)
	local ok, talent_data = pcall(TalentUtils.get_talent_by_id, hero_name, talent_id)
	if not ok or not talent_data then return nil end
	local buffs = talent_data.buffs
	if not buffs then return nil end
	for i = 1, #buffs do
		local name = UNBALANCE[buffs[i]]
		if name then return name end
	end
	return nil
end

-- Display name of the talent the hook most recently stripped (for the status
-- line: "<talent> damage bonus removed"). nil = nothing was equipped to strip.
local removed_name = nil

local function unequip_wanted()
	return not restore_override and mod:is_enabled() and M.on("unequip_l15")
end

local function local_talent_extension()
	local pm = Managers.player
	local ok, player = pcall(function () return pm and pm:local_player() end)
	if not ok then return nil end
	local unit = player and player.player_unit
	if not unit or not Unit.alive(unit) then return nil end
	return ScriptUnit.has_extension(unit, "talent_system")
end

-- Re-apply talent buffs from the (possibly filtered) talent list. The heavy
-- lifting -- clearing old buff ids, re-adding, resyncing to the network -- is
-- the game's own talents_changed().
local function reapply_talents()
	local te = local_talent_extension()
	if not te then return false end
	local ok = pcall(function () te:talents_changed() end)
	return ok
end

-- Called from the mod's on_disabled: make the hook transparent and hand the
-- full talent row back before we go quiet.
function M.restore()
	if not unequip_applied then return end
	restore_override = true
	reapply_talents()
	restore_override = false
	unequip_applied = false
	removed_name = nil
	if mod._gameplay_live then mod._gameplay_live.unequip_l15 = false end
end

function M.update(dt)
	-- Enforce the desired unequip state. extensions_ready runs get_talent_ids
	-- through our hook, so a fresh spawn picks the filter up automatically; only
	-- a mid-life toggle needs an explicit talents_changed(). The player unit must
	-- exist for that, so keep trying until it does.
	local wanted = unequip_wanted()
	if wanted ~= unequip_applied then
		if reapply_talents() then
			unequip_applied = wanted
			if not wanted then removed_name = nil end
		end
	end
	mod._gameplay_live.unequip_l15 = unequip_applied

	-- Force-cleave is live whenever its gate is on (the power-level panels are
	-- always active, so the widened sweep happens on your real melee swings).
	mod._gameplay_live.force_ep = M.on("force_ep") or false
end

-- ---------------------------------------------------------------------------
-- Status line for the control panel: labels of the modifications that are LIVE
-- right now (not merely enabled in settings), spelling out the actual alteration.
-- The force_* flags are set each update by their owning modules; unequip_l15 by
-- this one.
-- ---------------------------------------------------------------------------
local function tb_mod_active()
	local tb = get_mod("TourneyBalance")
	return tb ~= nil and tb:is_enabled()
end

function M.live_list()
	local live = mod._gameplay_live
	local out = {}
	if live.force_ep then
		-- The forced cleave budget mirrors the power-level talent's boost: EP +7.5%
		-- vanilla / +10% under Tourney Balance.
		out[#out + 1] = string.format("Extra cleave (EP +%s%%)", tb_mod_active() and "10" or "7.5")
	end
	if live.force_flense then
		out[#out + 1] = "Flense bleed granted"
	end
	if live.force_st_spread then
		out[#out + 1] = "Paced Strikes spread to allies"
	end
	if live.unequip_l15 then
		if removed_name then
			out[#out + 1] = removed_name .. " damage bonus removed"
		else
			out[#out + 1] = "L15 row unequipped"
		end
	end
	return out
end

-- ---------------------------------------------------------------------------
-- Group-module interface (no panel of its own).
-- ---------------------------------------------------------------------------
function M.reset() end
function M.log_state() end
function M.wants_display() return false end
function M.draw(gui) end

function M.init(owner_mod)
	mod = owner_mod
	mod._gameplay_live = {}       -- runtime "this modification is live" flags
	mod._gameplay_on = M.on       -- the gate every module calls
	mod._gameplay = M

	-- Filter L15 row talents out of the local player's talent list while the
	-- unequip feature is wanted. Class-wide hook, so gate hard on the local,
	-- non-bot player. Copy before filtering -- the returned table belongs to the
	-- backend talents interface.
	mod:hook(TalentExtension, "get_talent_ids", function (func, self)
		local ids = func(self)
		if not unequip_wanted() then return ids end
		local player = self.player
		if not player or not player.local_player or player.bot_player then return ids end
		local hero_name = self._hero_name
		if not hero_name then return ids end
		local filtered = {}
		local removed = nil
		for i = 1, #ids do
			local name = l15_talent_name(hero_name, ids[i])
			if name then
				removed = name
			else
				filtered[#filtered + 1] = ids[i]
			end
		end
		removed_name = removed
		return filtered
	end)
end

return M
