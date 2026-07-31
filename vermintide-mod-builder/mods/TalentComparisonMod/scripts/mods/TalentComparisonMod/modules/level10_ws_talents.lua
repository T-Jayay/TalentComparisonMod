-- level10_ws_talents.lua
-- ============================================================================
-- Talent group: Level-10 Waystalker (Kerillian career "we_waywatcher").
-- CAREER-SPECIFIC, like the WHC / Merc / BW level-10 panels -- the panel is hidden
-- and NONE of the simulation runs unless the LOCAL player is currently playing
-- Waystalker. Values are hypothetical ("what would this talent have given me this
-- run") and are computed regardless of which of the three the player equipped.
--
-- A Waystalker picks 2 of these 3 at level 10 (talent_settings_kerillian.lua):
--   Blood Shot (kerillian_waywatcher_extra_arrow_melee_kill) -- a MELEE KILL
--     (light/heavy killing blow) grants a 10s buff; your NEXT ranged hit consumes
--     it and fires ONE extra projectile (stat_buff extra_shot +1, remove_on_proc).
--     Value = the extra arrow's damage, which we estimate as the damage of the
--     first ranged shot fired within 10s of a melee kill (the extra arrow is a
--     duplicate projectile of that shot). Equip-independent estimate.
--   Serrated Shots (kerillian_waywatcher_critical_bleed, perk kerillian_critical_
--     bleed_dot) -- despite the internal name, in DamageUtils.server_apply_hit
--     (damage_utils.lua:3698) EVERY projectile hit (charge_value == "projectile")
--     applies the weapon_bleed_dot_whc DoT (profile "bleed", tick 0.75s, dur 2s,
--     up to 3 stacks) -- the same bleed WHC Flense uses. It is DISABLED on a few
--     weapons (hagbane / deus) via the ..._disable perk. Rather than force the DoT
--     (gameplay change), we PROJECT it with the shared dot_sim module: per
--     projectile hit we compute one bleed tick's damage (re-run calculate_damage
--     with the "bleed" profile) and hand it to dot_sim, which schedules the ticks
--     forward until the unit dies. Pure estimate, equip-independent, no gameplay.
--   Drakira's Alacrity (kerillian_waywatcher_attack_speed_on_ranged_headshot) -- a
--     RANGED HEADSHOT (head/neck, not melee) grants +15% attack speed for 5s
--     (TOURNEY BALANCE: +20% for 10s -- drakira_speed()/drakira_duration())
--     (add_buff_on_ranged_headshot; the buff_on_stacks=5 field is ignored by the
--     func). Attack speed affects BOTH melee and ranged, so we value it with the
--     shared attack_speed_sim fed BOTH the melee swing stream and the ranged shot
--     stream, each swing/shot boosted x1.15 while the Drakira window is up.
--
-- WHAT IS SHOWN (Extra Damage, per unit-category buckets merged by the filter):
--   Blood Shot     : Total (overkill removed) / Uncapped (raw). ESTIMATION.
--   Serrated Shots : Total / Uncapped projected bleed damage. ESTIMATION.
--   Drakira        : Total = ghost-swing extra damage; plus an uptime line.
-- None of the three has a per-hit "who died sooner" model, so there is no Real
-- Total column (unlike the damage panels).
--
-- WIRING: this module owns NO hooks. Per-hit crediting is forwarded from the
-- level-15 DamageUtils.calculate_damage hook via mod._l10_ws_on_hit(ctx), and melee
-- swing starts from its ActionSweep.client_owner_start_action hook via
-- mod._l10_ws_on_swing_start(self). Non-DoT dedupe reuses mod._l15_melee_credit
-- (covers melee AND ranged -- the level-15 self_ctx window is opened for any genuine
-- local hit). Ranged shots have no start hook on the host, so they are segmented from
-- the hit stream by time gap (like the L20 ally-swing reconstruction). Most accurate
-- as host (calculate_damage resolves server-side).
-- ============================================================================

local M = {}

local mod   -- set in init()
local ui    -- shared ui_panel, set in init()
local F     -- unit_filter (mod._filter), set in init
local AttackSpeedSim  -- shared attack_speed_sim (dofiled in init)
local DotSim          -- shared dot_sim (dofiled in init)
local l10ws_kt        -- shared kill-tracker instance (mod._kill_tracker.new(), created in init)

local DBG = false
local function dlog(fmt, ...)
	if DBG and mod then
		local ok, s = pcall(string.format, "[TCM10WS] " .. fmt, ...)
		if not ok then s = "[TCM10WS] (log format error) " .. fmt end
		mod:echo((s:gsub("%%", "%%%%")))
	end
end

local WS_CAREER_NAME = "we_waywatcher"
-- Talent buff names for has_talent() detection (talent_settings_kerillian.lua).
local TALENT_BLOODSHOT = "kerillian_waywatcher_extra_arrow_melee_kill"
local TALENT_SERRATED  = "kerillian_waywatcher_critical_bleed"
local TALENT_DRAKIRA   = "kerillian_waywatcher_attack_speed_on_ranged_headshot"

-- Tourney Balance detection (same list/logic as the level-15 / L20 / THP panels).
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

-- Talent numbers (buff_tweak_data / buff templates in talent_settings_kerillian.lua).
local BLOODSHOT_WINDOW  = 10.0  -- extra_arrow_melee_kill_buff.duration
-- Drakira's Alacrity. TOURNEY BALANCE buffs it: attack speed 15% -> 20%, duration
-- 5s -> 10s. Resolved live so the ghost-sim boost + uptime window track whichever
-- mod is loaded.
local function drakira_speed()    return tb_mod_active() and 0.20 or 0.15 end
local function drakira_duration() return tb_mod_active() and 10.0 or 5.0  end
-- weapon_bleed_dot_whc (buff_templates.lua:5285): 0.75s ticks, 2s duration, <=3 stacks.
local BLEED_TICK_INTERVAL = 0.75
local BLEED_DURATION      = 2.0
local BLEED_MAX_STACKS    = 3
-- Serrated is turned off on some weapons (hagbane shortbow, deus) via this perk.
local SERRATED_DISABLE_PERK = "kerillian_critical_bleed_dot_disable"

-- A ranged "shot" has no start hook on the host; consecutive ranged hits within this
-- gap are the same shot (bow pierce, shotgun pellets), a new shot begins after it.
local RANGED_SHOT_GAP = 0.3
-- A swing/shot idle this long with no further hit is flushed (end of chain / whiff).
local ATTACK_IDLE_FLUSH = 1.0

-- ---------------------------------------------------------------------------
-- Running totals
-- ---------------------------------------------------------------------------
-- Blood Shot extra-arrow damage, per unit-category bucket { total, uncap }.
local bs_cat
-- Serrated bleed is banked inside its dot_sim instance.
local serrated_sim
-- Drakira attack-speed ghost sim (fed melee swings + ranged shots).
local drakira_sim
-- Drakira uptime bookkeeping.
local drakira_expiry     -- game-time expiry of the +15% attack-speed window
local uptime_total       -- integrated game-time since the first attack
local drakira_active_time
local first_attack_t

-- Current open attacks being accumulated for the attack-speed sim.
--   cur_melee : one melee swing (opened on swing start / first melee hit).
--   cur_ranged: one ranged shot (gap-segmented from the hit stream).
local cur_melee, cur_ranged
-- Blood Shot state: a melee-kill window and the currently-crediting extra-arrow shot.
local bloodshot_window   -- game-time expiry (10s) of the pending extra arrow
local bloodshot_shot     -- { expiry } while the triggering ranged shot is crediting

local function new_pair() return { total = 0, uncap = 0 } end
local function fresh_cat()
	return { elite = new_pair(), special = new_pair(), mon = new_pair(), trash = new_pair() }
end

function M.reset()
	bs_cat = fresh_cat()
	if l10ws_kt then l10ws_kt:reset() end
	if serrated_sim then serrated_sim:reset() end
	if drakira_sim then drakira_sim:reset() end
	drakira_expiry = nil
	uptime_total = 0
	drakira_active_time = 0
	first_attack_t = nil
	cur_melee = nil
	cur_ranged = nil
	bloodshot_window = nil
	bloodshot_shot = nil
end

bs_cat = fresh_cat()

-- Kill-column record for `talent` from the shared tracker, or an all-zero default
-- before its first credit (Blood Shot only; the DoT / attack-speed talents have none).
local ZERO_KILLS = { n = 0, saved_sum = 0, saved_n = 0, hpk_sum = 0, hpk_n = 0, real_total = 0 }
local function kget(talent)
	return (l10ws_kt and l10ws_kt:get(talent)) or ZERO_KILLS
end

-- ---------------------------------------------------------------------------
-- Helpers (mirror the other level-10 modules)
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

local function unit_alive(unit)
	if not Unit.alive(unit) then return false end
	local h = unit_current_health(unit)
	return h ~= nil and h > 0
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

local function career_is_ws()
	local unit = local_player_unit()
	if not unit then return false end
	local ce = ScriptUnit.has_extension(unit, "career_system")
	if not ce then return false end
	local ok, name = pcall(function () return ce:career_name() end)
	return ok and name == WS_CAREER_NAME
end

-- Panel/simulation active only while playing Waystalker.
local function active()
	return career_is_ws()
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

-- A projectile (bow/crossbow arrow) hit -- the only kind Serrated bleeds and the
-- kind Blood Shot's extra arrow duplicates. charge_value "projectile" per the game's
-- own Serrated gate (damage_utils.lua:3698).
local function is_projectile(dp)
	return dp and not dp.is_dot and dp.charge_value == "projectile"
end

-- Any non-DoT, non-melee attack (projectile + any other ranged action) -- used for
-- the Drakira attack-speed shot stream (attack speed affects all ranged, not just
-- projectiles) and Drakira's headshot arming.
local function is_ranged(dp)
	return dp and not dp.is_dot and not is_melee(dp)
end

local function has_perk(buff_ext, perk)
	if not buff_ext then return false end
	local ok, res = pcall(function () return buff_ext:has_buff_perk(perk) end)
	return ok and res or false
end

local function credit_pair(catset, cat, base, extra, health)
	if extra <= 0 then return end
	local capped = useful_extra(base, extra, health)
	catset[cat].total = catset[cat].total + capped
	catset[cat].uncap = catset[cat].uncap + extra
end

local CATS = { "elite", "special", "mon", "trash" }
local function merge_pair(catset)
	local total, uncap = 0, 0
	for _, c in ipairs(CATS) do
		if F.enabled(c) then
			total = total + catset[c].total
			uncap = uncap + catset[c].uncap
		end
	end
	return total, uncap
end

-- ---------------------------------------------------------------------------
-- Serrated Shots: compute one bleed tick's damage for a projectile hit by re-running
-- calculate_damage with the "bleed" damage profile, exactly as the game's DoT tick
-- does (server_apply_hit: profile "bleed", hit_zone "neck", crit false, boost 0,
-- damage_source "dot_debuff"). Hand it to dot_sim to project forward.
-- ---------------------------------------------------------------------------
local function bleed_tick_damage(ctx)
	local bleed = rawget(_G, "DamageProfileTemplates") and DamageProfileTemplates.bleed
	if not bleed then return nil end
	local ok, v = pcall(ctx.func, ctx.damage_output, ctx.target_unit, ctx.attacker_unit,
		"neck", ctx.original_power_level, ctx.boost_curve, 0, false,
		bleed, 1, ctx.backstab_multiplier, "dot_debuff")
	if ok and type(v) == "number" and v > 0 then return v end
	return nil
end

-- ---------------------------------------------------------------------------
-- Drakira attack-speed: feed a completed attack (melee swing or ranged shot) into
-- the ghost sim, boosted x1.15 if the Drakira window was up at the attack's start.
-- ---------------------------------------------------------------------------
local function feed_attack(atk)
	if not atk then return end
	if not first_attack_t then first_attack_t = atk.t end
	local m = 1.0
	if drakira_expiry and atk.t < drakira_expiry then
		m = 1.0 + drakira_speed()
	end
	drakira_sim:add_swing(atk.dmg, m)
	-- A ranged headshot in this attack (re)arms the window for SUBSEQUENT attacks.
	if atk.headshot then
		drakira_expiry = (atk.last_t or atk.t) + drakira_duration()
	end
end

local function finalize_melee()
	local atk = cur_melee
	cur_melee = nil
	feed_attack(atk)
end

local function finalize_ranged()
	local atk = cur_ranged
	cur_ranged = nil
	feed_attack(atk)
end

-- Called from the level-15 ActionSweep.client_owner_start_action hook for every melee
-- swing the local player starts: the previous swing is complete, open a fresh one.
local function on_swing_start(self)
	if not active() then return end
	if self.owner_unit ~= local_player_unit() then return end
	local dp = self._damage_profile
	if not is_melee(dp) then return end
	finalize_melee()
	cur_melee = { dmg = { elite = 0, special = 0, mon = 0, trash = 0 }, t = game_time(), last_t = game_time() }
end

-- ---------------------------------------------------------------------------
-- Per-hit crediting (from the level-15 calculate_damage hook via mod._l10_ws_on_hit)
-- ---------------------------------------------------------------------------
local function on_hit(ctx)
	if not active() then return end
	local attacker = ctx.attacker_unit
	if attacker ~= local_player_unit() then return end
	local final = ctx.final
	if not final or final <= 0 then return end
	local dp = ctx.damage_profile
	if not dp then return end

	-- Ignore real DoT ticks entirely: Serrated is projected (equip-independent), so
	-- a real bleed tick (when Serrated IS equipped) must not be double-counted.
	if dp.is_dot then return end

	local target = ctx.target_unit
	local health = unit_current_health(target)
	if health and health <= 0 then   -- corpse contact / already dead
		if serrated_sim then serrated_sim:forget(target) end
		return
	end
	local cat = ctx.cat or F.cat_of(target)
	local now = game_time()

	-- Dedupe each genuine hit once (melee AND ranged): the level-15 self_ctx window is
	-- opened for any real local hit, so this is the same per-genuine-hit decision.
	if not (mod._l15_melee_credit and mod._l15_melee_credit(ctx)) then return end

	local melee = is_melee(dp)

	if melee then
		-- Accumulate this swing's damage for the Drakira ghost sim.
		if not cur_melee then
			cur_melee = { dmg = { elite = 0, special = 0, mon = 0, trash = 0 }, t = now, last_t = now }
		end
		cur_melee.dmg[cat] = (cur_melee.dmg[cat] or 0) + final
		cur_melee.last_t = now

		-- Blood Shot: a melee KILLING BLOW arms the 10s extra-arrow window.
		if health and final >= health then
			bloodshot_window = now + BLOODSHOT_WINDOW
			dlog("BLOODSHOT melee kill -> window armed until %.2f", bloodshot_window)
		end
		return
	end

	if not is_ranged(dp) then return end

	-- --- Ranged shot stream (Drakira + Blood Shot). Gap-segment into shots. ---
	if cur_ranged and cur_ranged.last_t and (now - cur_ranged.last_t) > RANGED_SHOT_GAP then
		finalize_ranged()
	end
	local new_shot = not cur_ranged
	if new_shot then
		cur_ranged = { dmg = { elite = 0, special = 0, mon = 0, trash = 0 }, t = now, last_t = now, headshot = false }
	end
	cur_ranged.dmg[cat] = (cur_ranged.dmg[cat] or 0) + final
	cur_ranged.last_t = now
	if ctx.hit_zone_name == "head" or ctx.hit_zone_name == "neck" then
		cur_ranged.headshot = true
	end

	-- --- Blood Shot: the extra arrow duplicates the first ranged shot fired within
	-- 10s of a melee kill. Open a same-shot crediting window on that shot's first hit
	-- (consuming the 10s window), and credit every hit of that shot as the extra arrow.
	if new_shot and bloodshot_window and now <= bloodshot_window then
		bloodshot_shot = { expiry = now + RANGED_SHOT_GAP }
		bloodshot_window = nil   -- consumed (remove_on_proc: one ranged attack)
		dlog("BLOODSHOT extra-arrow shot opened")
	end
	if bloodshot_shot then
		if now <= bloodshot_shot.expiry then
			credit_pair(bs_cat, cat, 0, final, health)
			-- Real Total (kill-aware, shared kill_tracker, same mechanism as Famished
			-- Flames): the extra arrow duplicates this shot, so in the no-Blood-Shot world
			-- this target takes `final` (the real shot, which happens either way) and in
			-- the Blood-Shot world it takes `final` + the extra arrow (~= another `final`).
			-- The tracker credits only the part of that extra that actually pulled the kill
			-- sooner than the real shot alone (calibrated against the real applied damage).
			l10ws_kt:add("bloodshot", final, final * 2)
			bloodshot_shot.expiry = now + RANGED_SHOT_GAP
			dlog("BLOODSHOT extra-arrow credit %.2f (cat=%s)", final, cat)
		else
			bloodshot_shot = nil
		end
	end

	-- --- Serrated Shots: every projectile hit applies the bleed DoT (unless the
	-- weapon disables it). Project it via dot_sim (no gameplay change). ---
	if is_projectile(dp) then
		local buff_ext = ScriptUnit.has_extension(attacker, "buff_system")
		if not has_perk(buff_ext, SERRATED_DISABLE_PERK) then
			local tick = bleed_tick_damage(ctx)
			if tick then
				serrated_sim:apply(target, tick, now, health, cat)
				dlog("SERRATED apply tick=%.2f target hp=%s cat=%s", tick,
					health and string.format("%.0f", health) or "?", cat)
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- Init / wiring
-- ---------------------------------------------------------------------------
function M.init(owner_mod, ui_panel)
	mod = owner_mod
	ui = ui_panel
	F = mod._filter

	AttackSpeedSim = mod:dofile("scripts/mods/TalentComparisonMod/modules/attack_speed_sim")
	AttackSpeedSim.set_filter(F.enabled)
	DotSim = mod:dofile("scripts/mods/TalentComparisonMod/modules/dot_sim")
	DotSim.set_filter(F.enabled)

	-- Shared kill / Real-Total tracker (owned by level15, which inits first); own instance
	-- so this panel's Reset zeroes only its rows. Only Blood Shot feeds it.
	l10ws_kt = mod._kill_tracker.new()

	drakira_sim = AttackSpeedSim.new()
	serrated_sim = DotSim.new({
		tick_interval = BLEED_TICK_INTERVAL,
		duration = BLEED_DURATION,
		max_stacks = BLEED_MAX_STACKS,
	})

	M.reset()

	-- Forwarded by the level-15 module's shared hooks (see its init).
	mod._l10_ws_on_hit = function (ctx) pcall(on_hit, ctx) end
	mod._l10_ws_on_swing_start = function (self) pcall(on_swing_start, self) end
end

-- ---------------------------------------------------------------------------
-- Update: advance the Serrated bleed projection, flush idle attacks, integrate uptime.
-- ---------------------------------------------------------------------------
function M.update(dt)
	if serrated_sim then serrated_sim:update(dt, game_time(), unit_alive) end
	if not active() then return end
	local now = game_time()

	-- Flush attacks that have gone idle (end of a chain / a whiff with no next start).
	if cur_melee and cur_melee.last_t and (now - cur_melee.last_t) > ATTACK_IDLE_FLUSH then
		finalize_melee()
	end
	if cur_ranged and cur_ranged.last_t and (now - cur_ranged.last_t) > ATTACK_IDLE_FLUSH then
		finalize_ranged()
	end

	-- Expire the Blood Shot windows on their own timeline.
	if bloodshot_window and now > bloodshot_window then bloodshot_window = nil end
	if bloodshot_shot and now > bloodshot_shot.expiry then bloodshot_shot = nil end

	-- Integrate Drakira uptime (only after the first attack, when the ghost timeline starts).
	if first_attack_t then
		uptime_total = uptime_total + dt
		if drakira_expiry and now < drakira_expiry then
			drakira_active_time = drakira_active_time + dt
		end
	end
end

-- ---------------------------------------------------------------------------
-- Display
-- ---------------------------------------------------------------------------
local T10WS_TOTAL_COL = 200
local T10WS_UNCAP_COL = 330
local T10WS_REAL_COL  = 460   -- Real Total: extra damage that actually pulled kills sooner
local PANEL_W_T10WS   = 660
local ui_red = Color(255, 255, 60, 60)

local T10WS_TITLE = "Blood Shot / Serrated Shots / Drakira's Alacrity:"

function M.wants_display()
	return active()
end

local function uptime_pct()
	if not uptime_total or uptime_total <= 0 then return 0 end
	return drakira_active_time / uptime_total * 100
end

function M.log_state()
	if not DBG then return end
	local bs_t, bs_u = merge_pair(bs_cat)
	local sr_t, sr_u = serrated_sim:totals()
	dlog("L10WS SNAP bloodshot=%.1f (%.1f) real=%.1f | serrated=%.1f (%.1f) | drakira=%.1f up=%.1f%%",
		bs_t, bs_u, kget("bloodshot").real_total, sr_t, sr_u, drakira_sim:extra(), uptime_pct())
end

function M.reset_self()
	if M.log_state then pcall(M.log_state) end
	M.reset()
end

function M.draw(gui)
	local FONT_SIZE = ui.FONT_SIZE
	local small = FONT_SIZE - 6

	local player_unit = local_player_unit()
	-- Drakira equipped contaminates the observed attack cadence (real swings/shots are
	-- already sped up), so the ghost delta is no longer a clean measurement -- warn, as
	-- the L20 Enhanced Training panel does.
	local drakira_equipped = player_unit and talent_equipped(player_unit, TALENT_DRAKIRA)
	local off = drakira_equipped and 1 or 0

	-- rows (last index): title(0) header(1) BloodShot(2) Serrated(3) Drakira(4)
	-- uptime(5); a shown warning shifts everything down one (off).
	local content_rows = 5 + off
	local x, top, row_y, collapsed, title_visible = ui.frame(gui, PANEL_W_T10WS, content_rows,
		"l10ws_pos_x", "l10ws_pos_y", 0.03, 0.35, "l10ws", M.reset_self)
	if not x then return end

	if collapsed then
		if title_visible then
			ui.text_bold(gui, "Blood Shot / Serrated / Drakira:", x, row_y(0), FONT_SIZE, ui.yellow)
		end
		return
	end

	if drakira_equipped then
		ui.text_bold(gui, "Unequip Drakira's Alacrity for an accurate attack-speed estimate!",
			x, row_y(0), FONT_SIZE, ui_red)
	end

	if title_visible then
		ui.text_bold(gui, T10WS_TITLE, x, row_y(0 + off), FONT_SIZE, ui.yellow)
	end

	ui.text(gui, "Extra Damage:", x, row_y(1 + off), small, ui.grey)
	ui.text(gui, "Total", x + T10WS_TOTAL_COL, row_y(1 + off), small, ui.grey)
	ui.text(gui, "Uncapped", x + T10WS_UNCAP_COL, row_y(1 + off), small, ui.grey)
	ui.text(gui, "Real Total", x + T10WS_REAL_COL, row_y(1 + off), small, ui.grey)

	-- `uncap` nil -> mark the Uncapped cell ESTIMATION; `real` nil -> "-" (no per-hit
	-- kill model). Real Total is kill-aware: extra damage that actually pulled a kill.
	local function row(i, name, total, uncap, real)
		local ry = row_y(i)
		ui.text(gui, name, x, ry, FONT_SIZE, ui.white)
		ui.text(gui, string.format("%.0f", total), x + T10WS_TOTAL_COL, ry, FONT_SIZE, ui.white)
		if uncap then
			ui.text(gui, string.format("%.0f", uncap), x + T10WS_UNCAP_COL, ry, FONT_SIZE, ui.white)
		else
			ui.text(gui, "ESTIMATION", x + T10WS_UNCAP_COL, ry, small, ui.grey)
		end
		ui.text(gui, real and string.format("%.0f", real) or "-", x + T10WS_REAL_COL, ry, FONT_SIZE, ui.white)
	end

	-- Blood Shot: extra arrow's damage; Real Total from the shared kill_tracker.
	local bs_total, bs_uncap = merge_pair(bs_cat)
	row(2 + off, "Blood Shot", bs_total, bs_uncap, kget("bloodshot").real_total)

	-- Serrated Shots: projected bleed damage (dot_sim). A forward DoT projection has no
	-- real add_damage to calibrate a kill against (like Lingering Flames), so Real "-".
	local sr_total, sr_uncap = serrated_sim:totals()
	row(3 + off, "Serrated Shots", sr_total, sr_uncap, nil)

	-- Drakira's Alacrity: ghost-swing extra damage from +15% attack speed. A cadence
	-- estimate, not a per-hit delta -> Uncapped ESTIMATION, no Real Total (like ET).
	row(4 + off, "Drakira's Alacrity", drakira_sim:extra(), nil, nil)

	ui.text(gui, string.format("Drakira uptime: %.0f%%", uptime_pct()),
		x, row_y(5 + off), small, ui.grey)
end

return M
