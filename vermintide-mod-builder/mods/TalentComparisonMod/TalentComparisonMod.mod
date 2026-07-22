return {
	run = function()
		fassert(rawget(_G, "new_mod"), "`TalentComparisonMod` mod must be lower than Vermintide Mod Framework in your launcher's load order.")

		new_mod("TalentComparisonMod", {
			mod_script       = "scripts/mods/TalentComparisonMod/TalentComparisonMod",
			mod_data         = "scripts/mods/TalentComparisonMod/TalentComparisonMod_data",
			mod_localization = "scripts/mods/TalentComparisonMod/TalentComparisonMod_localization",
		})
	end,
	packages = {
		"resource_packages/TalentComparisonMod/TalentComparisonMod",
	},
}
