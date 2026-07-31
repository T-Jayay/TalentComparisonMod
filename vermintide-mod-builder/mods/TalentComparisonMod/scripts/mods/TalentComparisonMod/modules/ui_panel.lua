-- ui_panel.lua
-- ============================================================================
-- Shared on-screen panel framework used by every talent-comparison group.
-- Owns: GUI acquisition, text/rect drawing helpers, per-frame mouse-edge state,
-- and a reusable draggable panel with a Reset button.
--
-- Each talent-group module gets the resolved (x, top, row_y) from `frame(...)`
-- and draws its own rows. The Reset button calls the single `reset_all` callback
-- registered in init(), so one button clears every group at once.
-- ============================================================================

local ui = {}

-- Layout constants (shared so every panel lines up visually).
ui.FONT       = "arial"
ui.FONT_MTRL  = "materials/fonts/arial"
ui.FONT_SIZE  = 22
ui.LINE_HEIGHT = 26
ui.BTN_W, ui.BTN_H = 90, 26
ui.EXTRA_BTN_W = 150   -- per-panel button, e.g. the L15 details toggle
ui.HIDE_BTN_W = 70     -- built-in collapse/hide toggle button
ui.PAD = 10

local FONT       = ui.FONT
local FONT_MTRL  = ui.FONT_MTRL
local FONT_SIZE  = ui.FONT_SIZE
local LINE_HEIGHT = ui.LINE_HEIGHT
local BTN_W, BTN_H = ui.BTN_W, ui.BTN_H
local EXTRA_BTN_W = ui.EXTRA_BTN_W
local HIDE_BTN_W = ui.HIDE_BTN_W
local PAD = ui.PAD

local mod           -- set in init()
local reset_all_fn  -- set in init()

function ui.init(owner_mod, reset_all)
	mod = owner_mod
	reset_all_fn = reset_all
end

-- ---------------------------------------------------------------------------
-- GUI acquisition (cached per world; invalidated when the world changes).
-- ---------------------------------------------------------------------------
local WORLD_CANDIDATES = { "level_world", "top_ingame_view" }

function ui.get_gui()
	local wm = Managers.world
	if not wm then
		mod._gui = nil
		mod._gui_world = nil
		return nil
	end
	local world
	for _, name in ipairs(WORLD_CANDIDATES) do
		if wm:has_world(name) then
			world = wm:world(name)
			break
		end
	end
	if not world then
		mod._gui = nil
		mod._gui_world = nil
		return nil
	end
	if mod._gui and mod._gui_world == world then
		return mod._gui
	end
	mod._gui = World.create_screen_gui(world, "material", "materials/fonts/gw_fonts", "immediate")
	mod._gui_world = world
	return mod._gui
end

-- Invalidate the cached GUI so the next ui.get_gui() rebuilds it. Called when a
-- draw call throws (an incompatible mod, or a level teardown, can destroy the
-- screen GUI without the world object changing, leaving mod._gui a dead handle
-- that raises "Gui expected, got userdata").
function ui.invalidate_gui()
	mod._gui = nil
	mod._gui_world = nil
end

-- ---------------------------------------------------------------------------
-- Drawing helpers
-- ---------------------------------------------------------------------------
-- Every Gui.* call is individually guarded: if the handle has gone stale (an
-- incompatible mod or a level teardown can destroy the screen GUI without the
-- world object changing), the call raises "Gui expected, got userdata". Rather
-- than let one bad call abort the frame, we swallow it and invalidate the cache
-- so ui.get_gui() rebuilds a fresh handle next frame.
function ui.text(gui, str, x, y, size, color)
	if not pcall(Gui.text, gui, str, FONT_MTRL, size, FONT, Vector3(x, y, 900), color) then
		ui.invalidate_gui()
	end
end

function ui.text_bold(gui, str, x, y, size, color)
	ui.text(gui, str, x, y, size, color)
	ui.text(gui, str, x + 1, y, size, color)
end

-- Centers str horizontally around cx. There is no Gui.text_size in this API, so
-- width is estimated from an average per-character advance for the arial font;
-- good enough for short numeric/label columns to line up visually.
local AVG_CHAR_W = 0.5
function ui.text_centered(gui, str, cx, y, size, color)
	local w = #str * size * AVG_CHAR_W
	ui.text(gui, str, cx - w * 0.5, y, size, color)
end

function ui.rect(gui, x, y_bottom, w, h, color, z)
	if not pcall(Gui.rect, gui, Vector3(x, y_bottom, z or 850), Vector2(w, h), color) then
		ui.invalidate_gui()
	end
end

-- Common colors.
ui.white  = Color(255, 255, 255, 255)
ui.yellow = Color(255, 255, 220, 90)
ui.grey   = Color(255, 180, 180, 180)

-- ---------------------------------------------------------------------------
-- Mouse helpers + per-frame edge state
-- ---------------------------------------------------------------------------
local function point_in_box(px, py, bx, by, bw, bh)
	return px and px >= bx and px <= bx + bw and py >= by and py <= by + bh
end

local function get_mouse()
	local ok, cur = pcall(function () return Mouse.axis(Mouse.axis_index("cursor")) end)
	if not ok or not cur then return nil end
	return Vector3.x(cur), Vector3.y(cur)
end

local function mouse_left_down()
	local ok, val = pcall(function () return Mouse.button(Mouse.button_index("left")) == 1 end)
	return ok and val
end

-- Exposed for the control panel, which hit-tests its own buttons.
ui.point_in_box   = point_in_box
ui.get_mouse      = get_mouse
ui.mouse_left_down = mouse_left_down

-- The "pressed edge" (down this frame but not last), consistent across panels
-- because ui.end_frame latches mouse_down_last once after all panels draw.
function ui.pressed_edge()
	return mouse_left_down() and not mod._mouse_down_last
end

-- Called once per update, after all panels have drawn, so the "pressed edge"
-- (down this frame but not last) is consistent across panels.
function ui.end_frame(cursor_active)
	if cursor_active then
		mod._mouse_down_last = mouse_left_down()
	else
		mod._drag_key = nil
		mod._mouse_down_last = false
	end
end

function ui.cursor_active()
	return ShowCursorStack and ShowCursorStack.cursor_active()
end

-- ---------------------------------------------------------------------------
-- Draggable panel with Reset button.
--   content_rows : number of text rows below the title.
-- Returns (x, top, row_y) where row_y(i) is the baseline y of the i-th row.
-- ---------------------------------------------------------------------------
-- reset_fn (optional): called when this panel's Reset button is pressed; resets
-- only this group. Falls back to the global reset_all when not supplied.
-- opts (optional table):
--   extra_btn : { label = string, on_click = fn } drawn as a second button to
--               the right of Reset (e.g. the L15 details toggle).
-- Per-panel show/hide is now handled globally by the control panel's Hide button
-- (mod._hide_all), so ui.frame no longer draws its own Hide toggle. It draws the
-- background panel, handles dragging, and draws the Reset (+ optional extra) button.
function ui.frame(gui, panel_w, content_rows, pos_x_id, pos_y_id, default_x_frac, default_y_frac, drag_key, reset_fn, opts)
	-- Resolution not resolved yet (e.g. very early load): skip this frame.
	if not RESOLUTION_LOOKUP or not RESOLUTION_LOOKUP.res_w or not RESOLUTION_LOOKUP.res_h then
		return nil
	end

	opts = opts or {}

	local panel_bottom_drop = content_rows * LINE_HEIGHT + BTN_H + PAD
	local panel_top_rise = FONT_SIZE + PAD

	local x = mod:get(pos_x_id)
	local top = mod:get(pos_y_id)
	if not x or not top then
		x = RESOLUTION_LOOKUP.res_w * default_x_frac
		top = RESOLUTION_LOOKUP.res_h * default_y_frac
	end
	x = math.clamp(x, 0, RESOLUTION_LOOKUP.res_w - panel_w)
	top = math.clamp(top, panel_bottom_drop, RESOLUTION_LOOKUP.res_h - panel_top_rise)

	local function row_y(i)
		return top - i * LINE_HEIGHT
	end

	local btn_x = x
	local btn_bottom = row_y(content_rows) - BTN_H
	local panel_top = top + panel_top_rise

	local cursor_active = ui.cursor_active()

	-- Background panel (always drawn behind the rows).
	local panel_bottom = btn_bottom - PAD
	local panel_h = panel_top - panel_bottom
	ui.rect(gui, x - PAD, panel_bottom, panel_w, panel_h, Color(160, 20, 20, 20), 850)

	if cursor_active then
		local mx, my = get_mouse()
		local down = mouse_left_down()
		local pressed_edge = down and not mod._mouse_down_last

		-- Title row drags the panel.
		local title_row_bottom = top - FONT_SIZE - 4
		local hover_drag = point_in_box(mx, my, x - PAD, title_row_bottom, panel_w, panel_top - title_row_bottom)
		if pressed_edge and hover_drag then
			mod._drag_key = drag_key
			mod._drag_dx = x - mx
			mod._drag_dy = top - my
		end

		local hover_reset = point_in_box(mx, my, btn_x, btn_bottom, BTN_W, BTN_H)
		ui.rect(gui, btn_x, btn_bottom, BTN_W, BTN_H,
			hover_reset and Color(220, 90, 40, 40) or Color(200, 50, 25, 25), 860)
		ui.text(gui, "Reset", btn_x + 18, btn_bottom + 4, FONT_SIZE - 4, Color(255, 255, 255, 255))

		-- Optional second button (e.g. the L15 details toggle), to the right of Reset.
		local extra = opts.extra_btn
		local hover_extra = false
		if extra then
			local ex = btn_x + BTN_W + PAD * 2 + 6
			hover_extra = point_in_box(mx, my, ex, btn_bottom, EXTRA_BTN_W, BTN_H)
			ui.rect(gui, ex, btn_bottom, EXTRA_BTN_W, BTN_H,
				hover_extra and Color(220, 40, 70, 40) or Color(200, 25, 45, 25), 860)
			ui.text(gui, extra.label or "", ex + 10, btn_bottom + 4, FONT_SIZE - 4, Color(255, 255, 255, 255))
		end

		if pressed_edge and hover_reset then
			if reset_fn then reset_fn()
			elseif reset_all_fn then reset_all_fn() end
		elseif pressed_edge and hover_extra then
			if extra and extra.on_click then extra.on_click() end
		end

		if mod._drag_key == drag_key then
			if down and mx then
				mod:set(pos_x_id, mx + mod._drag_dx)
				mod:set(pos_y_id, my + mod._drag_dy)
			else
				mod._drag_key = nil
			end
		end
	end

	-- Returns kept 5-wide for backwards compatibility with existing callers that
	-- unpack (x, top, row_y, collapsed, title_visible): panels are never collapsed
	-- now (global hide skips drawing them entirely) and the title always shows.
	return x, top, row_y, false, true
end

return ui
