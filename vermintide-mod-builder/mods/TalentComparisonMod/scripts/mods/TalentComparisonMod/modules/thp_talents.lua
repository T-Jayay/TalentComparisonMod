-- thp_talents.lua
-- ============================================================================
-- Talent group: Temp Health (level-5 talents).
--
-- Shows, as a running total for the current run, how much temp health EACH of
-- Sting / Carve / Execute / Second Wind would have generated, regardless of
-- which one is equipped. Optional "Tourney Balance" (TB) column shows the same
-- events under the rebalanced values (Regrowth / Reaper / Bloodlust / Vanguard),
-- including the corpse-stagger bug fix for Vanguard.
--
-- Formulas mirror the game's thp_* buff functions. This module's behavior is
-- intentionally unchanged from the original mod.
-- ============================================================================

local M = {}

local mod   -- set in init()
local ui    -- shared ui_panel, set in init()

-- Debug logging: per-event inputs + outputs so each formula can be verified by
-- hand from the chat/log output. Flip DBG off to silence everything at once.
local DBG = false
local function dlog(fmt, ...)
	if DBG and mod then
		local ok, s = pcall(string.format, "[TCM] " .. fmt, ...)
		if not ok then s = "[TCM] (log format error) " .. fmt end
		-- mod:echo re-runs string.format on its argument, so literal % must be
		-- re-escaped or VMF crashes on e.g. "dec%:".
		mod:echo((s:gsub("%%", "%%%%")))
	end
end

-- ---------------------------------------------------------------------------
-- Running totals
-- ---------------------------------------------------------------------------
-- The THP generated per talent, partitioned by the gaining hit/kill's unit category
-- (es / mon / trash) so the panel's Live/TB columns filter with the control panel.
-- `totals` points at the active category during a gain event and at a merged view in
-- draw. (The Decay / Dec % / Blocked columns model per-talent pools and are NOT
-- category-split -- they stay aggregate; documented on the decay table below.)
local function fresh_totals()
	return {
		-- live values
		sting = 0, carve = 0, execute = 0, second_wind = 0,
		-- Tourney Balance values
		tb_regrowth = 0,   -- <- sting        (rebaltourn_heal_finesse: crit 1.5 / hs 3)
		tb_reaper = 0,     -- <- carve        (flat 1, targets 1-5 only)
		tb_bloodlust = 0,  -- <- execute      (TB-overridden breed.bloodlust_health)
		tb_vanguard = 0,   -- <- second_wind  (raw stagger x1, no kill credit)
	}
end

local F   -- unit_filter (mod._filter), set in init
local totals_cat = { es = fresh_totals(), mon = fresh_totals(), trash = fresh_totals() }
local totals = totals_cat.trash

-- Per-swing latch for Regrowth (TB Sting): the finesse heal fires only on the
-- first crit/headshot hit of a swing (`has_procced`), reset when target_index 1
-- comes round again. Mirrors `rebaltourn_heal_finesse_damage_on_melee`.
local regrowth_procced = false

-- ---------------------------------------------------------------------------
-- Decay model ("Decayed" column)
-- ---------------------------------------------------------------------------
-- For EACH talent independently, model the temp-health pool it would have
-- generated and how much of that pool would then have decayed away. Every THP
-- gain grows the talent's pool and (re)arms its decay to start DEGEN_START
-- seconds later; while armed and non-empty, the pool loses DEGEN_AMOUNT per
-- tick and we accumulate `lost`, the running total shown in the column.
--
-- Rates are the game's (player_unit_health_extension.lua / player_unit_status_
-- settings.lua): each level-5 THP talent equips a healing perk (smiter/linesman/
-- tank/ninja_healing) whose not-wounded rate is 0.25 every 0.25 s (1.0 THP/s);
-- while wounded the perk is ignored and it uses 0.25 every 0.5 s (0.5 THP/s).
-- Decay begins 3 s after the most recent gain. All four talents share these
-- rates, so only their gain events (which pool/re-arm below) differ.
--
-- Per the chosen model the pool is UNCAPPED (no max-health clamp) and damage
-- taken is ignored, so `lost` is an upper bound on decay for that talent.
local DEGEN_START         = 3     -- seconds after last gain before decay starts
local DEGEN_AMOUNT        = 0.25  -- THP removed per tick
local DEGEN_DELAY_NORMAL  = 0.25  -- tick period, not wounded (1.0 THP/s)
local DEGEN_DELAY_WOUNDED = 0.5   -- tick period, wounded    (0.5 THP/s)

-- Monotonic clock advanced from update(dt); gains stamp their re-arm time here.
local decay_clock = 0

-- Per talent:
--   timer                   -> shared decay-delay clock for the realistic pool
--   first_t/last_t/decaying_time -> "% time decaying" column (gain cadence only)
--   rpool/blocked           -> "Blocked" column (realistic pool: capped at the
--                              player's free health, decayed, and drained by real
--                              damage taken; `blocked` is the running total the
--                              pool absorbed).
local function new_decay_state()
	return { timer = math.huge,
	         first_t = nil, last_t = 0, decaying_time = 0,
	         rpool = 0, blocked = 0 }
end

local decay = {
	sting       = new_decay_state(),
	carve       = new_decay_state(),
	execute     = new_decay_state(),
	second_wind = new_decay_state(),
}

-- Sting and Carve are both frequent-melee-hit-driven procs; their gain cadence
-- (and thus "Dec %") is modeled as identical rather than tracked independently
-- so the column reads the same number for both rows.
local sting_carve_cadence = { first_t = nil, last_t = 0, decaying_time = 0 }

-- Free health the realistic THP pool may fill (max_health - permanent_health),
-- refreshed each update. THP can never push total health past max, so gains are
-- clamped to this. Defaults to "no cap" until the first update reads real health.
local current_cap = math.huge

-- Multiplier for THP the realistic pool receives, from the local player's
-- `healing_received` stat buff (Increased Healing necklace trait / properties).
-- The game runs temp-health gains through `DamageUtils.apply_buffs_to_heal`,
-- which scales the heal by `healing_received`, so more Increased Healing means
-- more THP generated -- and thus more damage the pool can block. Only the Blocked
-- column (realistic pool) uses this; Live/TB/Dec %/Decay stay unscaled. Refreshed
-- each update; defaults to 1 (no increased healing) until real buffs are read.
local healing_mult = 1

-- Record a THP gain for `key`: grow the realistic pool and (re)arm the 3 s decay
-- delay. The amount is scaled by the player's `healing_received` multiplier and
-- clamped so the pool never exceeds free health (excess THP is simply wasted).
local function register_gain(key, amount)
	if not amount or amount <= 0 then return end
	local d = decay[key]
	d.rpool = math.min(d.rpool + amount * healing_mult, current_cap)
	d.timer = decay_clock + DEGEN_START
	d.first_t = d.first_t or decay_clock
	d.last_t  = decay_clock

	if key == "sting" or key == "carve" then
		sting_carve_cadence.first_t = sting_carve_cadence.first_t or decay_clock
		sting_carve_cadence.last_t  = decay_clock
	end
end

function M.reset()
	totals_cat = { es = fresh_totals(), mon = fresh_totals(), trash = fresh_totals() }
	totals = totals_cat.trash
	for _, d in pairs(decay) do
		d.timer = math.huge
		d.first_t = nil
		d.last_t  = 0
		d.decaying_time = 0
		d.rpool   = 0
		d.blocked = 0
	end
	sting_carve_cadence.first_t = nil
	sting_carve_cadence.last_t  = 0
	sting_carve_cadence.decaying_time = 0
	regrowth_procced = false
	current_cap = math.huge
	healing_mult = 1
	mod._pending_stagger_unit = nil
	mod._pending_stagger_amount = nil
	mod._sw_pred = {}
	mod._sw_now = nil
end

-- Neither Second Wind talent grants stagger THP on a killing blow: the game
-- applies damage first, then only runs the stagger proc `if target_alive`
-- (damage_utils.lua server_apply_hit), so a hit that kills never fires `on_stagger`.
-- Both the Official (thp_tank) and TB (rebaltourn_vanguard) buffs use `on_stagger`,
-- so both simply never see these staggers -- there is nothing to credit on kill.
-- (The server_apply_hit hook below still runs; it drives the Level-15 Bulwark
-- stagger window via `mod._on_player_stagger`, not any THP crediting here.)

local function local_player_unit()
	if not Managers.player then return nil end
	local ok, player = pcall(function () return Managers.player:local_player() end)
	if not ok or not player then return nil end
	return player.player_unit
end

-- True when the Tourney Balance mod is loaded (and enabled). In that case the
-- game is already applying the TB `rebaltourn_*` talents, so our own "Live"
-- column becomes the hypothetical vanilla/"Official" values and the TB column is
-- reality -- the panel relabels/reorders accordingly (see M.draw).
--
-- The canonical internal id (from the repo's .mod, `new_mod(...)`) is
-- "TourneyBalance" -- NOT the Steam workshop title ("Tourney Balance Testing").
-- We try a few candidate ids so a differently-registered testing build is still
-- detected; `get_mod` returns nil for any id that isn't registered.
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

-- Local player's equipped melee item name (e.g. "wh_2h_billhook"), for Vanguard's
-- weapon-specific THP caps. nil if unreadable.
local function local_player_melee_item_name()
	local unit = local_player_unit()
	if not unit then return nil end
	local ok, name = pcall(function ()
		local inv = ScriptUnit.has_extension(unit, "inventory_system")
		if not inv then return nil end
		local eq = inv:equipment()
		local slot = eq and eq.slots and eq.slots.slot_melee
		return slot and slot.item_data and slot.item_data.name
	end)
	if ok then return name end
	return nil
end

-- Wounded local player -> decay ticks at the slower (0.5 THP/s) wounded rate.
local function local_player_is_wounded()
	local unit = local_player_unit()
	if not unit then return false end
	local ok, wounded = pcall(function ()
		local status = ScriptUnit.has_extension(unit, "status_system")
		return status and status:is_wounded()
	end)
	return ok and wounded == true
end

-- Free health available to temp health: max_health - permanent_health. Returns
-- nil if it can't be read (leave the previous cap in place that frame).
local function local_player_free_health()
	local unit = local_player_unit()
	if not unit then return nil end
	local ok, cap = pcall(function ()
		local health = ScriptUnit.has_extension(unit, "health_system")
		if not health or not health.get_max_health or not health.current_permanent_health then
			return nil
		end
		return math.max(0, health:get_max_health() - health:current_permanent_health())
	end)
	if ok and cap then return cap end
	return nil
end

-- Local player's `healing_received` multiplier (Increased Healing). Mirrors the
-- game's `DamageUtils.apply_buffs_to_heal`, which does
-- `buff_extension:apply_buffs_to_value(heal_amount, "healing_received")`. Returns
-- nil if unreadable (keep the previous value that frame).
local function local_player_healing_mult()
	local unit = local_player_unit()
	if not unit then return nil end
	local ok, mult = pcall(function ()
		local buff = ScriptUnit.has_extension(unit, "buff_system")
		if not buff or not buff.apply_buffs_to_value then return nil end
		return buff:apply_buffs_to_value(1, "healing_received")
	end)
	if ok and mult then return mult end
	return nil
end

-- TB fix (partial): Vanguard (Stagger) must NOT grant THP on corpses -- the live
-- bug lets shield-bash hitboxes stagger already-downed units. A truly dead unit
-- reports `dead`; clients also carry a predicted-dead flag for units downed in
-- the same sweep. Returns true when the target should be treated as a corpse.
local function target_is_corpse(unit)
	local ok, dead = pcall(function ()
		local health = ScriptUnit.has_extension(unit, "health_system")
		if not health then return false end
		if health.dead then return true end
		if health.client_predicted_is_alive and not health:client_predicted_is_alive() then
			return true
		end
		return false
	end)
	return ok and dead
end

-- ---------------------------------------------------------------------------
-- Bloodlust / Execute kill-THP tables
-- ---------------------------------------------------------------------------
-- Both Execute (Official, thp_smiter) and Bloodlust (TB, rebaltourn_bloodlust /
-- heal_percentage_of_enemy_hp_on_melee_kill) heal `breed.bloodlust_health` on a
-- melee kill -- but Tourney Balance OVERRIDES that field for some breeds (e.g.
-- Chaos Warrior 30 -> 20), so the two columns differ. Only the currently-loaded
-- mod's value is live in `breed.bloodlust_health`, so we read it for the ACTIVE
-- scenario's column and fall back to the hardcoded table for the other column.
--
-- `BL_OFFICIAL` is vanilla `BreedTweaks.bloodlust_health` (breed_tweaks.lua:594),
-- keyed by category; `BL_TB` is the Tourney Balance override (only differing
-- categories need listing -- others fall back to the live/vanilla value).
local TB_BREED_CATEGORY = {
	-- beastmen
	beastmen_bestigor = "beastmen_elite",
	beastmen_standard_bearer = "beastmen_elite",
	beastmen_standard_bearer_crater = "beastmen_elite",
	beastmen_gor = "beastmen_roamer",
	beastmen_ungor = "beastmen_horde",
	beastmen_ungor_archer = "beastmen_horde",
	beastmen_minotaur = "monster",
	-- chaos
	chaos_berzerker = "chaos_elite",
	chaos_raider = "chaos_elite",
	ethereal_skeleton_with_hammer = "chaos_elite",
	chaos_bulwark = "chaos_bulwark",
	chaos_corruptor_sorcerer = "chaos_special",
	chaos_mutator_sorcerer = "chaos_special",
	chaos_tether_sorcerer = "chaos_special",
	chaos_vortex_sorcerer = "chaos_special",
	chaos_fanatic = "chaos_horde",
	chaos_marauder = "chaos_roamer",
	chaos_marauder_with_shield = "chaos_roamer",
	chaos_skeleton = "chaos_roamer",
	ethereal_skeleton_with_shield = "chaos_roamer",
	pet_skeleton = "chaos_roamer",
	pet_skeleton_armored = "chaos_roamer",
	pet_skeleton_dual_wield = "chaos_roamer",
	pet_skeleton_with_shield = "chaos_roamer",
	chaos_warrior = "chaos_warrior",
	chaos_exalted_champion_warcamp = "monster",
	chaos_exalted_champion_norsca = "monster",
	chaos_exalted_sorcerer = "monster",
	chaos_exalted_sorcerer_drachenfels = "monster",
	chaos_spawn = "monster",
	chaos_spawn_exalted_champion_norsca = "monster",
	chaos_troll = "monster",
	chaos_troll_chief = "monster",
	-- skaven
	skaven_plague_monk = "skaven_elite",
	skaven_storm_vermin = "skaven_elite",
	skaven_storm_vermin_commander = "skaven_elite",
	skaven_storm_vermin_with_shield = "skaven_elite",
	skaven_gutter_runner = "skaven_special",
	skaven_loot_rat = "skaven_special",
	skaven_pack_master = "skaven_special",
	skaven_poison_wind_globadier = "skaven_special",
	skaven_ratling_gunner = "skaven_special",
	skaven_warpfire_thrower = "skaven_special",
	skaven_clan_rat = "skaven_roamer",
	skaven_clan_rat_with_shield = "skaven_roamer",
	skaven_explosive_loot_rat = "skaven_roamer",
	skaven_slave = "skaven_horde",
	skaven_grey_seer = "monster",
	skaven_rat_ogre = "monster",
	skaven_stormfiend = "monster",
	skaven_stormfiend_boss = "monster",
	skaven_storm_vermin_champion = "monster",
	skaven_storm_vermin_warlord = "monster",
}

-- Vanilla BreedTweaks.bloodlust_health (Official).
local BL_OFFICIAL = {
	beastmen_horde = 1.5,
	beastmen_roamer = 3,
	beastmen_elite = 15,
	chaos_horde = 1.5,
	chaos_roamer = 3,
	chaos_elite = 15,
	chaos_special = 10,
	chaos_warrior = 30,
	chaos_bulwark = 35,
	skaven_horde = 1,
	skaven_roamer = 2,
	skaven_elite = 8,
	skaven_special = 8,
	monster = 50,
}

-- Tourney Balance overrides (only the categories TB changes from vanilla).
local BL_TB = {
	chaos_elite = 10,
	chaos_warrior = 20,
	monster = 35,
}

-- Category of the killed breed, or nil.
local function breed_category(breed)
	return breed and breed.name and TB_BREED_CATEGORY[breed.name]
end

-- Official (vanilla) bloodlust_health for this breed. When the TB mod ISN'T
-- loaded the live field is already vanilla; when it IS loaded the live field is
-- TB's, so use the hardcoded vanilla table.
local function official_bloodlust(breed)
	local live = breed.bloodlust_health or 0
	if not tb_mod_active() then return live end
	local cat = breed_category(breed)
	return (cat and BL_OFFICIAL[cat]) or live
end

-- Tourney Balance bloodlust_health for this breed. When the TB mod IS loaded the
-- live field is already TB's; when it ISN'T, use the hardcoded TB override (only
-- some categories differ -- the rest fall back to the live/vanilla value).
local function tb_bloodlust(breed)
	local live = breed.bloodlust_health or 0
	if tb_mod_active() then return live end
	local cat = breed_category(breed)
	return (cat and BL_TB[cat]) or live
end

-- ---------------------------------------------------------------------------
-- Temp-health formulas (mirrors of the game's thp_*_func functions)
-- ---------------------------------------------------------------------------

-- Sting / thp_ninjafencer: event on_hit
local function sting_amount(params)
	local hit_unit    = params[1]
	local attack_type = params[2]
	local hit_zone    = params[3]
	local target_num  = params[4]
	local crit        = params[6]
	local breed = AiUtils.unit_breed(hit_unit)
	if not breed then return 0 end
	if not (attack_type == "light_attack" or attack_type == "heavy_attack") then return 0 end
	if target_num ~= 1 then return 0 end

	local bonus = 2
	local weakspot = hit_zone == "head" or hit_zone == "neck" or hit_zone == "weakspot"
	if crit and weakspot then
		return bonus * 2
	elseif crit or weakspot then
		return bonus
	else
		return bonus / 4
	end
end

-- Regrowth (TB Sting) / rebaltourn_heal_finesse_damage_on_melee: fires only on
-- the FIRST crit/headshot hit of a swing (has_procced, reset when target 1 comes
-- round), and crit + headshot stack in the same hit. Non-finesse hits give 0 --
-- unlike Sting there is no base heal. Not restricted to target_index 1 (any hit
-- may be the swing's first finesse hit).
--   headshot -> 3, crit -> 1.5, crit+headshot -> 4.5, plain -> 0
local function regrowth_amount(params)
	local hit_unit    = params[1]
	local attack_type = params[2]
	local hit_zone    = params[3]
	local target_num  = params[4]
	local crit        = params[6]
	if target_num == 1 then regrowth_procced = false end
	if regrowth_procced then return 0 end
	local breed = AiUtils.unit_breed(hit_unit)
	if not breed then return 0 end
	if not (attack_type == "light_attack" or attack_type == "heavy_attack") then return 0 end

	local weakspot = hit_zone == "head" or hit_zone == "neck" or hit_zone == "weakspot"
	local heal = 0
	if weakspot then heal = heal + 3;   regrowth_procced = true end
	if crit     then heal = heal + 1.5; regrowth_procced = true end
	return heal
end

-- Carve / thp_linesman: event on_player_damage_dealt
local function carve_amount(params)
	local hit_unit    = params[1]
	local damage      = params[2]
	local attack_type = params[6]
	local target_num  = params[7]
	if not (attack_type == "light_attack" or attack_type == "heavy_attack") then return 0 end
	local breed = AiUtils.unit_breed(hit_unit)
	if not breed then return 0 end
	if not damage or damage <= 0 then return 0 end
	if not target_num then return 0 end

	local base_value      = 1
	local target_dropoff  = 5
	local max_targets     = 10
	local dropoff_divisor = 2
	if target_dropoff < target_num then
		base_value = base_value / dropoff_divisor
	end
	if target_num <= max_targets then
		return base_value
	end
	return 0
end

-- Reaper (TB Carve) / heal_damage_targets_on_melee: flat 1 THP per hit target,
-- but only for targets 1-5 (max_targets = 5). Unlike Carve there is no 0.5
-- drop-off tier for targets 6-10 -- cleave past 5 gives nothing.
local function reaper_amount(params)
	local hit_unit    = params[1]
	local damage      = params[2]
	local attack_type = params[6]
	local target_num  = params[7]
	if not (attack_type == "light_attack" or attack_type == "heavy_attack") then return 0 end
	local breed = AiUtils.unit_breed(hit_unit)
	if not breed then return 0 end
	if not damage or damage <= 0 then return 0 end
	if not target_num then return 0 end
	if target_num <= 5 then return 1 end
	return 0
end

-- Shared gate for both kill-THP rows: only non-hero melee (light/heavy) kills
-- count. Returns the killed breed, or nil.
local function kill_breed(params)
	local killing_blow = params[1]
	local breed        = params[2]
	if not killing_blow then return nil end
	local attack_type = killing_blow[DamageDataIndex.ATTACK_TYPE]
	if not (attack_type == "light_attack" or attack_type == "heavy_attack") then return nil end
	if not breed or breed.is_hero then return nil end
	return breed
end

-- Execute (Official / thp_smiter): vanilla breed.bloodlust_health on melee kill.
local function execute_amount(params)
	local breed = kill_breed(params)
	if not breed then return 0 end
	return official_bloodlust(breed)
end

-- Bloodlust (TB / heal_percentage_of_enemy_hp_on_melee_kill): same event as
-- Execute, but TB overrides bloodlust_health for some breeds (see BL_TB), so this
-- reads the TB value -- differing from Execute exactly on those breeds.
local function bloodlust_amount(params)
	local breed = kill_breed(params)
	if not breed then return 0 end
	return tb_bloodlust(breed)
end

-- Second Wind / thp_tank: stagger + kill sources.
local STAGGER_INDEX = { 0.25, 1, 2 }
local function second_wind_stagger_amount(params)
	local hit_unit       = params[1]
	local damage_profile = params[2]
	local stagger_type   = params[4]
	local stagger_value  = params[6]
	local target_index   = params[8]
	if not damage_profile then return 0 end
	local attack_type = damage_profile.charge_value
	local breed = AiUtils.unit_breed(hit_unit)
	if not breed or breed.is_hero then return 0 end

	local base_value = 1
	if damage_profile.is_push then
		base_value = base_value * 0.5
	end
	local max_targets = 5
	local stagger_calc = math.min(math.max(stagger_type or 0, stagger_value or 0), 3)
	local stagger_multiplier = STAGGER_INDEX[stagger_calc] or 1
	local heal = base_value * stagger_multiplier
	if target_index and target_index <= max_targets
		and (attack_type == "light_attack" or attack_type == "heavy_attack" or attack_type == "action_push") then
		return heal
	end
	return 0
end

local function second_wind_kill_amount(params)
	local killing_blow = params[1]
	local breed        = params[2]
	if not killing_blow then return 0 end
	local attack_type = killing_blow[DamageDataIndex.ATTACK_TYPE]
	if not (attack_type == "light_attack" or attack_type == "heavy_attack") then return 0 end
	if not breed or breed.is_hero then return 0 end
	local target_index = killing_blow[16]
	local max_targets = 5
	if target_index and target_index <= max_targets then
		return 0.25
	end
	return 0
end

-- Vanguard (TB Second Wind) / rebaltourn_heal_stagger_targets_on_melee.
-- Differs from the vanilla thp_tank formula above in every dimension:
--   * heal is the RAW stagger number (stagger_type or stagger_value) x multiplier
--     1 -- NOT the {0.25,1,2} stagger-index mapping, so it is ~2x thp_tank.
--   * push is a flat 0.6 (not base x 0.5).
--   * target gate is target_index < 5 (targets 1-4), not <= 5.
--   * weapon caps: billhook stagger 9 -> 2; ghost-scythe discharge -> 0.25;
--     shield-slam heavy (attack_template "heavy_blunt_fencer") -> 0.75.
--   * on_stagger ONLY -- there is no on-kill component (see on_kill handler).
local function vanguard_weapon_cap(heal, damage_profile)
	local item = local_player_melee_item_name()
	if not item then return heal end
	local attack_type = damage_profile.charge_value
	if item == "wh_2h_billhook" and heal == 9 then
		return 2
	end
	if item == "bw_ghost_scythe" and damage_profile.is_discharge
		and not damage_profile.is_push and heal > 0 then
		return 0.25
	end
	if attack_type == "heavy_attack" and heal > 0
		and damage_profile.default_target
		and damage_profile.default_target.attack_template == "heavy_blunt_fencer" then
		return 0.75
	end
	return heal
end

local function vanguard_amount(params)
	local hit_unit       = params[1]
	local damage_profile = params[2]
	local stagger_type   = params[4]
	local stagger_value  = params[6]
	local target_index   = params[8]
	if not damage_profile then return 0 end
	local attack_type = damage_profile.charge_value
	local breed = AiUtils.unit_breed(hit_unit)
	if not breed or breed.is_hero then return 0 end
	if not (target_index and target_index < 5) then return 0 end
	if not (attack_type == "light_attack" or attack_type == "heavy_attack" or attack_type == "action_push") then
		return 0
	end
	-- Lua truthiness: stagger_type is used whenever non-nil (0 stays 0).
	local heal = (stagger_type or stagger_value) or 0
	if damage_profile.is_push then
		heal = 0.6
	end
	return vanguard_weapon_cap(heal, damage_profile)
end

-- ---------------------------------------------------------------------------
-- Hooks
-- ---------------------------------------------------------------------------
function M.init(owner_mod, ui_panel)
	mod = owner_mod
	ui = ui_panel
	F = mod._filter

	-- Buff-proc event hook: fires for every proc on every unit; filter to ours.
	mod:hook_safe(BuffExtension, "trigger_procs", function (self, event, ...)
		if self._unit ~= local_player_unit() then
			return
		end

		local params = { ... }

		if event == "on_hit" then
			totals = totals_cat[F.cat_of(params[1])]
			local sting = sting_amount(params)
			local regrowth = regrowth_amount(params)
			totals.sting = totals.sting + sting
			totals.tb_regrowth = totals.tb_regrowth + regrowth
			register_gain("sting", sting)
			if params[2] == "light_attack" or params[2] == "heavy_attack" then
				local br = AiUtils.unit_breed(params[1])
				dlog("STING breed=%s type=%s zone=%s tgt=%s crit=%s -> live=%.2f tb=%.2f",
					tostring(br and br.name), tostring(params[2]), tostring(params[3]),
					tostring(params[4]), tostring(params[6]), sting, regrowth)
			end
		elseif event == "on_player_damage_dealt" then
			totals = totals_cat[F.cat_of(params[1])]
			local carve = carve_amount(params)
			totals.carve = totals.carve + carve
			totals.tb_reaper = totals.tb_reaper + reaper_amount(params)
			register_gain("carve", carve)
			if params[6] == "light_attack" or params[6] == "heavy_attack" then
				dlog("CARVE tgt_idx=%s dmg=%.2f type=%s -> %.2f",
					tostring(params[7]), params[2] or 0, tostring(params[6]), carve)
			end
		elseif event == "on_stagger" then
			-- Only fires for staggers on units that survived the hit (the game skips
			-- this proc for killing blows). Both live and TB count these.
			totals = totals_cat[F.cat_of(params[1])]
			local stagger = second_wind_stagger_amount(params)
			totals.second_wind = totals.second_wind + stagger
			local corpse = target_is_corpse(params[1])
			if not corpse then
				totals.tb_vanguard = totals.tb_vanguard + vanguard_amount(params)
			end
			register_gain("second_wind", stagger)
			dlog("SW-STAG type=%s val=%s idx=%s push=%s corpse=%s -> %.2f",
				tostring(params[4]), tostring(params[6]), tostring(params[8]),
				tostring(params[2] and params[2].is_push), tostring(corpse), stagger)
		elseif event == "on_kill" then
			-- Prefer the killed breed (params[2]); fall back to the killed unit (params[3]).
			totals = totals_cat[params[2] and F.cat_of_breed(params[2]) or F.cat_of(params[3])]
			local execute = execute_amount(params)
			local bloodlust = bloodlust_amount(params)
			totals.execute = totals.execute + execute
			totals.tb_bloodlust = totals.tb_bloodlust + bloodlust
			register_gain("execute", execute)
			do
				local br = params[2]
				local kb = params[1]
				dlog("EXEC breed=%s bl_health=%s kb_idx=%s -> live=%.2f tb=%.2f",
					tostring(br and br.name), tostring(br and br.bloodlust_health),
					tostring(kb and kb[16]), execute, bloodlust)
			end
			-- Only vanilla thp_tank (Official Second Wind) heals on a melee kill; the
			-- TB Vanguard template is on_stagger-only, so tb_vanguard gets nothing
			-- here. And TB's on_stagger -- exactly like vanilla -- never fires on a
			-- killing blow (the game applies damage, then staggers only if the target
			-- survived), so there is no dropped killing-blow stagger to credit either.
			local sw_kill = second_wind_kill_amount(params)
			totals.second_wind = totals.second_wind + sw_kill
			register_gain("second_wind", sw_kill)

			local killed_unit = params[3]
			if mod._sw_pred then mod._sw_pred[killed_unit] = nil end
			mod._pending_stagger_unit = nil
		end
	end)

	-- TB Vanguard "killing stagger" support: predict the stagger the player's hit
	-- would apply so a unit killed by the same hit still credits Vanguard.
	mod:hook(DamageUtils, "server_apply_hit", function (func,
		t, attacker_unit, target_unit, hit_zone_name, hit_position, attack_direction,
		hit_ragdoll_actor, damage_source, power_level, damage_profile, target_index,
		boost_curve_multiplier, is_critical_strike, can_damage, can_stagger, blocking, ...)

		mod._pending_stagger_unit = nil
		mod._sw_now = t

		-- Set to the unit this melee hit staggers; the Bulwark window is opened on it
		-- AFTER func() (below), so the causing hit itself is not credited Bulwark.
		local stagger_mark_unit = nil

		if attacker_unit == local_player_unit() and damage_profile and not damage_profile.no_stagger then
			local stagger_power = can_stagger and power_level or 0
			-- Must pass the real per-armor impact table (ImpactTypeOutput), not an
			-- empty {}. do_stagger_calculation reads stagger_table[armor].min/.max;
			-- with {} that indexes nil and the pcall fails every hit, which is why
			-- Bulwark's window never opened and its total stayed at 0.
			local ok, stagger_type, _dur, _dist, stagger_value = pcall(
				DamageUtils.calculate_stagger_player, ImpactTypeOutput, target_unit, attacker_unit,
				hit_zone_name, stagger_power, boost_curve_multiplier, is_critical_strike,
				damage_profile, target_index, blocking, damage_source)

			local pred_amount = 0
			if ok and stagger_type and stagger_type > 0 then
				pred_amount = second_wind_stagger_amount({
					target_unit, damage_profile, nil, stagger_type, nil, stagger_value, nil, target_index,
				})
				mod._pending_stagger_amount = pred_amount
				mod._pending_stagger_unit = target_unit

				-- Remember to open the level-15 Bulwark window on this unit, but only
				-- AFTER func() applies the hit (below). The aura debuff is applied by the
				-- on_stagger proc, which fires after this hit's damage is computed, so the
				-- hit that CAUSES the stagger must NOT itself be credited Bulwark -- only
				-- later hits benefit. Marking here (pre-func) credited the causing hit too,
				-- badly inflating Bulwark on fast weapons that stagger-and-kill in one swing.
				-- Gated to melee attacks, matching the debuff's real trigger (MELEE_1H/2H).
				local cv = damage_profile.charge_value
				if cv == "light_attack" or cv == "heavy_attack" then
					stagger_mark_unit = target_unit
				end
			end

			dlog("SW-PRED t=%.2f ok=%s stype=%s sval=%s pred=%.2f", t, tostring(ok),
				tostring(stagger_type), tostring(stagger_value), pred_amount)

			-- Persist this hit's predicted stagger THP per unit so a deferred kill can
			-- credit TB with the killing blow's dropped stagger (see on_kill). Stored
			-- even when 0 so a later melee kill never reuses a stale earlier value.
			mod._sw_pred = mod._sw_pred or {}
			mod._sw_pred[target_unit] = { amount = pred_amount, t = t }
		end

		-- Open the level-15 ally-Bulwark window around the real hit application so
		-- its calculate_damage hook can credit an ally's melee hit (host only). We
		-- drive it from here because VMF ignores a second server_apply_hit hook from
		-- the same mod. No-op for local-player / non-melee / blocked hits.
		local l15_prev
		if mod._l15_open_ally_ctx then
			l15_prev = mod._l15_open_ally_ctx(attacker_unit, target_unit, damage_profile, blocking)
		end

		local res = func(t, attacker_unit, target_unit, hit_zone_name, hit_position, attack_direction,
			hit_ragdoll_actor, damage_source, power_level, damage_profile, target_index,
			boost_curve_multiplier, is_critical_strike, can_damage, can_stagger, blocking, ...)

		if mod._l15_close_ally_ctx then
			mod._l15_close_ally_ctx(l15_prev)
		end

		-- Now that this hit's damage is applied and credited, open the Bulwark window
		-- on the staggered unit so only SUBSEQUENT melee hits get the aura's bonus.
		if stagger_mark_unit and mod._on_player_stagger then
			mod._on_player_stagger(stagger_mark_unit, t)
		end

		mod._pending_stagger_unit = nil
		return res
	end)

	-- "Blocked" column: when the local player takes real damage, each talent's
	-- realistic (capped, decayed) THP pool absorbs it first. We credit the amount
	-- each pool would have soaked (min(damage, pool)) to that talent's running
	-- `blocked` total and drain the pool by it. Decay damage itself is skipped so
	-- it isn't double-counted against the pool it already drained.
	mod:hook_safe(PlayerUnitHealthExtension, "add_damage", function (self,
		attacker_unit, damage_amount, hit_zone_name, damage_type)
		if self.unit ~= local_player_unit() then return end
		if not damage_amount or damage_amount <= 0 then return end
		if damage_type == "temporary_health_degen" then return end

		dlog("DMG-TAKEN amt=%.2f type=%s | rpools sting=%.2f carve=%.2f exec=%.2f sw=%.2f",
			damage_amount, tostring(damage_type),
			decay.sting.rpool, decay.carve.rpool, decay.execute.rpool, decay.second_wind.rpool)

		for _, d in pairs(decay) do
			if d.rpool > 0 then
				local blk = math.min(damage_amount, d.rpool)
				d.rpool = d.rpool - blk
				d.blocked = d.blocked + blk
			end
		end
	end)

	-- Ground truth: every real heal the local player receives, with its source and
	-- type. The equipped level-5 talent's Live column deltas must line up with the
	-- proc heals here (times healing_received), which verifies that talent exactly.
	mod:hook_safe(PlayerUnitHealthExtension, "add_heal", function (self,
		healer_unit, heal_amount, heal_source, heal_type)
		if self.unit ~= local_player_unit() then return end
		if heal_type == "health_regen" then return end
		dlog("REAL-HEAL +%.2f src=%s type=%s",
			heal_amount or 0, tostring(heal_source), tostring(heal_type))
	end)
end

-- ---------------------------------------------------------------------------
-- Per-frame decay tick
-- ---------------------------------------------------------------------------
-- Advances the shared clock and drains each talent's realistic pool once its
-- 3 s delay has elapsed. Runs every frame regardless of panel visibility (like
-- the totals hooks) so the running "Blocked" totals stay correct even when hidden.
local next_pool_dbg = 0

function M.update(dt)
	local step = dt or 0
	decay_clock = decay_clock + step
	local now = decay_clock
	local wounded = local_player_is_wounded()
	local delay = wounded and DEGEN_DELAY_WOUNDED or DEGEN_DELAY_NORMAL

	-- Periodic pool snapshot (5 s cadence, only while any pool holds THP) so the
	-- decay rate / 3 s delay / cap clamp can be read off consecutive lines.
	if DBG and now >= next_pool_dbg then
		next_pool_dbg = now + 5
		if decay.sting.rpool > 0 or decay.carve.rpool > 0
			or decay.execute.rpool > 0 or decay.second_wind.rpool > 0 then
			dlog("POOLS t=%.1f cap=%.1f hmult=%.2f wounded=%s | rpool sting=%.2f carve=%.2f exec=%.2f sw=%.2f",
				now, current_cap, healing_mult, tostring(wounded),
				decay.sting.rpool, decay.carve.rpool, decay.execute.rpool, decay.second_wind.rpool)
		end
	end

	-- Refresh the free-health cap; if unreadable this frame, keep the last value.
	local cap = local_player_free_health()
	if cap then current_cap = cap end

	-- Refresh the Increased Healing multiplier used when banking THP into the
	-- realistic (Blocked) pool; keep the last value if unreadable this frame.
	local hmult = local_player_healing_mult()
	if hmult then healing_mult = hmult end

	-- "% time decaying" for Sting/Carve: shared cadence so both rows read the
	-- same number (see sting_carve_cadence above).
	if sting_carve_cadence.first_t then
		local grace_end = sting_carve_cadence.last_t + DEGEN_START
		local seg = now - math.max(now - step, grace_end)
		if seg > 0 then
			sting_carve_cadence.decaying_time = sting_carve_cadence.decaying_time + seg
		end
	end

	for key, d in pairs(decay) do
		-- "% time decaying": accumulate the portion of this frame's [now-step, now]
		-- slice that lies past the 3 s grace window since the last gain. Endless-
		-- supply assumption, so pool state is ignored here. Sting/Carve use the
		-- shared cadence above instead of their own.
		if key ~= "sting" and key ~= "carve" and d.first_t then
			local grace_end = d.last_t + DEGEN_START
			local seg = now - math.max(now - step, grace_end)
			if seg > 0 then
				d.decaying_time = d.decaying_time + seg
			end
		end

		-- Realistic pool can't exceed the current free-health cap (e.g. permanent
		-- health was healed up); trimmed THP is wasted, not blocked or decayed.
		if d.rpool > current_cap then d.rpool = current_cap end

		if d.rpool > 0 and now >= d.timer then
			-- Catch up any ticks owed since the last frame (guarded against a huge
			-- backlog, e.g. after a long pause/hitch).
			local guard = 0
			while now >= d.timer and d.rpool > 0 and guard < 256 do
				d.rpool = math.max(0, d.rpool - DEGEN_AMOUNT)
				d.timer = d.timer + delay
				guard = guard + 1
			end
			if guard >= 256 then
				d.timer = now + delay
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- Display
-- ---------------------------------------------------------------------------
local COL0        = 160  -- x of the first data column (relative to panel x)
local COL_STEP    = 90   -- spacing between data columns

function M.wants_display()
	return true
end

-- Fraction of time (0-100) this talent's pool would be actively decaying,
-- assuming an endless supply of THP -- i.e. time past the grace window over
-- total time since the talent's first gain.
local function decay_pct(d)
	if not d.first_t then return 0 end
	local elapsed = decay_clock - d.first_t
	if elapsed <= 0 then return 0 end
	return math.min(d.decaying_time / elapsed * 100, 100)
end

-- Full snapshot of every displayed value; called by reset_all just before the
-- totals are cleared (Reset button, keybind, and mission-entry reset).
function M.log_state()
	if not DBG then return end
	local totals = F.merge_sets(totals_cat)
	dlog("THP SNAP live: sting=%.2f carve=%.2f exec=%.2f sw=%.2f | tb: regrowth=%.2f reaper=%.2f bloodlust=%.2f vanguard=%.2f",
		totals.sting, totals.carve, totals.execute, totals.second_wind,
		totals.tb_regrowth, totals.tb_reaper, totals.tb_bloodlust, totals.tb_vanguard)
	local sc_pct = decay_pct(sting_carve_cadence)
	dlog("THP SNAP dec%%: sting/carve=%.0f exec=%.0f sw=%.0f | blocked: sting=%.2f carve=%.2f exec=%.2f sw=%.2f | cap=%.1f hmult=%.2f",
		sc_pct, decay_pct(decay.execute), decay_pct(decay.second_wind),
		decay.sting.blocked, decay.carve.blocked, decay.execute.blocked, decay.second_wind.blocked,
		current_cap, healing_mult)
end

-- Reset just this group (its panel's Reset button), snapshotting first.
function M.reset_self()
	if M.log_state then pcall(M.log_state) end
	M.reset()
end

local function fmt_val(v) return string.format("%.1f", v) end
local function fmt_pct(v) return string.format("%.0f%%", v) end

function M.draw(gui)
	local FONT_SIZE = ui.FONT_SIZE
	-- Merge the category totals the current filter selects (Live/TB columns filter;
	-- Decay/Dec %/Blocked stay aggregate).
	local totals = F.merge_sets(totals_cat)
	local tb_on = true
	local pct_on = true
	local blocked_on = true

	local sting_carve_pct = decay_pct(sting_carve_cadence)

	local rows = {
		{ label = "Sting:",       live = totals.sting,       tb = totals.tb_regrowth,  pct = sting_carve_pct,               blocked = decay.sting.blocked },
		{ label = "Carve:",       live = totals.carve,       tb = totals.tb_reaper,    pct = sting_carve_pct,               blocked = decay.carve.blocked },
		{ label = "Execute:",     live = totals.execute,     tb = totals.tb_bloodlust, pct = decay_pct(decay.execute),      blocked = decay.execute.blocked },
		{ label = "Second Wind:", live = totals.second_wind, tb = totals.tb_vanguard,  pct = decay_pct(decay.second_wind),  blocked = decay.second_wind.blocked },
	}
	local SECOND_WIND_ROW = 4  -- index in `rows`; its cross column is a stagger estimate

	-- Column order/labels depend on whether the TB mod is actually running:
	--  * TB loaded -> reality is TB, so show TB first and relabel the vanilla
	--    column "Official" (the hypothetical values WITHOUT the TB changes). Both
	--    columns always show in this case.
	--  * TB absent  -> "Live" is reality and comes first; the TB column (the
	--    hypothetical rebalance values) is opt-in via show_tb.
	local tb_active = tb_mod_active()
	local cols
	if tb_active then
		cols = {
			{ name = "TB",       key = "tb",   fmt = fmt_val },
			{ name = "Official", key = "live", fmt = fmt_val },
		}
	else
		cols = { { name = "Live", key = "live", fmt = fmt_val } }
		if tb_on then cols[#cols + 1] = { name = "TB", key = "tb", fmt = fmt_val } end
	end
	if pct_on then cols[#cols + 1] = { name = "Dec %", key = "pct", fmt = fmt_pct } end
	if blocked_on then cols[#cols + 1] = { name = "Blocked", key = "blocked", fmt = fmt_val } end

	-- Second Wind caveat (option 1): unlike Sting/Carve/Execute -- whose proc
	-- inputs (crit/headshot/target_index/damage/breed) are mod-independent -- the
	-- Second Wind / Vanguard THP is driven by the game's computed stagger_type /
	-- stagger_value, which come from the weapon's IMPACT power. TB's weapon_changes
	-- rebalances that impact, so the stagger numbers reaching `on_stagger` are the
	-- LOADED mod's, not the modeled mod's. That makes only the CROSS column (the
	-- mod you are NOT running) an estimate for the Second Wind row; the reality
	-- column stays exact. Mark that one value with a leading "~" and add a footnote.
	local sw_cross_key = nil
	if tb_active then
		sw_cross_key = "live"   -- Official = "what vanilla would give" (estimate)
	elseif tb_on then
		sw_cross_key = "tb"     -- TB = "what Tourney Balance would give" (estimate)
	end

	local content_rows = sw_cross_key and 6 or 5

	local panel_w = COL0 + (#cols - 1) * COL_STEP + 90

	local x, top, row_y, collapsed, title_visible = ui.frame(gui, panel_w, content_rows, "thp_pos_x", "thp_pos_y", 0.03, 0.60, "thp", M.reset_self)
	if not x then return end

	if title_visible then
		ui.text_bold(gui, "Temp Health:", x, row_y(0), FONT_SIZE, ui.yellow)
	end
	if collapsed then return end

	-- Column headers only when there's more than the single Live column.
	if #cols > 1 then
		local header_size = FONT_SIZE - 6
		for ci, c in ipairs(cols) do
			ui.text(gui, c.name, x + COL0 + (ci - 1) * COL_STEP, row_y(0), header_size, ui.grey)
		end
	end

	for i, r in ipairs(rows) do
		ui.text(gui, r.label, x, row_y(i), FONT_SIZE, ui.white)
		for ci, c in ipairs(cols) do
			local s = c.fmt(r[c.key])
			-- Flag the Second Wind cross column as an estimate (see sw_cross_key).
			if i == SECOND_WIND_ROW and sw_cross_key and c.key == sw_cross_key then
				s = "~" .. s
			end
			ui.text(gui, s, x + COL0 + (ci - 1) * COL_STEP, row_y(i), FONT_SIZE, ui.white)
		end
	end

	-- Footnote for the "~" marker: the cross-mod Second Wind value is only an
	-- estimate because TB reshapes stagger via weapon impact (see sw_cross_key).
	if sw_cross_key then
		ui.text(gui, "~ Second Wind: estimate (TB alters stagger)",
			x, row_y(#rows + 1), FONT_SIZE - 8, ui.grey)
	end
end

return M
