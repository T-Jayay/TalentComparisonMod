local mod = get_mod("TalentComparisonMod")

return {
	name = "Talent Comparison Mod",
	description = mod:localize("mod_description"),
	is_togglable = true,
	options = {
		widgets = {
			-- Temp Health group (level-5 talents) --------------------------------
			{
				setting_id = "show_thp",
				type = "checkbox",
				title = "show_thp",
				tooltip = "show_thp_tooltip",
				default_value = true,
				sub_widgets = {
					{
						setting_id = "show_tb",
						type = "checkbox",
						title = "show_tb",
						tooltip = "show_tb_tooltip",
						default_value = false,
					},
					{
						setting_id = "show_decay_pct",
						type = "checkbox",
						title = "show_decay_pct",
						tooltip = "show_decay_pct_tooltip",
						default_value = false,
					},
					{
						setting_id = "show_blocked",
						type = "checkbox",
						title = "show_blocked",
						tooltip = "show_blocked_tooltip",
						default_value = false,
					},
				},
			},
			-- Level-15 damage group ---------------------------------------------
			{
				setting_id = "show_level15",
				type = "checkbox",
				title = "show_level15",
				tooltip = "show_level15_tooltip",
				default_value = false,
			},
			-- Level-10 talent tier: a master category with one career-specific sub-
			-- toggle each (the panel for a career shows only while playing it).
			{
				setting_id = "show_level10",
				type = "checkbox",
				title = "show_level10",
				tooltip = "show_level10_tooltip",
				default_value = false,
				sub_widgets = {
					{
						setting_id = "show_level10_whc",
						type = "checkbox",
						title = "show_level10_whc",
						tooltip = "show_level10_whc_tooltip",
						default_value = true,
					},
					{
						setting_id = "show_level10_merc",
						type = "checkbox",
						title = "show_level10_merc",
						tooltip = "show_level10_merc_tooltip",
						default_value = true,
					},
				},
			},
			-- Level-20 talent tier: master category with career-specific sub-toggles.
			{
				setting_id = "show_level20",
				type = "checkbox",
				title = "show_level20",
				tooltip = "show_level20_tooltip",
				default_value = false,
				sub_widgets = {
					{
						setting_id = "show_level20_merc",
						type = "checkbox",
						title = "show_level20_merc",
						tooltip = "show_level20_merc_tooltip",
						default_value = true,
					},
				},
			},
			-- General power-boost cleave forcing (applies to every power-level
			-- talent panel: Enhanced Power L15, Reikland Reaper L20). Top-level,
			-- not nested, because it is shared across panels.
			{
				setting_id = "force_ep",
				type = "checkbox",
				title = "force_ep",
				tooltip = "force_ep_tooltip",
				default_value = false,
			},
			-- Crit rate tracker -----------------------------------------------------
			{
				setting_id = "show_crit_tracker",
				type = "checkbox",
				title = "show_crit_tracker",
				tooltip = "show_crit_tracker_tooltip",
				default_value = false,
			},
			-- Career-skill ult cooldown refund group ------------------------------
			{
				setting_id = "show_ult_refund",
				type = "checkbox",
				title = "show_ult_refund",
				tooltip = "show_ult_refund_tooltip",
				default_value = false,
			},
			-- Global --------------------------------------------------------------
			{
				setting_id = "reset_on_restart",
				type = "checkbox",
				title = "reset_on_restart",
				tooltip = "reset_on_restart_tooltip",
				default_value = true,
			},
			{
				setting_id = "reset_keybind",
				type = "keybind",
				title = "reset_keybind",
				tooltip = "reset_keybind_tooltip",
				default_value = {},
				keybind_trigger = "pressed",
				keybind_type = "function_call",
				function_name = "reset",
			},
		},
	},
}
