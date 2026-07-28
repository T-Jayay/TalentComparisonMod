local mod = get_mod("TalentComparisonMod")

return {
	name = "Talent Comparison Mod",
	description = mod:localize("mod_description"),
	is_togglable = true,
	options = {
		widgets = {
			-- Gameplay-affecting features. ONE master consent switch (default off:
			-- the mod is measure-only out of the box) with a sub-toggle per
			-- feature. Every forced/modifying code path gates on master AND sub
			-- (mod._gameplay_on in modules/gameplay_control.lua); the control
			-- panel lists whatever is live in-game.
			{
				setting_id = "allow_gameplay",
				type = "checkbox",
				title = "allow_gameplay",
				tooltip = "allow_gameplay_tooltip",
				default_value = false,
				sub_widgets = {
					{
						setting_id = "force_ep",
						type = "checkbox",
						title = "force_ep",
						tooltip = "force_ep_tooltip",
						default_value = true,
					},
					{
						setting_id = "force_flense",
						type = "checkbox",
						title = "force_flense",
						tooltip = "force_flense_tooltip",
						default_value = true,
					},
					{
						setting_id = "force_st_spread",
						type = "checkbox",
						title = "force_st_spread",
						tooltip = "force_st_spread_tooltip",
						default_value = true,
					},
					{
						setting_id = "unequip_l15",
						type = "checkbox",
						title = "unequip_l15",
						tooltip = "unequip_l15_tooltip",
						default_value = false,
					},
				},
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
			{
				setting_id = "hide_keybind",
				type = "keybind",
				title = "hide_keybind",
				tooltip = "hide_keybind_tooltip",
				default_value = {},
				keybind_trigger = "pressed",
				keybind_type = "function_call",
				function_name = "toggle_hide",
			},
		},
	},
}
