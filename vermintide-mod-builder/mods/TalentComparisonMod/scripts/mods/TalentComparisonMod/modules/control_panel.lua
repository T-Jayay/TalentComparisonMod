-- control_panel.lua
-- ============================================================================
-- The MAIN control panel. Unlike the value panels it holds no stats -- it drives
-- two pieces of global UI state (shared via mod._filter / unit_filter.lua):
--   * Hide-all : one Hide/Show button (also a keybind, mod.toggle_hide) that hides
--                every OTHER panel. This panel is always drawn so it can be brought
--                back.
--   * Unit filter : four MULTI-SELECT toggle buttons -- Elites / Specials /
--                Monsters / Trash -- each an independent on/off switch. Every value
--                panel sums the enabled categories, so any combination shows at once
--                (e.g. Elites+Specials+Trash minus Monsters). At least one stays on.
--   * Gameplay status line : one line under the buttons stating whether the mod
--                is currently measure-only (green) or lists exactly which
--                gameplay modifications are LIVE right now (orange) -- read from
--                mod._gameplay.live_list() (modules/gameplay_control.lua).
--
-- It is added FIRST in the entry file's `groups` list and is the one group the
-- entry update loop still draws while mod._hide_all is set.
-- ============================================================================

local M = {}

local mod  -- set in init()
local ui   -- shared ui_panel
local F    -- unit_filter (mod._filter)

-- Filter toggle buttons, in display order: {category, label, width}. Each is an
-- independent on/off toggle (multi-select); there is no "All" button.
local FILTER_BTNS = {
	{ "elite",   "Elites",   72 },
	{ "special", "Specials", 84 },
	{ "mon",     "Monsters", 96 },
	{ "trash",   "Trash",    64 },
}

local PAD       = 10
local BTN_H     = 26
local HIDE_W    = 70
local GAP       = 8
local TITLE_GAP = 6

function M.reset()
	-- No per-run state to reset.
end

function M.log_state()
end

function M.wants_display()
	-- Always drawn while the mod is enabled (in-mission gating is done by the
	-- entry update loop). Ignores mod._hide_all on purpose.
	return true
end

-- Total panel width = title/hide row width vs the filter-button row width.
local function filter_row_width()
	local w = 0
	for i, b in ipairs(FILTER_BTNS) do
		w = w + b[3]
		if i < #FILTER_BTNS then w = w + GAP end
	end
	return w
end

-- ---------------------------------------------------------------------------
-- Tabs. mod._tabs (set by the entry file) is the ordered tab list:
-- { id, label, groups = {module, ...} }. A tab is available when any of its
-- modules currently wants_display() (career-gated tabs appear/disappear with
-- the career; settings-disabled panels drop their tab).
-- ---------------------------------------------------------------------------
local function tab_btn_w(label)
	return 22 + #label * 9
end

local function available_tabs()
	local avail = {}
	for _, t in ipairs(mod._tabs or {}) do
		local ok = false
		for _, g in ipairs(t.groups) do
			if g.wants_display() then ok = true break end
		end
		if ok then avail[#avail + 1] = t end
	end
	return avail
end

local function tab_row_width(tabs)
	local w = 0
	for i, t in ipairs(tabs) do
		w = w + tab_btn_w(t.label)
		if i < #tabs then w = w + GAP end
	end
	return w
end

function M.draw(gui)
	if not RESOLUTION_LOOKUP or not RESOLUTION_LOOKUP.res_w or not RESOLUTION_LOOKUP.res_h then
		return
	end

	local FONT_SIZE = ui.FONT_SIZE

	-- Gameplay status: nil-safe list of the modifications live right now.
	local live = (mod._gameplay and mod._gameplay.live_list()) or {}
	local show_status = mod:get("show_gameplay_status")
	if show_status == nil then show_status = true end

	-- Status lines: one line per modification (or a single "untouched" line).
	local status_lines, status_col
	if #live == 0 then
		status_lines = { "Gameplay: untouched (measure-only)" }
		status_col = Color(255, 120, 220, 120)
	else
		status_lines = { "Gameplay MODIFIED:" }
		for _, item in ipairs(live) do
			status_lines[#status_lines + 1] = "  " .. item
		end
		status_col = Color(255, 255, 170, 60)
	end

	-- Tabs available this frame (career-gated ones appear/disappear live). Each
	-- is an independent show/hide toggle (mod._tab_enabled, entry file).
	local tabs = available_tabs()

	local filt_w = filter_row_width()
	local tabs_w = tab_row_width(tabs)
	local panel_w = math.max(filt_w, tabs_w, 200) + PAD * 2
	-- Panel is 3 button rows tall (title/hide row, filter row, tab row) + status line(s).
	local row_h = BTN_H + TITLE_GAP
	local STATUS_LINE_H = FONT_SIZE - 7 + 4
	local status_h = show_status and (STATUS_LINE_H * #status_lines + TITLE_GAP) or (BTN_H + TITLE_GAP)

	local x = mod:get("ctl_pos_x")
	local top = mod:get("ctl_pos_y")   -- baseline y of the title row (like other panels' `top`)
	if not x or not top then
		x = RESOLUTION_LOOKUP.res_w * 0.03
		top = RESOLUTION_LOOKUP.res_h * 0.92
	end
	x = math.clamp(x, 0, RESOLUTION_LOOKUP.res_w - panel_w)
	top = math.clamp(top, row_h * 2 + BTN_H + status_h + PAD, RESOLUTION_LOOKUP.res_h - FONT_SIZE - PAD)

	local panel_top = top + FONT_SIZE + PAD
	local title_bottom = top - 4
	-- Filter row sits one row below the title; the tab row below that; the
	-- gameplay status line below the tabs.
	local filt_bottom = title_bottom - row_h
	local tabs_bottom = filt_bottom - row_h
	local status_y = tabs_bottom - status_h
	local panel_bottom = status_y - PAD
	local panel_h = panel_top - panel_bottom

	-- Background.
	ui.rect(gui, x - PAD, panel_bottom, panel_w, panel_h, Color(180, 20, 20, 30), 850)

	-- Title.
	ui.text_bold(gui, "Talent Comparison", x, top, FONT_SIZE, ui.yellow)

	local cursor_active = ui.cursor_active()
	local mx, my, down, pressed
	if cursor_active then
		mx, my = ui.get_mouse()
		down = ui.mouse_left_down()
		pressed = down and not mod._mouse_down_last
	end

	-- Hide/Show button, right-aligned on the title row.
	local hide_x = x - PAD + panel_w - HIDE_W - PAD
	local hidden = F.is_hidden()
	do
		local hover = cursor_active and ui.point_in_box(mx, my, hide_x, title_bottom, HIDE_W, BTN_H)
		ui.rect(gui, hide_x, title_bottom, HIDE_W, BTN_H,
			hover and Color(220, 70, 70, 90) or Color(200, 45, 45, 65), 860)
		ui.text(gui, hidden and "Show" or "Hide", hide_x + 10, title_bottom + 4, FONT_SIZE - 6, ui.white)
		if pressed and hover then
			F.toggle_hidden()
		end
	end

	-- Filter toggle buttons row (multi-select: each category on/off independently).
	local bx = x
	for _, b in ipairs(FILTER_BTNS) do
		local cat, label, bw = b[1], b[2], b[3]
		local active = F.enabled(cat)
		local hover = cursor_active and ui.point_in_box(mx, my, bx, filt_bottom, bw, BTN_H)
		local col
		if active then
			col = Color(230, 40, 90, 60)
		elseif hover then
			col = Color(210, 45, 55, 55)
		else
			col = Color(190, 30, 35, 40)
		end
		ui.rect(gui, bx, filt_bottom, bw, BTN_H, col, 860)
		ui.text(gui, label, bx + 8, filt_bottom + 4, FONT_SIZE - 7, active and ui.yellow or ui.white)
		if pressed and hover then
			F.toggle(cat)
		end
		bx = bx + bw + GAP
	end

	-- Tab row: one TOGGLE button per available tab. Clicking shows/hides that
	-- tab's free-floating panel(s); any number of tabs can be on at once.
	bx = x
	for _, t in ipairs(tabs) do
		local bw = tab_btn_w(t.label)
		local on = mod._tab_enabled(t.id)
		local hover = cursor_active and ui.point_in_box(mx, my, bx, tabs_bottom, bw, BTN_H)
		local col
		if on then
			col = Color(230, 90, 70, 30)
		elseif hover then
			col = Color(210, 60, 50, 35)
		else
			col = Color(190, 35, 32, 32)
		end
		ui.rect(gui, bx, tabs_bottom, bw, BTN_H, col, 860)
		ui.text(gui, t.label, bx + 8, tabs_bottom + 4, FONT_SIZE - 7, on and ui.yellow or ui.white)
		if pressed and hover then
			mod:set("show_tab_" .. t.id, not on)
		end
		bx = bx + bw + GAP
	end

	-- Top of the status block (first line's baseline), used for both the toggle
	-- and the first status line.
	local status_top = show_status and (status_y + STATUS_LINE_H * (#status_lines - 1)) or status_y

	-- Gameplay status toggle: a small checkbox at the top-right of the status
	-- area that turns the whole status section on/off.
	local TOGGLE_W = 14
	local toggle_x = x - PAD + panel_w - PAD - TOGGLE_W
	local toggle_y = status_top
	do
		local hover = cursor_active and ui.point_in_box(mx, my, toggle_x, toggle_y, TOGGLE_W, TOGGLE_W)
		ui.rect(gui, toggle_x, toggle_y, TOGGLE_W, TOGGLE_W,
			hover and Color(220, 90, 90, 100) or Color(190, 40, 40, 70), 870)
		if show_status then
			ui.text(gui, "x", toggle_x + 3, toggle_y - 1, FONT_SIZE - 8, ui.white)
		end
		if pressed and hover then
			mod:set("show_gameplay_status", not show_status)
		end
	end

	-- Gameplay status line(s): measure-only (green) or the live modifications (orange),
	-- one per line.
	if show_status then
		local ly = status_top
		for _, line in ipairs(status_lines) do
			ui.text(gui, line, x, ly, FONT_SIZE - 7, status_col)
			ly = ly - STATUS_LINE_H
		end
	end

	-- Dragging: grab anywhere on the title text area (left of the Hide button).
	if cursor_active then
		local drag_w = hide_x - (x - PAD) - GAP
		local hover_drag = ui.point_in_box(mx, my, x - PAD, title_bottom, drag_w, BTN_H)
		if pressed and hover_drag and not (mod._drag_key) then
			mod._drag_key = "ctl"
			mod._drag_dx = x - mx
			mod._drag_dy = top - my
		end
		if mod._drag_key == "ctl" then
			if down and mx then
				mod:set("ctl_pos_x", mx + mod._drag_dx)
				mod:set("ctl_pos_y", my + mod._drag_dy)
			else
				mod._drag_key = nil
			end
		end
	end
end

function M.init(owner_mod, ui_panel)
	mod = owner_mod
	ui = ui_panel
	F = mod._filter
end

return M
