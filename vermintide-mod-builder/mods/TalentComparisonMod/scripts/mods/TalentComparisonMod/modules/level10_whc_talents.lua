-- level10_whc_talents.lua
-- ============================================================================
-- Talent group: Level-10 Witch Hunter Captain (WHC) damage talents.
--
-- CAREER-SPECIFIC: unlike the shared THP / level-15 panels, these talents exist
-- only on WHC (career_name "wh_captain"). The panel is hidden -- and none of the
-- simulation runs -- unless the LOCAL player is currently playing WHC. This is the
-- template for any future one-career talent group: gate everything on the career.
--
-- Talents (a WHC picks 2 of these 3 at level 10):
--   Riposte   (victor_witchhunter_guaranteed_crit_on_timed_block) -- a perfectly
--             timed block makes your NEXT melee/ranged attack (<=2s) a guaranteed
--             critical hit (single hit: the buff is remove_on_proc on on_hit).
--   Deathknell(victor_witchhunter_headshot_damage_increase) -- +headshot BONUS
--             damage (stat_buff headshot_multiplier; source value 0.5 -- see
--             DEATHKNELL_HEADSHOT_BONUS). Only finesse hits (head/neck) gain.
--   Flense    (victor_witchhunter_bleed_on_critical_hit) -- despite the internal
--             name, every LIGHT/HEAVY melee hit makes the target bleed: it applies
--             the weapon_bleed_dot_whc DoT (damage_profile "bleed", up to 3 stacks)
--             in DamageUtils.server_apply_hit. A brand-new damage-over-time source.
--
-- Reported per talent, exactly like the level-15 panel:
--   Total    : extra damage across all targets with OVERKILL removed (only the
--              part of each hit's extra that lands while the unit still had HP).
--   First    : the same, first unit only (target_index 1).
--   Uncapped : the raw hypothetical extra with no overkill removal.
--
-- HOW EACH VALUE IS DERIVED
--   Flense  -- because a DoT is a NEW source that does not exist without the
--     talent, we FORCE it: while this panel is active on WHC and the player has NOT
--     equipped Flense, a victor_witchhunter_bleed_on_critical_hit buff is granted to
--     the local player so the game itself applies the real weapon_bleed_dot_whc DoT
--     (gameplay-affecting -- modded realm only, most accurate as host). Every
--     resulting "bleed"-profile DoT tick on the local player's targets is credited
--     to Flense at full damage (baseline 0), overkill-capped by the unit's HP. The
--     DoT stops when the unit dies, so Total and Uncapped both sum only real ticks
--     (Uncapped just omits the per-tick overkill clamp). On WHC no other source
--     produces the "bleed" profile, so attribution is unambiguous.
--   Deathknell -- re-run the real calculate_damage with +DEATHKNELL_HEADSHOT_BONUS
--     injected into headshot_multiplier (BuffExtension.apply_buffs_to_value hook +
--     a recompute flag, the same trick the level-15 EP column uses). Body hits get
--     no headshot boost, so their delta is naturally 0.
--   Riposte -- OPPORTUNISTIC: a hook on GenericStatusExtension.blocked_attack
--     detects a real timed block (t < self.timed_block) and arms a 2s window. The
--     next local melee/ranged hit in that window, if it was NOT already a crit, is
--     re-run with is_critical_strike = true and the crit delta credited; then the
--     window is consumed (one hit, matching remove_on_proc). No gameplay change.
--
-- Deathknell / Riposte are only credited when NOT equipped (this is a "value of the
-- talent you DIDN'T take" panel); the one of the two you did take reads 0. Flense is
-- always measured (forced when absent, real when present).
--
-- Damage crediting piggybacks on the level-15 module's single DamageUtils.calculate_
-- damage hook (VMF ignores a duplicate hook on the same function from the same mod),
-- which calls mod._l10_on_hit for every local-player hit. This module owns its own,
-- non-conflicting hooks: BuffExtension.apply_buffs_to_value and
-- GenericStatusExtension.blocked_attack.
--
-- NOTE (host vs client): calculate_damage, the forced DoT's server_apply_hit and the
-- timed-block detection all resolve server-side. Most accurate as host.
-- ============================================================================

local M = {}

local mod   -- set in init()
local ui    -- shared ui_panel, set in init()
local l10_kt   -- shared kill-tracker instance (mod._kill_tracker.new(), created in init)

local DBG = false
local function dlog(fmt, ...)
	if DBG and mod then
		local ok, s = pcall(string.format, "[TCM10] " .. fmt, ...)
		if not ok then s = "[TCM10] (log format error) " .. fmt end
		mod:echo((s:gsub("%%", "%%%%")))
	end
end

-- WHC level-10 talent buff names (for has_talent detection) and the forced Flense buff.
local WHC_CAREER_NAME  = "wh_captain"
local TALENT_RIPOSTE   = "victor_witchhunter_guaranteed_crit_on_timed_block"
local TALENT_DEATHKNELL = "victor_witchhunter_headshot_damage_increase"
local TALENT_FLENSE    = "victor_witchhunter_bleed_on_critical_hit"

-- Deathknell's headshot_multiplier stat-buff value. buff_tweak_data in
-- talent_settings_victor.lua lists victor_witchhunter_headshot_damage_increase =
-- { multiplier = 0.5 } (the decompiled source, which CLAUDE.md treats as
-- authoritative). The in-game tooltip loosely says "25%"; flip this to 0.25 if you
-- want to match the tooltip instead of the code.
local DEATHKNELL_HEADSHOT_BONUS = 0.5
local RIPOSTE_WINDOW = 2.0
-- Melee calculate_damage fires 2+ times per real hit (prediction + application);
-- dedupe by timestamp exactly like the level-15 module.
local SWEEP_DEDUPE_WINDOW = 0.2

local TALENTS10 = { "riposte", "deathknell", "flense" }
local TALENT10_NAMES = {
	riposte    = "Riposte",
	deathknell = "Deathknell",
	flense     = "Flense",
}

-- ---------------------------------------------------------------------------
-- Running totals
-- ---------------------------------------------------------------------------
local totals       -- ACTIVE record set: points at totals_cat[cat] per hit / merged in draw.
local totals_cat   -- { es=, mon=, trash= }
local F            -- unit_filter (mod._filter), set in init

local function new_record()
	return { total_dmg = 0, first_dmg = 0, total_uncapped = 0 }
end

local function fresh_totals()
	local t = {}
	for _, k in ipairs(TALENTS10) do
		t[k] = new_record()
	end
	return t
end

local function fresh_totals_cat()
	return { es = fresh_totals(), mon = fresh_totals(), trash = fresh_totals() }
end

totals_cat = fresh_totals_cat()
totals = totals_cat.trash

-- Riposte window (game-time expiry of the guaranteed crit) and per-target melee dedupe.
local riposte_window = nil
local sweep_seen = {}
-- Deathknell recompute state: while set, the apply_buffs_to_value hook adjusts
-- headshot_multiplier for exactly this buff extension by dk_recompute_delta (which
-- is +BONUS when Deathknell is NOT equipped -- simulate it -- and -BONUS when it IS
-- equipped -- strip it to recover the without-talent baseline).
local dk_recompute_ext = nil
local dk_recompute_delta = 0
-- Force-Flense bookkeeping: the last player unit we granted (or verified) the bleed
-- perk on, so we do it once per spawn rather than every frame.
local flense_forced_unit = nil

function M.reset()
	totals_cat = fresh_totals_cat()
	totals = totals_cat.trash
	if l10_kt then l10_kt:reset() end
	riposte_window = nil
	table.clear(sweep_seen)
	dk_recompute_ext = nil
	dk_recompute_delta = 0
	flense_forced_unit = nil
end

-- Kill-column record for `talent` from the shared tracker, or an all-zero default
-- before its first credit (Deathknell / Riposte only; Flense has no kill column).
local ZERO_KILLS = { n = 0, hpk_sum = 0, hpk_n = 0, real_total = 0 }
local function kget(talent)
	return (l10_kt and l10_kt:get(talent)) or ZERO_KILLS
end

-- ---------------------------------------------------------------------------
-- Small helpers (mirror the level-15 module).
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

-- Overkill accounting, identical to the level-15 model.
local function useful_extra(baseline, extra, H)
	if not H then return extra end
	local lo = math.min(baseline, H)
	local hi = math.min(baseline + extra, H)
	local u = hi - lo
	if u < 0 then u = 0 end
	if u > extra then u = extra end
	return u
end

-- Is the local player currently playing WHC?
local function career_is_whc()
	local unit = local_player_unit()
	if not unit then return false end
	local ce = ScriptUnit.has_extension(unit, "career_system")
	if not ce then return false end
	local ok, name = pcall(function () return ce:career_name() end)
	return ok and name == WHC_CAREER_NAME
end

-- Panel/simulation active only while playing WHC.
local function active()
	return career_is_whc()
end

local function talent_equipped(unit, talent_name)
	local te = ScriptUnit.has_extension(unit, "talent_system")
	if not te then return false end
	local ok, res = pcall(function () return te:has_talent(talent_name) end)
	return ok and res or false
end

-- ---------------------------------------------------------------------------
-- Force Flense: grant the bleed perk to the local player so the real DoT applies.
-- Called every update; only does work when the player unit changes (new spawn) and
-- only when Flense is not already equipped. Gameplay-affecting (modded realm only).
-- ---------------------------------------------------------------------------
local function maintain_forced_flense()
	local unit = local_player_unit()
	if not unit or not Unit.alive(unit) then
		flense_forced_unit = nil
		return
	end
	if unit == flense_forced_unit then return end
	flense_forced_unit = unit

	-- Already have Flense: the real DoT exists, nothing to force.
	if talent_equipped(unit, TALENT_FLENSE) then
		dlog("Flense already equipped -- not forcing (real DoT will be measured)")
		return
	end
	local buff_system = Managers.state.entity and Managers.state.entity:system("buff_system")
	if not buff_system then
		flense_forced_unit = nil   -- retry next frame
		return
	end
	local ok = pcall(function ()
		buff_system:add_buff(unit, TALENT_FLENSE, unit)
	end)
	dlog("Forced Flense buff added=%s", tostring(ok))
end

-- Undo a forced grant when the gameplay gate turns off mid-life: find the buff we
-- added on the local player (by buff_type; never present unless granted or equipped
-- -- and we never grant while equipped) and remove it. If the type scan misses
-- (template preprocessing quirk) the buff simply lasts until the next respawn.
local function remove_forced_flense()
	local unit = flense_forced_unit
	flense_forced_unit = nil
	if not unit or not Unit.alive(unit) then return end
	if talent_equipped(unit, TALENT_FLENSE) then return end
	local buff_ext = ScriptUnit.has_extension(unit, "buff_system")
	if not buff_ext then return end
	pcall(function ()
		local buffs = buff_ext._buffs
		for i = 1, buff_ext._num_buffs do
			local buff = buffs[i]
			if buff and (buff.buff_type == TALENT_FLENSE
				or (buff.template and buff.template.name == TALENT_FLENSE)) then
				buff_ext:remove_buff(buff.id)
				dlog("Forced Flense buff removed (gate off)")
				return
			end
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Per-hit crediting (called from the level-15 calculate_damage hook via
-- mod._l10_on_hit). ctx carries the unhooked calculate_damage `func` plus all its
-- arguments and the real `final` damage, so Deathknell/Riposte can recompute.
-- ---------------------------------------------------------------------------
local function credit(rec, baseline, extra, health, first)
	if extra <= 0 then return end
	local capped = useful_extra(baseline, extra, health)
	rec.total_uncapped = rec.total_uncapped + extra
	rec.total_dmg = rec.total_dmg + capped
	if first then
		rec.first_dmg = rec.first_dmg + capped
	end
end

-- Re-run calculate_damage with a modified critical-strike flag (Riposte).
local function recompute(ctx, crit_override)
	local ok, v = pcall(ctx.func, ctx.damage_output, ctx.target_unit, ctx.attacker_unit,
		ctx.hit_zone_name, ctx.original_power_level, ctx.boost_curve, ctx.boost_damage_multiplier,
		crit_override, ctx.damage_profile, ctx.target_index, ctx.backstab_multiplier, ctx.damage_source)
	if ok and type(v) == "number" then return v end
	return ctx.final
end

-- Re-run calculate_damage with Deathknell's headshot bonus adjusted by `delta` (via
-- the apply_buffs_to_value hook + dk_recompute_ext flag). delta = +BONUS simulates
-- the talent (when not equipped); delta = -BONUS strips it (when equipped) to get the
-- without-talent baseline.
local function recompute_deathknell(ctx, buff_ext, delta)
	dk_recompute_ext = buff_ext
	dk_recompute_delta = delta
	local ok, v = pcall(ctx.func, ctx.damage_output, ctx.target_unit, ctx.attacker_unit,
		ctx.hit_zone_name, ctx.original_power_level, ctx.boost_curve, ctx.boost_damage_multiplier,
		ctx.is_critical_strike, ctx.damage_profile, ctx.target_index, ctx.backstab_multiplier, ctx.damage_source)
	dk_recompute_ext = nil
	dk_recompute_delta = 0
	if ok and type(v) == "number" then return v end
	return ctx.final
end

local function on_hit(ctx)
	if not active() then return end
	local attacker_unit = ctx.attacker_unit
	if attacker_unit ~= local_player_unit() then return end
	local final = ctx.final
	if not final or final <= 0 then return end
	local dp = ctx.damage_profile
	if not dp then return end

	local target_unit = ctx.target_unit
	local health = unit_current_health(target_unit)
	-- Corpse contacts (a sweep clipping a dead unit) deal no real damage -- skip so
	-- they don't inflate any column (matches the level-15 dead-skip guard).
	if health and health <= 0 then
		if l10_kt then l10_kt:forget(target_unit) end
		return
	end
	-- Route this hit's crediting into the target's unit-category record set.
	totals = totals_cat[ctx.cat or F.cat_of(target_unit)]
	local first = (ctx.target_index or 1) <= 1

	-- --- Flense: bleed DoT ticks. On WHC the "bleed" profile only comes from the
	-- (forced or equipped) weapon_bleed_dot_whc, so every such tick is Flense. ---
	if dp.is_dot then
		local bleed_profile = rawget(_G, "DamageProfileTemplates") and DamageProfileTemplates.bleed
		if bleed_profile and dp == bleed_profile then
			credit(totals.flense, 0, final, health, first)
			dlog("FLENSE tick fin=%.2f first=%s", final, tostring(first))
		end
		return
	end

	-- Only melee/ranged direct attacks feed Deathknell/Riposte.
	local is_melee = dp.charge_value == "light_attack" or dp.charge_value == "heavy_attack"

	-- Melee dedupe: defer to the level-15 module's single per-genuine-hit decision so
	-- duplicate calculate_damage calls collapse to one while a dual-wield attack's two
	-- sweeps (left+right weapon) each still count. See level15 melee_should_credit.
	if is_melee then
		if not (mod._l15_melee_credit and mod._l15_melee_credit(ctx)) then return end
	end

	local buff_ext = ScriptUnit.has_extension(attacker_unit, "buff_system")

	-- --- Deathknell: headshot bonus damage. If NOT equipped, simulate the talent
	-- (+BONUS) and credit dk - final. If equipped, the real `final` already includes
	-- it, so strip the bonus (-BONUS) to get the without-talent baseline and credit
	-- the boost already realized (final - baseline) -- mirroring the level-15 EP
	-- "already equipped" case. Body hits get no headshot boost, so extra is 0. ---
	if buff_ext then
		if not talent_equipped(attacker_unit, TALENT_DEATHKNELL) then
			local dk = recompute_deathknell(ctx, buff_ext, DEATHKNELL_HEADSHOT_BONUS)
			local extra = dk - final
			if extra > 0 then
				credit(totals.deathknell, final, extra, health, first)
				-- Kill-aware: baseline = real (no Deathknell) hit, world = with the bonus.
				l10_kt:add("deathknell", final, dk)
				dlog("DEATHKNELL(sim) zone=%s fin=%.2f dk=%.2f extra=%.2f", tostring(ctx.hit_zone_name), final, dk, extra)
			end
		else
			local base = recompute_deathknell(ctx, buff_ext, -DEATHKNELL_HEADSHOT_BONUS)
			local extra = final - base
			if extra > 0 then
				credit(totals.deathknell, base, extra, health, first)
				-- Equipped: real `final` already has the bonus, baseline = stripped hit.
				l10_kt:add("deathknell", base, final)
				dlog("DEATHKNELL(equipped) zone=%s fin=%.2f base=%.2f extra=%.2f", tostring(ctx.hit_zone_name), final, base, extra)
			end
		end
	end

	-- --- Riposte: guaranteed crit on the next attack after a timed block. ---
	if riposte_window and game_time() <= riposte_window
		and not talent_equipped(attacker_unit, TALENT_RIPOSTE) then
		if not ctx.is_critical_strike then
			local crit = recompute(ctx, true)
			local extra = crit - final
			if extra > 0 then
				credit(totals.riposte, final, extra, health, first)
				-- Kill-aware: baseline = real (non-crit) hit, world = the guaranteed crit.
				l10_kt:add("riposte", final, crit)
			end
			dlog("RIPOSTE zone=%s fin=%.2f crit=%.2f extra=%.2f", tostring(ctx.hit_zone_name), final, crit, crit - final)
		else
			dlog("RIPOSTE window hit already crit -- consumed, no extra")
		end
		riposte_window = nil   -- consumed by this attack (remove_on_proc)
	end
end

-- ---------------------------------------------------------------------------
-- Hooks
-- ---------------------------------------------------------------------------
function M.init(owner_mod, ui_panel)
	mod = owner_mod
	ui = ui_panel
	F = mod._filter

	-- Shared kill / Real-Total tracker (owned by level15, which inits first). This panel
	-- gets its own instance so its Reset zeroes only its rows; Deathknell/Riposte feed it.
	l10_kt = mod._kill_tracker.new()

	-- Shared entry point called by the level-15 module's single calculate_damage
	-- hook, once per local-player hit (see level15_talents.lua).
	mod._l10_on_hit = function (ctx)
		pcall(on_hit, ctx)
	end

	-- Deathknell recompute injection: while recomputing a hit, add the talent's
	-- bonus to headshot_multiplier for exactly the attacker's buff extension. Guarded
	-- to the recompute flag so normal gameplay is untouched.
	mod:hook(BuffExtension, "apply_buffs_to_value", function (func, self, value, stat_buff)
		local v = func(self, value, stat_buff)
		if dk_recompute_ext and self == dk_recompute_ext and stat_buff == "headshot_multiplier" then
			v = v + dk_recompute_delta
		end
		return v
	end)

	-- Riposte: detect a real perfectly-timed block and arm the 2s guaranteed-crit
	-- window. blocked_attack fires on every block; a timed block is t < self.timed_block.
	mod:hook_safe(GenericStatusExtension, "blocked_attack", function (self)
		if not active() then return end
		if self.unit ~= local_player_unit() then return end
		local tb = self.timed_block
		if tb and game_time() < tb then
			riposte_window = game_time() + RIPOSTE_WINDOW
			dlog("RIPOSTE timed block -> window armed until %.2f", riposte_window)
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Update: keep the forced Flense DoT applied (WHC + panel on + the gameplay
-- gate only); take it back the moment the gate closes.
-- ---------------------------------------------------------------------------
function M.update(dt)
	if active() and mod._gameplay_on("force_flense") then
		pcall(maintain_forced_flense)
	elseif flense_forced_unit then
		pcall(remove_forced_flense)
	end
	-- Live status for the control panel: only true while we are actually holding a
	-- granted (not naturally equipped) Flense buff on the player.
	if mod._gameplay_live then
		mod._gameplay_live.force_flense = flense_forced_unit ~= nil
			and Unit.alive(flense_forced_unit)
			and not talent_equipped(flense_forced_unit, TALENT_FLENSE)
	end
end

-- ---------------------------------------------------------------------------
-- Display
-- ---------------------------------------------------------------------------
-- Column x-offsets shared with the Level 15 panel so the two line up visually.
local T10_TOTAL_COL = 160
local T10_UNCAP_COL = 350
local T10_REAL_COL  = 490   -- Real Total: extra damage that actually pulled kills sooner
local PANEL_W_T10   = 640

-- Title lists the specific talents this panel compares (descriptor-only style).
local T10_TITLE = table.concat({
	TALENT10_NAMES.riposte, TALENT10_NAMES.deathknell, TALENT10_NAMES.flense,
}, " / ") .. ":"

function M.wants_display()
	return active()
end

function M.log_state()
	if not DBG then return end
	local totals = F.merge_sets(totals_cat)
	dlog("L10 SNAP total/first (uncap): ri=%.1f/%.1f (%.1f) dk=%.1f/%.1f (%.1f) fl=%.1f/%.1f (%.1f)",
		totals.riposte.total_dmg, totals.riposte.first_dmg, totals.riposte.total_uncapped,
		totals.deathknell.total_dmg, totals.deathknell.first_dmg, totals.deathknell.total_uncapped,
		totals.flense.total_dmg, totals.flense.first_dmg, totals.flense.total_uncapped)
end

function M.reset_self()
	if M.log_state then pcall(M.log_state) end
	M.reset()
end

function M.draw(gui)
	local FONT_SIZE = ui.FONT_SIZE
	local small = FONT_SIZE - 6

	local totals = F.merge_sets(totals_cat)

	-- rows: title (0) + header (1) + 3 talents (2..4) + note (5). content_rows = 5
	-- so Reset sits directly beneath the note.
	local x, top, row_y, collapsed, title_visible = ui.frame(gui, PANEL_W_T10, 5, "l10_pos_x", "l10_pos_y", 0.03, 0.6, "l10", M.reset_self)
	if not x then return end

	if title_visible then
		ui.text_bold(gui, T10_TITLE, x, row_y(0), FONT_SIZE, ui.yellow)
	end
	if collapsed then return end

	-- No "First Unit" column here (unlike the Stagger panel): Total / Uncapped / Real.
	ui.text(gui, "Extra Damage:", x, row_y(1), small, ui.grey)
	ui.text(gui, "Total", x + T10_TOTAL_COL, row_y(1), small, ui.grey)
	ui.text(gui, "Uncapped", x + T10_UNCAP_COL, row_y(1), small, ui.grey)
	ui.text(gui, "Real Total", x + T10_REAL_COL, row_y(1), small, ui.grey)

	-- Riposte is only measured when NOT equipped ("value of the talent you didn't
	-- take"); when it IS equipped its counters carry no meaning, so show dashes.
	local player_unit = local_player_unit()
	local riposte_equipped = player_unit and talent_equipped(player_unit, TALENT_RIPOSTE)
	-- Flense only accumulates while its DoT actually exists: equipped, or granted by
	-- the (gameplay-gated) forcing. Otherwise mark the row (off).
	local flense_live = player_unit and (talent_equipped(player_unit, TALENT_FLENSE)
		or mod._gameplay_on("force_flense"))

	for i, talent in ipairs(TALENTS10) do
		local rec = totals[talent]
		local ry = row_y(i + 1)
		local name = TALENT10_NAMES[talent]
		if talent == "flense" and not flense_live then name = name .. " (off)" end
		ui.text(gui, name, x, ry, FONT_SIZE, ui.white)
		if talent == "riposte" and riposte_equipped then
			ui.text(gui, "-", x + T10_TOTAL_COL, ry, FONT_SIZE, ui.white)
			ui.text(gui, "-", x + T10_UNCAP_COL, ry, FONT_SIZE, ui.white)
			ui.text(gui, "-", x + T10_REAL_COL, ry, FONT_SIZE, ui.white)
		else
			ui.text(gui, string.format("%.0f", rec.total_dmg), x + T10_TOTAL_COL, ry, FONT_SIZE, ui.white)
			ui.text(gui, string.format("%.0f", rec.total_uncapped), x + T10_UNCAP_COL, ry, FONT_SIZE, ui.white)
			-- Real Total is kill-aware; Flense (a DoT with no per-hit kill sequence of
			-- its own) has none, so it shows a dash.
			if talent == "flense" then
				ui.text(gui, "-", x + T10_REAL_COL, ry, FONT_SIZE, ui.white)
			else
				ui.text(gui, string.format("%.0f", kget(talent).real_total), x + T10_REAL_COL, ry, FONT_SIZE, ui.white)
			end
		end
	end

	local note
	if flense_live and not talent_equipped(player_unit, TALENT_FLENSE) then
		note = "Flense DoT is FORCE-applied (gameplay setting). Most accurate as host."
	elseif flense_live then
		note = "Flense equipped: its real DoT is measured. Most accurate as host."
	else
		note = "Flense off: enable 'Allow gameplay' + 'Force Flense' to measure its DoT."
	end
	ui.text(gui, note, x, row_y(#TALENTS10 + 2), small, ui.grey)
end

return M
