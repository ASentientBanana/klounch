#!/usr/bin/env lua
-- gridlauncher - a small wofi-style app launcher with an icon grid for Hyprland.
--
-- Deps (Arch): sudo pacman -S lua-lgi gtk3 gtk-layer-shell
-- Keys: type to search | arrows/Tab move | Enter launch | Esc or click outside closes

local lgi = require 'lgi'
local Gtk = lgi.require('Gtk', '3.0')
local Gdk = lgi.require('Gdk', '3.0')
local Gio = lgi.Gio
local GLib = lgi.GLib
local LayerShell = lgi.require('GtkLayerShell', '0.1')

-- ---- tweak these -----------------------------------------------------------
local COLUMNS      = 6     -- icons per row
local ICON_SIZE    = 96    -- icon size in px
local ITEM_WIDTH   = 130   -- width of each grid cell
local VISIBLE_ROWS = 3.5   -- rows shown before scrolling
local SEARCH_FONT  = 22    -- search bar font size in px
-- ---------------------------------------------------------------------------

local CSS = string.format([[
window { background: transparent; }
#card {
    background: rgba(24, 24, 32, 0.92);
    border-radius: 22px;
    border: 2px solid rgba(255, 255, 255, 0.10);
    padding: 22px;
}
#search {
    font-size: %dpx;
    padding: 14px 18px;
    border-radius: 14px;
    background: rgba(255, 255, 255, 0.08);
    color: #f0f0f5;
    border: 2px solid transparent;
    box-shadow: none;
}
#search:focus { border-color: rgba(140, 170, 255, 0.85); }
flowboxchild {
    border-radius: 14px;
    padding: 12px 6px;
    background: transparent;
}
flowboxchild:selected {
    background: rgba(140, 170, 255, 0.25);
    outline: none;
}
flowboxchild:hover { background: rgba(255, 255, 255, 0.08); }
.app-name { color: #e8e8f0; font-size: 13px; }
scrolledwindow, viewport, flowbox { background: transparent; }
]], SEARCH_FONT)

-- GDK keysyms
local KEY = {
  Escape = 0xff1b, Return = 0xff0d, KP_Enter = 0xff8d, Tab = 0xff09,
  ISO_Left_Tab = 0xfe20, Left = 0xff51, Up = 0xff52, Right = 0xff53, Down = 0xff54,
}

-- ---- apps ------------------------------------------------------------------
local function app_text(app)
  local parts = { app:get_name() or '', app:get_display_name() or '' }
  pcall(function()
    parts[#parts + 1] = app:get_generic_name() or ''
    parts[#parts + 1] = app:get_string('Comment') or ''
    parts[#parts + 1] = table.concat(app:get_keywords() or {}, ' ')
    parts[#parts + 1] = app:get_string('Exec') or ''
  end)
  return table.concat(parts, ' '):lower()
end

local apps = {}      -- { app = AppInfo, name = string, text = string }
local children = {}  -- FlowBoxChild per app (same index as apps)
local mask = {}      -- mask[i] = true if apps[i] matches the query
local vis = {}       -- indices of visible apps, in display order
local sel = nil      -- selected app index

local function load_apps()
  local seen = {}
  for _, app in ipairs(Gio.AppInfo.get_all()) do
    if app:should_show() then
      local name = app:get_display_name() or app:get_name() or '?'
      local key = name .. '\0' .. (app:get_commandline() or '')
      if not seen[key] then
        seen[key] = true
        apps[#apps + 1] = { app = app, name = name, text = app_text(app) }
      end
    end
  end
  table.sort(apps, function(a, b) return a.name:lower() < b.name:lower() end)
end

-- ---- launching -------------------------------------------------------------
local function launch(entry)
  local ok, err = pcall(function()
    local ctx = Gdk.Display.get_default():get_app_launch_context()
    entry.app:launch({}, ctx)
  end)
  if not ok then io.stderr:write('launch failed: ' .. tostring(err) .. '\n') end
  Gtk.main_quit()
end

-- ---- UI --------------------------------------------------------------------
local win = Gtk.Window { title = 'gridlauncher', app_paintable = true }
local visual = win:get_screen():get_rgba_visual()
if visual then win:set_visual(visual) end

-- layer-shell: full-screen overlay so clicks outside the card can close it
LayerShell.init_for_window(win)
LayerShell.set_layer(win, LayerShell.Layer.OVERLAY)
LayerShell.set_namespace(win, 'gridlauncher')
LayerShell.set_keyboard_mode(win, LayerShell.KeyboardMode.EXCLUSIVE)
LayerShell.set_exclusive_zone(win, -1)
for _, edge in ipairs { 'TOP', 'BOTTOM', 'LEFT', 'RIGHT' } do
  LayerShell.set_anchor(win, LayerShell.Edge[edge], true)
end

local provider = Gtk.CssProvider()
provider:load_from_data(CSS)
Gtk.StyleContext.add_provider_for_screen(
  Gdk.Screen.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

-- backdrop: click anywhere outside the card to close
local backdrop = Gtk.EventBox { visible_window = false }
function backdrop:on_button_press_event()
  Gtk.main_quit()
  return true
end
win:add(backdrop)

-- card wrapper swallows clicks on the card's padding; it does the centering
local card_wrap = Gtk.EventBox { visible_window = false, halign = 'CENTER', valign = 'CENTER' }
function card_wrap:on_button_press_event() return true end
backdrop:add(card_wrap)

local card = Gtk.Box { orientation = 'VERTICAL', spacing = 18, name = 'card' }
card_wrap:add(card)

local entry = Gtk.SearchEntry { name = 'search', placeholder_text = 'Search applications...' }
card:pack_start(entry, false, false, 0)

local flow = Gtk.FlowBox {
  min_children_per_line = COLUMNS,
  max_children_per_line = COLUMNS,
  selection_mode = 'SINGLE',
  homogeneous = true,
  activate_on_single_click = true,
  row_spacing = 4,
  column_spacing = 4,
  can_focus = false,
  valign = 'START', -- don't stretch rows to fill the area
}
flow:set_filter_func(function(child)
  return mask[child:get_index() + 1] == true
end)

local scroll = Gtk.ScrolledWindow { hscrollbar_policy = 'NEVER', vscrollbar_policy = 'AUTOMATIC' }
-- hard minimum so the window keeps its size with zero or one result
-- (cell = item + 12px padding + 4px spacing)
scroll:set_size_request(COLUMNS * (ITEM_WIDTH + 16) + 20, math.floor(VISIBLE_ROWS * (ICON_SIZE + 62)))
scroll:add(flow)
card:pack_start(scroll, true, true, 0)

local function build_item(a)
  local box = Gtk.Box { orientation = 'VERTICAL', spacing = 8 }
  box:set_size_request(ITEM_WIDTH, -1)

  local icon = a.app:get_icon() or Gio.ThemedIcon.new('application-x-executable')
  local img = Gtk.Image.new_from_gicon(icon, Gtk.IconSize.DIALOG)
  img.pixel_size = ICON_SIZE
  box:pack_start(img, false, false, 0)

  local label = Gtk.Label { label = a.name, ellipsize = 'END', max_width_chars = 16, justify = 'CENTER' }
  label:get_style_context():add_class('app-name')
  box:pack_start(label, false, false, 0)

  local child = Gtk.FlowBoxChild {}
  child:add(box)
  return child
end

local function scroll_to(child)
  local a = child:get_allocation()
  local adj = scroll:get_vadjustment()
  if a.y < adj.value then
    adj.value = a.y
  elseif a.y + a.height > adj.value + adj.page_size then
    adj.value = a.y + a.height - adj.page_size
  end
end

local function refresh(query)
  local words = {}
  for w in query:lower():gmatch('%S+') do words[#words + 1] = w end

  mask, vis = {}, {}
  for i, a in ipairs(apps) do
    local ok = true
    for _, w in ipairs(words) do
      if not a.text:find(w, 1, true) then ok = false; break end
    end
    mask[i] = ok
    if ok then vis[#vis + 1] = i end
  end

  flow:invalidate_filter()
  scroll:get_vadjustment().value = 0
  if #vis > 0 then
    sel = vis[1]
    flow:select_child(children[sel])
  else
    sel = nil
    flow:unselect_all()
  end
end

local function move(delta)
  if #vis == 0 then return end
  local pos = 1
  for i, v in ipairs(vis) do
    if v == sel then pos = i; break end
  end
  pos = math.max(1, math.min(#vis, pos + delta))
  sel = vis[pos]
  flow:select_child(children[sel])
  GLib.idle_add(GLib.PRIORITY_DEFAULT, function()
    scroll_to(children[sel])
    return false
  end)
end

load_apps()
for i, a in ipairs(apps) do
  local child = build_item(a)
  flow:insert(child, -1)
  children[i] = child
end
refresh('')

function flow:on_child_activated(child)
  local a = apps[child:get_index() + 1]
  if a then launch(a) end
end

function entry:on_search_changed()
  refresh(self.text or '')
end

function win:on_key_press_event(ev)
  local k = ev.keyval
  if k == KEY.Escape then
    Gtk.main_quit()
  elseif k == KEY.Return or k == KEY.KP_Enter then
    if sel then launch(apps[sel]) end
  elseif k == KEY.Right or k == KEY.Tab then
    move(1)
  elseif k == KEY.Left or k == KEY.ISO_Left_Tab then
    move(-1)
  elseif k == KEY.Down then
    move(COLUMNS)
  elseif k == KEY.Up then
    move(-COLUMNS)
  else
    return false
  end
  return true
end

function win:on_destroy() Gtk.main_quit() end

win:show_all()
entry:grab_focus()
Gtk.main()
