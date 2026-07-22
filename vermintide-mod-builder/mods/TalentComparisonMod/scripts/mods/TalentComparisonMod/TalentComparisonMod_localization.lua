return {
	mod_description = {
		en = "Compares talents you don't have equipped, as running totals for the current run. Temp Health panel: how much temp health each level-5 talent (Sting, Carve, Execute, Second Wind) would have generated (optional Tourney Balance column). Level 15 panel: for each talent (Smiter, Mainstay, Bulwark, Assassin, Enhanced Power) the extra damage it would add -- Total (all targets) and First (first unit hit). Enhanced Power also shows extra units cleaved; the optional Force Enhanced Power setting makes that extra cleave really happen so units hit and damage dealt can be measured. Totals reset on a new mission (or via the reset keybind).",
	},
	show_thp = {
		en = "Show Temp Health panel (level 5)",
	},
	show_thp_tooltip = {
		en = "Toggle the on-screen temp-health comparison panel for the level-5 talents.",
	},
	show_tb = {
		en = "Show Tourney Balance (TB) column",
	},
	show_tb_tooltip = {
		en = "Adds a second column to the Temp Health panel showing values under Tourney Balance rules (Regrowth/Reaper/Bloodlust/Vanguard).",
	},
	show_decay_pct = {
		en = "Show time decaying column",
	},
	show_decay_pct_tooltip = {
		en = "Adds a column showing the percentage of time each talent's temp health would be actively decaying, assuming an endless supply of THP. This measures only gain cadence: the fraction of time spent more than 3s past that talent's most recent gain (the decay grace window). Higher = gains are more spread out; lower = gains are frequent enough to keep re-arming the 3s delay. Measured from each talent's first gain.",
	},
	show_blocked = {
		en = "Show Blocked (real damage) column",
	},
	show_blocked_tooltip = {
		en = "Adds a column showing the real damage each talent's temp health would have blocked this run. Unlike Decayed, this pool is realistic: gains are capped so temp + current health never exceeds max health, the pool decays over time (stopping at empty), and when you take damage the pool absorbs it first -- the absorbed amount is added to the running total. Most accurate as host.",
	},
	show_level15 = {
		en = "Show Level 15 Talent panel",
	},
	show_level15_tooltip = {
		en = "Toggle the level-15 damage panel: per-talent Extra Damage Total (all targets) and First (first unit hit) as running damage totals. Enhanced Power's damage covers its +7.5% power level across melee, ranged and DoTs; Bulwark's Total is the extra damage from your +10% aura, self and allies combined, with a separate line showing the ally-only slice (ally tracking is host-only). Most accurate as host.",
	},
	force_ep = {
		en = "Force Extra Power cleave (measure real cleave)",
	},
	force_ep_tooltip = {
		en = "Gameplay-affecting (modded realm only): applies to EVERY panel that measures a power-level talent (Enhanced Power at level 15, Reikland Reaper at level 20). Forces your melee swings to cleave as if that talent were equipped, so the extra units hit and the damage dealt to them are measured exactly instead of estimated. The per-hit extra damage is always measured regardless; this only affects the extra-CLEAVE measurement. Leave off to just see the estimated extra-unit count.",
	},
	show_level10 = {
		en = "Show Level 10 Talents",
	},
	show_level10_tooltip = {
		en = "Master toggle for the level-10 talent panels. Each career's panel shows only while you are playing that career; use the sub-toggles below to enable/disable each one. Most accurate as host.",
	},
	show_level10_whc = {
		en = "Witch Hunter Captain (Riposte / Deathknell / Flense)",
	},
	show_level10_whc_tooltip = {
		en = "The level-10 Witch Hunter Captain damage panel: per-talent Extra Damage Total (all targets, overkill removed), First (first unit hit) and Uncapped (raw). Riposte = crit damage from the guaranteed crit after a perfectly-timed block (measured opportunistically when you time blocks). Deathknell = extra headshot bonus damage. Flense = the WHC bleed damage-over-time -- because it is a brand-new source it is FORCE-applied while this panel is on (gameplay-affecting, modded realm only) so its real ticks can be measured. Only appears in-game while playing WHC.",
	},
	show_level10_merc = {
		en = "Mercenary (More the Merrier / Limb Splitter / Helborg's Tutelage)",
	},
	show_level10_merc_tooltip = {
		en = "The level-10 Mercenary damage panel. More the Merrier = extra damage from its +5%% power per nearby enemy (up to 5 stacks), valued like Enhanced Power across all sources, plus extra cleave. Limb Splitter = the extra units its +50%% cleave power reaches and the damage dealt to them (measured when the Force cleave button is on, otherwise estimated). Helborg's Tutelage = the net crit damage of its every-5-attacks guaranteed crit minus the random crits it would suppress. Only appears in-game while playing Mercenary. Most accurate as host (More the Merrier reads nearby enemies server-side).",
	},
	show_level20 = {
		en = "Show Level 20 Talents",
	},
	show_level20_tooltip = {
		en = "Master toggle for the level-20 talent panels. Each career's panel shows only while you are playing that career; use the sub-toggles below. Most accurate as host.",
	},
	show_level20_merc = {
		en = "Mercenary (Reikland Reaper / Enhanced Training / Strike Together)",
	},
	show_level20_merc_tooltip = {
		en = "The level-20 Mercenary damage panel. Reikland Reaper = extra damage from its +15%% power while Paced Strikes is up (Total / First / Uncapped, same as the level-15 panel). Enhanced Training = the extra damage its faster attacks would add, simulated with 'ghost swings': your real melee swings are resampled at the higher attack speed and each extra swing is valued like a real one -- shown as an upper bound (assumes you keep swinging) plus an uptime comparison of base Paced Strikes (+10%% on 3 targets) vs Enhanced Training (+20%% on 4 targets). Only appears in-game while playing Mercenary.",
	},
	show_crit_tracker = {
		en = "Show Crit Rate panel",
	},
	show_crit_tracker_tooltip = {
		en = "Toggle a panel showing your critical-strike percentage this run, split Melee / Ranged, each with two rows: Hits (of attacks that connected with an enemy, % that crit) and Total (of every swing/shot attempted, whether or not it connected, % that crit -- the true crit-chance rate). DoT ticks are excluded (not attack rolls).",
	},
	show_ult_refund = {
		en = "Show Ult Cooldown Refund panel",
	},
	show_ult_refund_tooltip = {
		en = "Toggle the career-skill (ultimate) cooldown refund panels. Combat Ult Refund (all careers) shows how much of the full base cooldown was saved by combat -- the cooldown-on-hit and cooldown-on-damage-taken reduction -- for the last ult and as a running average. A second panel appears only on Mercenary with the Ready for Action talent, showing the TOTAL refund (the talent's instant 20% plus combat) as a percentage of the base cooldown. Measured by sampling your career-skill cooldown each frame.",
	},
	reset_keybind = {
		en = "Reset totals",
	},
	reset_keybind_tooltip = {
		en = "Reset all running totals (all panels) to zero.",
	},
	reset_on_restart = {
		en = "Reset On Restart",
	},
	reset_on_restart_tooltip = {
		en = "When on, all panels' running totals are cleared automatically on entering a non-hub mission. When off, totals survive a mission restart.",
	},
}
