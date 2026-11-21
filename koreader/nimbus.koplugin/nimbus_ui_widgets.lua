--[[--
nimbus_ui_widgets.lua
Shared Storefront/Libbee/Beeline UI primitives and mixin composer for Nimbus.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local ok_fm, FocusManager = pcall(require, "ui/widget/focusmanager")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputText = require("ui/widget/inputtext")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local ok_loc, Localization = pcall(require, "localization_nimbus")
local _ = (ok_loc and Localization and Localization.getHelper) and Localization:getHelper() or require("gettext")
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs or not lfs then
    ok_lfs, lfs = pcall(require, "lfs")
end

local theme = require("nimbus_theme")

local Widgets = {}
local sc = theme.sc
local _asset_path_cache = {}
local _active_toast = nil

--- Merges mixin functions into target table (matching xray.koplugin).
function Widgets.applyMixin(target, source)
    for k, v in pairs(source or {}) do
        target[k] = v
    end
    return target
end

function Widgets.isTouchDevice()
    if Device and type(Device.isTouchDevice) == "function" then
        return Device:isTouchDevice()
    elseif Device and Device.isTouchDevice ~= nil then
        return Device.isTouchDevice == true
    end
    return true
end

function Widgets.getAssetPath(filename)
    if _asset_path_cache[filename] then
        return _asset_path_cache[filename]
    end
    local info = debug.getinfo(1, "S")
    local dir = (info and info.source and info.source:match("^@(.*[/\\])")) or ""
    local candidates = {
        dir .. "assets/" .. filename,
        "plugins/nimbus.koplugin/assets/" .. filename,
    }
    for _, p in ipairs(candidates) do
        if lfs and lfs.attributes and lfs.attributes(p, "mode") == "file" then
            _asset_path_cache[filename] = p
            return p
        end
    end
    local fallback = dir .. "assets/" .. filename
    _asset_path_cache[filename] = fallback
    return fallback
end

local _focus_controllers = setmetatable({}, { __mode = "k" })

function Widgets.clearKeyboardFocus()
    for ctrl in pairs(_focus_controllers) do
        if ctrl._nimbus_focus_active then
            ctrl._nimbus_focus_active = false
            local sel = ctrl.selected
            local row = ctrl.layout and sel and ctrl.layout[sel.y]
            local w = row and row[sel.x]
            if w and w.onUnfocus then
                pcall(w.onUnfocus, w)
            end
        end
    end
end

function Widgets.installLazyFocus(ctrl)
    if not ctrl then return end
    _focus_controllers[ctrl] = true
    ctrl._nimbus_focus_active = false
    if ctrl.layout and ctrl.layout[1] and ctrl.layout[1][1] and ctrl.layout[1][1].onUnfocus then
        pcall(ctrl.layout[1][1].onUnfocus, ctrl.layout[1][1])
    end

    local function activateCurrent()
        ctrl._nimbus_focus_active = true
        if not ctrl.layout or #ctrl.layout == 0 then return false end
        local sel = ctrl.selected or { x = 1, y = 1 }
        local y = math.max(1, math.min(sel.y or 1, #ctrl.layout))
        local row = ctrl.layout[y]
        if not row or #row == 0 then return false end
        local x = math.max(1, math.min(sel.x or 1, #row))
        ctrl.selected = { x = x, y = y }
        local w = row[x]
        if w and w.onFocus then
            pcall(w.onFocus, w)
        end
        return true
    end

    for _, method_name in ipairs({ "onFocusMove", "onFocusHalfMove", "onFocusNext", "onFocusPrevious" }) do
        local orig = ctrl[method_name]
        if type(orig) == "function" then
            ctrl[method_name] = function(self, ...)
                if not self._nimbus_focus_active then
                    return activateCurrent()
                end
                return orig(self, ...)
            end
        end
    end

    for _, action_name in ipairs({ "onPress", "onHold" }) do
        local orig = ctrl[action_name]
        if type(orig) == "function" then
            ctrl[action_name] = function(self, ...)
                if not self._nimbus_focus_active then
                    return false
                end
                return orig(self, ...)
            end
        end
    end
end

function Widgets.makeTapItem(widget, callback, hold_callback, opts)
    opts = opts or {}
    local focus_frame = (widget and widget.bordersize ~= nil) and widget or FrameContainer:new{
        padding = 0,
        margin = 0,
        bordersize = 0,
        color = Blitbuffer.COLOR_BLACK,
        widget,
    }
    local orig_border = focus_frame.bordersize or 0
    local orig_color = focus_frame.color
    local item = InputContainer:new{ focus_frame }
    local sz = focus_frame:getSize()
    item.dimen = sz
    local function getRange()
        local d = item.dimen
        if not d then return Geom:new{ x = -1, y = -1, w = 1, h = 1 } end
        return Geom:new{ x = d.x or 0, y = d.y or 0, w = d.w or sz.w, h = d.h or sz.h }
    end
    item.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = getRange } },
    }
    item.onTap = function()
        Widgets.clearKeyboardFocus()
        if callback then callback() end
        return true
    end
    if hold_callback then
        item.ges_events.Hold = { GestureRange:new{ ges = "hold", range = getRange } }
        item.onHold = function()
            Widgets.clearKeyboardFocus()
            hold_callback()
            return true
        end
    end
    if opts.focusable ~= false then
        item.isFocusable = function() return true end
        item.onFocus = function()
            focus_frame.bordersize = math.max(orig_border, theme.border_focus or sc(3))
            focus_frame.color = Blitbuffer.COLOR_BLACK
            UIManager:setDirty(nil, "ui")
            return true
        end
        item.onUnfocus = function()
            focus_frame.bordersize = orig_border
            focus_frame.color = orig_color
            UIManager:setDirty(nil, "ui")
            return true
        end
        item.onTapSelect = function()
            if callback then callback() end
            return true
        end
        item.onHoldSelect = function()
            if hold_callback then
                hold_callback()
                return true
            end
            return false
        end
    end
    return item
end

function Widgets.collectFocusableLayout(root)
    local rows = {}
    local function collectRow(node, out_row)
        if type(node) ~= "table" then return end
        if node.isFocusable and node:isFocusable() then
            table.insert(out_row, node)
            return
        end
        for _, child in ipairs(node) do
            collectRow(child, out_row)
        end
    end
    local function walk(node)
        if type(node) ~= "table" then return end
        if node.isFocusable and node:isFocusable() then
            table.insert(rows, { node })
            return
        end
        if HorizontalGroup and node.is_a and node:is_a(HorizontalGroup) then
            local row = {}
            collectRow(node, row)
            if #row > 0 then table.insert(rows, row) end
            return
        end
        for _, child in ipairs(node) do
            walk(child)
        end
    end
    walk(root)
    return rows
end

function Widgets.createIconButton(opts)
    local size = opts.size or sc(26)
    local pad = opts.padding or sc(4)
    local pad_h = opts.padding_h or pad
    local icon = ImageWidget:new{
        file = Widgets.getAssetPath(opts.icon),
        width = size,
        height = size,
        scale_factor = 0,
        is_icon = true,
        alpha = true,
    }
    local frame = FrameContainer:new{
        padding = pad,
        padding_left = pad_h,
        padding_right = pad_h,
        bordersize = opts.is_focused and (theme.border_focus or sc(2)) or (opts.bordersize or 0),
        color = Blitbuffer.COLOR_BLACK,
        background = opts.is_focused and (theme.color_focus_bg or Blitbuffer.COLOR_LIGHT_GRAY) or opts.background,
        radius = (opts.is_focused and (theme.radius_focus or sc(4))) or opts.radius or 0,
        icon,
    }
    return Widgets.makeTapItem(frame, opts.callback)
end

--- Creates a Storefront/Libbee-styled primary (black) or secondary (bordered white) button.
function Widgets.createButton(opts)
    local is_primary = opts.is_primary == true
    local border_w = opts.bordersize or sc(1)
    local pad_v = opts.padding or sc(7)
    local pad_h = opts.padding_h or sc(10)
    local font_sz = opts.text_font_size or (theme.isSimpleUIActive and theme.isSimpleUIActive() and theme.fs("body") or 15)
    local is_bold = (opts.bold ~= nil) and opts.bold or is_primary

    local max_tw = opts.width and math.max(sc(40), opts.width - (pad_h * 2) - (border_w * 2)) or nil
    local label = TextWidget:new{
        text = opts.text or "",
        face = Font:getFace("cfont", font_sz),
        bold = is_bold,
        fgcolor = is_primary and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
        max_width = max_tw,
    }
    local lbl_sz = label:getSize()
    local content = opts.width and CenterContainer:new{
        dimen = Geom:new{ w = opts.width - (pad_h * 2) - (border_w * 2), h = lbl_sz.h },
        label,
    } or label

    local frame = FrameContainer:new{
        padding_top = pad_v,
        padding_bottom = pad_v,
        padding_left = pad_h,
        padding_right = pad_h,
        bordersize = border_w,
        color = Blitbuffer.COLOR_BLACK,
        background = is_primary and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
        radius = opts.radius or theme.radius_btn or sc(4),
        content,
    }
    return Widgets.makeTapItem(frame, opts.callback)
end

function Widgets.createBadge(text, is_highlighted, opts)
    if not text or text == "" then return nil end
    local is_compact = opts and opts.compact
    local is_sui = theme.isSimpleUIActive and theme.isSimpleUIActive()
    local badge_fs = is_compact and (theme.fs and theme.fs("caption") or 12) or (is_sui and (theme.fs("detail") - 1) or (theme.fs and theme.fs("caption") or 12))
    local pad_v = is_compact and sc(1) or sc(2)
    local pad_h = is_compact and sc(5) or (is_sui and sc(7) or sc(6))
    local label = TextWidget:new{
        text = text,
        face = Font:getFace("cfont", badge_fs),
        bold = is_highlighted,
        fgcolor = is_highlighted and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
    }
    return FrameContainer:new{
        padding = pad_v,
        padding_left = pad_h,
        padding_right = pad_h,
        bordersize = sc(1),
        color = Blitbuffer.COLOR_BLACK,
        radius = theme.radius_badge or sc(10),
        background = is_highlighted and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
        label,
    }
end

function Widgets.createIconBadge(icon_name, is_highlighted, opts)
    if not icon_name or icon_name == "" then return nil end
    local badge_fs = theme.fs and theme.fs("caption") or 12
    local probe = TextWidget:new{
        text = "0%",
        face = Font:getFace("cfont", badge_fs),
    }
    local inner_h = probe:getSize().h
    probe:free()
    local sz = (opts and opts.size) or math.max(sc(12), inner_h - sc(2))
    local icon = ImageWidget:new{
        file = Widgets.getAssetPath(icon_name),
        width = sz,
        height = sz,
        scale_factor = 0,
        is_icon = true,
        alpha = true,
        invert = is_highlighted and true or nil,
    }
    return FrameContainer:new{
        padding = sc(1),
        padding_left = sc(5),
        padding_right = sc(5),
        bordersize = sc(1),
        color = Blitbuffer.COLOR_BLACK,
        radius = theme.radius_badge or sc(10),
        background = is_highlighted and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = sz, h = inner_h },
            icon,
        },
    }
end

function Widgets.createCornerTag(text)
    if not text or text == "" then return nil end
    local tag_fs = theme.fs and theme.fs("caption") or 12
    local label = TextWidget:new{
        text = text,
        face = Font:getFace("cfont", tag_fs),
        bold = true,
        fgcolor = Blitbuffer.COLOR_WHITE,
    }
    return FrameContainer:new{
        padding_top = sc(2),
        padding_bottom = sc(3),
        padding_left = sc(6),
        padding_right = sc(6),
        bordersize = 0,
        background = Blitbuffer.COLOR_BLACK,
        label,
    }
end

function Widgets.createCircleBadge(opts)
    opts = opts or {}
    local is_sui = theme.isSimpleUIActive and theme.isSimpleUIActive()
    local d = sc(is_sui and 26 or 24)
    if opts.icon then
        local svg_file = (opts.icon == "check-white.svg" or opts.icon == "check.svg")
            and "check-circle-filled.svg" or opts.icon
        return ImageWidget:new{
            file = Widgets.getAssetPath(svg_file),
            width = d,
            height = d,
            scale_factor = 0,
            alpha = true,
        }
    end
    local bg = ImageWidget:new{
        file = Widgets.getAssetPath("circle-filled.svg"),
        width = d,
        height = d,
        scale_factor = 0,
        alpha = true,
    }
    local label = TextWidget:new{
        text = tostring(opts.text or ""),
        face = Font:getFace("cfont", theme.fs and theme.fs("caption") or 12),
        bold = true,
        fgcolor = Blitbuffer.COLOR_WHITE,
    }
    return OverlapGroup:new{
        dimen = Geom:new{ w = d, h = d },
        bg,
        CenterContainer:new{
            dimen = Geom:new{ w = d, h = d },
            label,
        },
    }
end

function Widgets.createFilterChip(label_text, on_clear)
    local lbl = TextWidget:new{
        text = label_text .. "  ✕",
        face = Font:getFace("cfont", 13),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local pill = FrameContainer:new{
        padding = sc(3),
        padding_left = sc(8),
        padding_right = sc(8),
        bordersize = sc(1),
        color = Blitbuffer.COLOR_BLACK,
        radius = theme.radius_badge or sc(10),
        background = theme.color_focus_bg or Blitbuffer.COLOR_LIGHT_GRAY,
        lbl,
    }
    return Widgets.makeTapItem(pill, on_clear)
end

function Widgets.createSectionHeader(title, inner_w)
    local label = TextWidget:new{
        text = tostring(title or ""):upper(),
        face = Font:getFace("cfont", 13),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    return FrameContainer:new{
        padding = sc(4),
        padding_left = sc(8),
        radius = theme.radius_btn or sc(4),
        bordersize = 0,
        width = inner_w,
        background = Blitbuffer.COLOR_LIGHT_GRAY,
        label,
    }
end

function Widgets.createSettingRow(left_text, right_widget, inner_w, callback, pad_v, pad_h)
    pad_v = pad_v or sc(6)
    pad_h = pad_h or pad_v
    local avail_w = inner_w - (pad_h * 2)
    local right_w = right_widget and ((right_widget.getSize and right_widget:getSize().w) or sc(60)) or 0
    local max_left_w = math.max(sc(60), avail_w - right_w - sc(8))

    local left_w = TextWidget:new{
        text = left_text,
        face = Font:getFace("cfont", 16),
        fgcolor = Blitbuffer.COLOR_BLACK,
        max_width = max_left_w,
    }
    local spacer_w = math.max(sc(8), avail_w - left_w:getSize().w - right_w)
    local elems = { left_w, HorizontalSpan:new{ width = spacer_w } }
    if right_widget then table.insert(elems, right_widget) end

    local frame = FrameContainer:new{
        bordersize = 0,
        padding_top = pad_v,
        padding_bottom = pad_v,
        padding_left = pad_h,
        padding_right = pad_h,
        width = inner_w,
        HorizontalGroup:new(elems),
    }
    if not callback then return frame end
    return Widgets.makeTapItem(frame, callback)
end

function Widgets.createMenuRow(left_text, right_widget, inner_w, callback)
    return Widgets.createSettingRow(left_text, right_widget, inner_w, callback, sc(7), sc(10))
end

function Widgets.createMenuList(rows, inner_w)
    local border = sc(1)
    local list_inner_w = inner_w - (border * 2)
    local vg = VerticalGroup:new{ align = "left" }
    for idx, r in ipairs(rows or {}) do
        if idx > 1 then
            table.insert(vg, LineWidget:new{
                dimen = Geom:new{ w = list_inner_w, h = sc(1) },
                background = Blitbuffer.COLOR_LIGHT_GRAY,
            })
        end
        table.insert(vg, r)
    end
    return FrameContainer:new{
        padding = 0,
        bordersize = border,
        color = Blitbuffer.COLOR_BLACK,
        radius = theme.radius_btn or sc(4),
        background = Blitbuffer.COLOR_WHITE,
        width = inner_w,
        vg,
    }
end

local function createChoiceRow(icon_file, label, subtitle, is_active, inner_w, callback)
    local icon = ImageWidget:new{
        file = Widgets.getAssetPath(icon_file),
        width = sc(20),
        height = sc(20),
        scale_factor = 0,
        is_icon = true,
        alpha = true,
    }
    local max_text_w = math.max(sc(80), inner_w - sc(38))
    local text_items = {
        TextWidget:new{
            text = label or "",
            face = Font:getFace("cfont", 15),
            bold = is_active,
            fgcolor = Blitbuffer.COLOR_BLACK,
            max_width = max_text_w,
        },
    }
    if subtitle and subtitle ~= "" then
        table.insert(text_items, TextWidget:new{
            text = subtitle,
            face = Font:getFace("cfont", 12),
            fgcolor = theme.color_label_dim,
            max_width = max_text_w,
        })
    end
    local text_vg = VerticalGroup:new{ align = "left", unpack(text_items) }
    local row = HorizontalGroup:new{
        align = "center",
        icon,
        HorizontalSpan:new{ width = sc(10) },
        text_vg,
    }
    local frame = FrameContainer:new{
        padding = sc(5),
        bordersize = 0,
        width = inner_w,
        background = Blitbuffer.COLOR_WHITE,
        row,
    }
    return Widgets.makeTapItem(frame, callback)
end

function Widgets.createCheckboxRow(label, subtitle, is_checked, inner_w, callback)
    return createChoiceRow(is_checked and "check-square.svg" or "square.svg", label, subtitle, is_checked, inner_w, callback)
end

function Widgets.createRadioRow(label, subtitle, is_selected, inner_w, callback)
    return createChoiceRow(is_selected and "radio-active.svg" or "radio.svg", label, subtitle, is_selected, inner_w, callback)
end

--- Kindle-style two-tab bar (`On Device (N)` | `Cloud (M)`).
function Widgets.createTwoTabBar(tabs, active_id, total_w, on_select)
    local tab_w = math.floor(total_w / #tabs)
    local tab_fs = theme.isSimpleUIActive and theme.isSimpleUIActive() and theme.fs("body") or 15
    local tab_items = {}
    for _, tab in ipairs(tabs) do
        local is_active = (tab.id == active_id)
        local label = TextWidget:new{
            text = tab.label,
            face = Font:getFace("cfont", tab_fs),
            bold = is_active,
            fgcolor = is_active and Blitbuffer.COLOR_BLACK or theme.color_label_dim,
        }
        local tab_h = math.max(sc(34), label:getSize().h + sc(12))
        local indicator = LineWidget:new{
            dimen = Geom:new{ w = tab_w, h = is_active and sc(3) or sc(1) },
            background = is_active and Blitbuffer.COLOR_BLACK or theme.color_bg_dim,
        }
        local cell = VerticalGroup:new{
            align = "center",
            CenterContainer:new{
                dimen = Geom:new{ w = tab_w, h = tab_h },
                label,
            },
            indicator,
        }
        local tap_cell = Widgets.makeTapItem(cell, function()
            if on_select then on_select(tab.id) end
        end)
        table.insert(tab_items, tap_cell)
    end
    return FrameContainer:new{
        padding = 0,
        bordersize = 0,
        width = total_w,
        background = Blitbuffer.COLOR_WHITE,
        HorizontalGroup:new(tab_items),
    }
end

--- Closes any active toast immediately so it never lingers beneath modals or progress dialogs.
function Widgets.closeToast()
    if _active_toast then
        local t = _active_toast
        _active_toast = nil
        if t._timer then
            UIManager:unschedule(t._timer)
            t._timer = nil
        end
        UIManager:close(t, "ui")
    end
end

--- Styled Storefront/Libbee card toast replacing KOReader's unstyled InfoMessage.
function Widgets.showToast(text, timeout)
    Widgets.closeToast()
    local sw = Device.screen:getWidth()
    local sh = Device.screen:getHeight()
    local max_w = math.min(sw - sc(32), sc(420))

    local icon = ImageWidget:new{
        file = Widgets.getAssetPath("info.svg"),
        width = sc(22),
        height = sc(22),
        scale_factor = 0,
        is_icon = true,
        alpha = true,
    }
    local label = TextBoxWidget:new{
        text = tostring(text or ""),
        face = Font:getFace("cfont", 16),
        fgcolor = Blitbuffer.COLOR_BLACK,
        width = max_w - sc(64),
        alignment = "center",
    }
    local card = FrameContainer:new{
        padding = sc(14),
        padding_left = sc(16),
        padding_right = sc(16),
        radius = theme.radius_window or sc(4),
        bordersize = theme.border_window or sc(2),
        color = Blitbuffer.COLOR_BLACK,
        background = Blitbuffer.COLOR_WHITE,
        HorizontalGroup:new{
            align = "center",
            icon,
            HorizontalSpan:new{ width = sc(10) },
            label,
        },
    }

    local toast
    toast = InputContainer:new{
        dimen = Geom:new{ w = sw, h = sh },
        key_events = { Close = { { "Back" }, { "Escape" } } },
        ges_events = {
            TapDismiss = {
                GestureRange:new{
                    ges = "tap",
                    range = Geom:new{ x = 0, y = 0, w = sw, h = sh },
                },
            },
        },
        CenterContainer:new{
            dimen = Geom:new{ w = sw, h = sh },
            card,
        },
    }
    toast.onTapDismiss = function()
        Widgets.closeToast()
        return true
    end
    toast.onClose = function()
        Widgets.closeToast()
        return true
    end
    local dur = tonumber(timeout) or 2.5
    if dur > 0 then
        toast._timer = UIManager:scheduleIn(dur, function()
            if _active_toast == toast then
                Widgets.closeToast()
            end
        end)
    end
    _active_toast = toast
    UIManager:show(toast, "ui")
    return toast
end

--- Generic Storefront/Libbee-styled modal card dialog.
function Widgets.showCardDialog(opts)
    Widgets.closeToast()
    local sw = Device.screen:getWidth()
    local sh = Device.screen:getHeight()
    local dialog_w = opts.width or math.min(sw - sc(24), sc(420))
    local pad = sc(14)
    local border = theme.border_window or sc(2)
    local inner_w = dialog_w - (pad * 2) - (border * 2)

    local overlay
    local function closeDlg()
        if overlay then
            local ov = overlay
            overlay = nil
            if opts.on_before_close then
                pcall(opts.on_before_close)
            end
            UIManager:close(ov, "ui")
        end
    end

    local close_icon = Widgets.createIconButton{
        icon = "x.svg",
        size = theme.icon and theme.icon(22) or sc(22),
        padding = sc(6),
        callback = function()
            closeDlg()
            if opts.on_close then opts.on_close() end
        end,
    }
    local title_w = TextWidget:new{
        text = opts.title or "Nimbus",
        face = Font:getFace(theme.getTitleFontName and theme.getTitleFontName() or "tfont", theme.fs and theme.fs("title") or 20),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
        max_width = inner_w - sc(36),
    }
    local header_row = HorizontalGroup:new{
        title_w,
        HorizontalSpan:new{ width = math.max(sc(8), inner_w - title_w:getSize().w - close_icon:getSize().w) },
        close_icon,
    }

    local content_items = {
        align = "left",
        header_row,
        VerticalSpan:new{ width = sc(8) },
        LineWidget:new{
            dimen = Geom:new{ w = inner_w, h = sc(1) },
            background = Blitbuffer.COLOR_BLACK,
        },
        VerticalSpan:new{ width = sc(10) },
    }

    if opts.body_widget then
        table.insert(content_items, opts.body_widget(inner_w, closeDlg))
    elseif opts.body_text then
        table.insert(content_items, TextBoxWidget:new{
            text = opts.body_text,
            face = Font:getFace("cfont", 16),
            fgcolor = Blitbuffer.COLOR_BLACK,
            width = inner_w,
        })
    end

    if opts.buttons and #opts.buttons > 0 then
        table.insert(content_items, VerticalSpan:new{ width = sc(12) })
        local btn_gap = sc(8)
        local n = #opts.buttons
        local avail_btn_w = inner_w - btn_gap * (n - 1)
        local nat_widths = {}
        local sum_nat = 0
        for i, b in ipairs(opts.buttons) do
            local tw = TextWidget:new{
                text = b.text or "",
                face = Font:getFace("cfont", 15),
                bold = (b.is_primary == true),
            }
            local w = tw:getSize().w + sc(20)
            nat_widths[i] = w
            sum_nat = sum_nat + w
        end

        local btn_widths = {}
        if sum_nat <= avail_btn_w then
            local extra = math.floor((avail_btn_w - sum_nat) / n)
            local rem = avail_btn_w - sum_nat - (extra * n)
            for i = 1, n do
                btn_widths[i] = nat_widths[i] + extra + (i == 1 and rem or 0)
            end
        else
            local equal_w = math.floor(avail_btn_w / n)
            for i = 1, n do btn_widths[i] = equal_w end
        end

        local btn_row = {}
        for i, b in ipairs(opts.buttons) do
            if i > 1 then table.insert(btn_row, HorizontalSpan:new{ width = btn_gap }) end
            table.insert(btn_row, Widgets.createButton{
                text = b.text,
                is_primary = b.is_primary,
                padding_h = sc(8),
                width = btn_widths[i],
                callback = function()
                    if not b.keep_open then closeDlg() end
                    if b.callback then b.callback(closeDlg) end
                end,
            })
        end
        table.insert(content_items, HorizontalGroup:new(btn_row))
    end

    local card = FrameContainer:new{
        padding = pad,
        radius = theme.radius_window or sc(4),
        bordersize = border,
        color = Blitbuffer.COLOR_BLACK,
        background = Blitbuffer.COLOR_WHITE,
        width = dialog_w,
        VerticalGroup:new(content_items),
    }

    local container_widget = CenterContainer:new{
        dimen = Geom:new{ w = sw, h = opts.container_h or sh },
        card,
    }

    local layout = Widgets.collectFocusableLayout(card)
    local BaseClass = (ok_fm and FocusManager and #layout > 0) and FocusManager or InputContainer
    overlay = BaseClass:new{
        dimen = Geom:new{ w = sw, h = sh },
        is_always_active = opts.is_always_active,
        layout = (#layout > 0) and layout or nil,
        container_widget,
    }
    overlay.key_events = overlay.key_events or {}
    overlay.key_events.FocusUp = overlay.key_events.FocusUp or { { "Up" }, event = "FocusMove", args = { 0, -1 } }
    overlay.key_events.FocusDown = overlay.key_events.FocusDown or { { "Down" }, event = "FocusMove", args = { 0, 1 } }
    overlay.key_events.FocusLeft = overlay.key_events.FocusLeft or { { "Left" }, event = "FocusMove", args = { -1, 0 } }
    overlay.key_events.FocusRight = overlay.key_events.FocusRight or { { "Right" }, event = "FocusMove", args = { 1, 0 } }
    overlay.key_events.Press = overlay.key_events.Press or { { "Press" }, event = "Press" }
    table.insert(overlay.key_events.Press, { "Return" })
    table.insert(overlay.key_events.Press, { "KP_Enter" })
    overlay.key_events.Close = { { "Back" }, { "Escape" } }
    if Device and Device.input and Device.input.group and Device.input.group.Back then
        table.insert(overlay.key_events.Close, { Device.input.group.Back })
    end
    if BaseClass == FocusManager then
        Widgets.installLazyFocus(overlay)
    end
    overlay.onClose = function()
        closeDlg()
        if opts.on_close then opts.on_close() end
        return true
    end
    overlay.onCloseDialog = overlay.onClose
    UIManager:show(overlay, "ui")
    return overlay, closeDlg
end

--- Styled confirmation card dialog replacing KOReader's ConfirmBox.
function Widgets.showConfirmDialog(opts)
    opts = opts or {}
    return Widgets.showCardDialog{
        title = opts.title or _("Confirm"),
        body_text = opts.text or "",
        on_close = opts.cancel_callback,
        buttons = {
            {
                text = opts.cancel_text or _("Cancel"),
                callback = function()
                    if opts.cancel_callback then opts.cancel_callback() end
                end,
            },
            {
                text = opts.ok_text or _("OK"),
                is_primary = true,
                callback = function()
                    if opts.ok_callback then opts.ok_callback() end
                end,
            },
        },
    }
end

--- Styled single- or multi-field input card dialog replacing KOReader's InputDialog & MultiInputDialog.
-- @param opts table { title, description, input, hint, fields = { { label, text, hint, text_type } }, buttons = { ... }, on_submit = function(val_or_vals) }
function Widgets.showInputDialog(opts)
    opts = opts or {}
    local fields_spec = opts.fields or {
        {
            label = opts.description,
            text = opts.input or "",
            hint = opts.hint or "",
            text_type = opts.text_type,
        },
    }
    local inputs = {}
    local overlay_ref = nil

    local function getValues()
        local vals = {}
        for i, inp in ipairs(inputs) do
            vals[i] = (inp.getText and inp:getText()) or inp.text or ""
        end
        return vals[1], vals
    end

    local function cleanupInputs()
        for _, inp in ipairs(inputs) do
            pcall(function() inp:onCloseKeyboard() end)
            pcall(function() inp:onCloseWidget() end)
        end
    end

    local action_buttons = {}
    if opts.buttons then
        for _, b in ipairs(opts.buttons) do
            table.insert(action_buttons, {
                text = b.text,
                is_primary = b.is_primary,
                keep_open = true,
                callback = function(closeDlg)
                    local v1, all_v = getValues()
                    if not b.keep_open and closeDlg then closeDlg() end
                    if b.callback then b.callback(v1, all_v, closeDlg) end
                end,
            })
        end
    else
        table.insert(action_buttons, {
            text = opts.cancel_text or _("Cancel"),
            keep_open = true,
            callback = function(closeDlg)
                if closeDlg then closeDlg() end
                if opts.on_cancel then opts.on_cancel() end
            end,
        })
        table.insert(action_buttons, {
            text = opts.save_text or _("Save"),
            is_primary = true,
            keep_open = true,
            callback = function(closeDlg)
                local v1, all_v = getValues()
                if closeDlg then closeDlg() end
                if opts.on_submit then opts.on_submit(v1, all_v) end
            end,
        })
    end

    local has_phys_kb = (Device.hasKeyboard and Device:hasKeyboard()) or (Device.hasScreenKB and Device:hasScreenKB())
    local vk_disabled = _G.G_reader_settings and _G.G_reader_settings.nilOrFalse and _G.G_reader_settings:nilOrFalse("virtual_keyboard_enabled")
    local should_show_vk = not (has_phys_kb and vk_disabled)

    local sh = Device.screen:getHeight()
    local overlay, closeDlg = Widgets.showCardDialog{
        title = opts.title or _("Input"),
        is_always_active = true,
        container_h = should_show_vk and math.floor(sh * 0.58) or sh,
        on_before_close = cleanupInputs,
        on_close = opts.on_cancel,
        body_widget = function(inner_w, close_fn)
            local vg = VerticalGroup:new{ align = "left" }
            for idx, fspec in ipairs(fields_spec) do
                if idx > 1 then
                    table.insert(vg, VerticalSpan:new{ width = sc(8) })
                end
                if fspec.label and fspec.label ~= "" then
                    table.insert(vg, TextWidget:new{
                        text = fspec.label,
                        face = Font:getFace("cfont", 14),
                        fgcolor = theme.color_label_dim,
                        max_width = inner_w,
                    })
                    table.insert(vg, VerticalSpan:new{ width = sc(4) })
                end
                local inp = InputText:new{
                    text = fspec.text or "",
                    hint = fspec.hint or "",
                    text_type = fspec.text_type,
                    face = Font:getFace("cfont", 16),
                    width = inner_w - sc(20),
                    padding = sc(8),
                    margin = 0,
                    bordersize = sc(1),
                    focused = (idx == 1),
                    scroll = false,
                    enter_callback = function()
                        local v1, all_v = getValues()
                        close_fn()
                        if opts.on_submit then
                            opts.on_submit(v1, all_v)
                        else
                            for _, b in ipairs(action_buttons) do
                                if b.is_primary and b.callback then
                                    b.callback(close_fn)
                                    break
                                end
                            end
                        end
                    end,
                }
                if inp._frame_textwidget then
                    inp._frame_textwidget.radius = theme.radius_btn or sc(4)
                    inp._frame_textwidget.color = (idx == 1) and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY
                end
                table.insert(inputs, inp)
                table.insert(vg, inp)
            end
            return vg
        end,
        buttons = action_buttons,
    }

    overlay_ref = overlay
    overlay_ref.getFocusableWidgetXY = function() return nil end
    overlay_ref.onSwitchFocus = function(_, target_inp)
        for _, inp in ipairs(inputs) do
            if inp ~= target_inp then
                pcall(function() inp:unfocus() end)
                pcall(function() inp:onCloseKeyboard() end)
            end
        end
        pcall(function() target_inp:focus() end)
        if should_show_vk then
            pcall(function() target_inp:onShowKeyboard() end)
        end
        UIManager:setDirty(overlay_ref, "ui")
    end

    for _, inp in ipairs(inputs) do
        inp.parent = overlay_ref
        if inp.text_widget then
            inp.text_widget.dialog = overlay_ref
        end
    end
    if should_show_vk and inputs[1] then
        pcall(function() inputs[1]:onShowKeyboard() end)
    end
    return overlay, closeDlg
end

return Widgets
