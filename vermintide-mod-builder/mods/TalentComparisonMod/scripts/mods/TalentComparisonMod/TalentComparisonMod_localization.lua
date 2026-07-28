return {
	mod_description = {
		en = "Compares talents you don't have equipped, as running totals for the current run. Temp Health panel: how much temp health each level-5 talent (Sting, Carve, Execute, Second Wind) would have generated (optional Tourney Balance column). Level 15 panel: for each talent (Smiter, Mainstay, Bulwark, Assassin, Enhanced Power) the extra damage it would add -- Total (all targets) and First (first unit hit). Enhanced Power also shows extra units cleaved; the optional Force Enhanced Power setting makes that extra cleave really happen so units hit and damage dealt can be measured. Totals reset on a new mission (or via the reset keybind).",
	},
	allow_gameplay = {
		en = "Allow the mod to AFFECT gameplay (accurate measurements)",
	},
	allow_gameplay_tooltip = {
		en = "Master consent switch for every feature that CHANGES your game instead of just watching it (modded realm only). OFF (default): the mod is strictly measure-only -- nothing is forced, granted or removed, and the affected values fall back to estimates or show as unavailable. ON: the sub-toggles below choose which modifications run, and the main control panel lists exactly what is currently modified in-game.",
	},
	force_ep = {
		en = "Force extra cleave (power-level talents)",
	},
	force_ep_tooltip = {
		en = "Gameplay-affecting: applies to EVERY panel that measures a power-level talent (Enhanced Power at level 15, Reikland Reaper at level 20, Limb Splitter / More the Merrier at Mercenary level 10). Forces your melee swings to cleave as if that talent were equipped, so the extra units hit and the damage dealt to them are measured exactly instead of estimated. The per-hit extra damage is always measured regardless; this only affects the extra-CLEAVE measurement. Off: you get an estimated extra-unit count marked (est).",
	},
	force_flense = {
		en = "Force Flense bleed (WHC level 10)",
	},
	force_flense_tooltip = {
		en = "Gameplay-affecting: while the WHC level-10 panel is on and Flense is not equipped, grants you the Flense bleed so its real damage-over-time ticks can be measured (a brand-new damage source cannot be simulated). Off: the Flense row reads (off) unless you actually equip the talent.",
	},
	force_st_spread = {
		en = "Force Strike Together ally spread (Merc level 20)",
	},
	force_st_spread_tooltip = {
		en = "Gameplay-affecting (host only, vanilla mode): while the Mercenary level-20 panel is on and Strike Together is not equipped, each of your 3+ target Paced Strikes procs also grants your allies the +10%% attack speed buff, exactly as the talent would, so the ally value can be measured. Off: the Strike Together row reads (off). Not used under Tourney Balance (there the value is estimated without touching gameplay).",
	},
	unequip_l15 = {
		en = "Unequip your level-15 talent row",
	},
	unequip_l15_tooltip = {
		en = "Gameplay-affecting: removes the buffs of whichever level-15 talent you have equipped (Smiter / Mainstay / Bulwark / Assassin / Enhanced Power), as if the whole row were empty. Every column of the level-15 panel then measures against a true no-talent baseline -- the cleanest comparison, at the cost of actually playing without your level-15 talent. Restored the moment you turn this (or the master switch) off. Default off.",
	},
	reset_keybind = {
		en = "Reset totals",
	},
	reset_keybind_tooltip = {
		en = "Reset all running totals (all panels) to zero.",
	},
	hide_keybind = {
		en = "Hide/Show panels",
	},
	hide_keybind_tooltip = {
		en = "Toggle hiding every panel except the main control panel (same as the control panel's Hide button).",
	},
	reset_on_restart = {
		en = "Reset On Restart",
	},
	reset_on_restart_tooltip = {
		en = "When on, all panels' running totals are cleared automatically on entering a non-hub mission. When off, totals survive a mission restart.",
	},
}
