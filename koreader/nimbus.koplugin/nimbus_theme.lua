--[[--
nimbus_theme.lua
Theme and styling constants for Nimbus (matching Storefront / Libbee / Beeline).
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = package.loaded["device"]
if not Device then
    local ok, dev = pcall(require, "device")
    if ok then Device = dev end
end

local function sc(val)
    return (Device and Device.screen and Device.screen.scaleBySize and Device.screen:scaleBySize(val)) or val
end

local nimbus_theme = {
    sc = sc,
    border_line_h = sc(1),
    border_window = sc(2),
    border_btn = sc(1),
    border_preview = sc(2),
    color_border = Blitbuffer.COLOR_DARK_GRAY,
    color_bg = Blitbuffer.COLOR_WHITE,
    color_bg_dim = Blitbuffer.COLOR_LIGHT_GRAY,
    color_label_dim = Blitbuffer.COLOR_BLACK,
    color_section_rule = Blitbuffer.COLOR_DARK_GRAY,
    radius_window = sc(4),
    radius_toast = sc(4),
    radius_btn = sc(4),
    radius_spec_btn = sc(8),
    radius_badge = sc(10),
    gap = sc(8),
    face_label_size = 18,
    title_font_size = 22,
    subtext_font_size = 16,
    section_header_font_size = 16,
    border_focus = sc(3),
    color_focus_border = Blitbuffer.COLOR_BLACK,
    color_focus_bg = Blitbuffer.COLOR_LIGHT_GRAY,
    color_focus_fg = Blitbuffer.COLOR_BLACK,
    radius_focus = sc(4),
}

function nimbus_theme.getTitleFontName()
    local sui_style = package.loaded["features/sui_style"]
    return (sui_style and sui_style.FACE_BOLD) or "tfont"
end

function nimbus_theme.getBodyFontName()
    local sui_style = package.loaded["features/sui_style"]
    return (sui_style and sui_style.FACE_REGULAR) or "cfont"
end

function nimbus_theme.resolveHomeViewport(opts, is_home)
    opts = opts or {}
    local sw = opts.width or (Device and Device.screen and Device.screen:getWidth()) or 600
    local sh = opts.height or (Device and Device.screen and Device.screen:getHeight()) or 800
    if is_home and not opts.height then
        local sui_core = package.loaded["infra/sui_core"]
        if sui_core and type(sui_core.getContentHeight) == "function" then
            local ok_h, content_h = pcall(sui_core.getContentHeight)
            if ok_h and type(content_h) == "number" and content_h > sc(200) then
                sh = content_h
            end
        end
    end
    return sw, sh
end

return nimbus_theme
