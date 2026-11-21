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

function nimbus_theme.isSimpleUIActive()
    return package.loaded["features/sui_style"] ~= nil or package.loaded["infra/sui_core"] ~= nil
end

function nimbus_theme.getDensity()
    return nimbus_theme.isSimpleUIActive() and 1.25 or 1.0
end

local DEFAULT_FONT_SIZES = {
    title = 20,
    subtitle = 18,
    body = 16,
    detail = 14,
    caption = 12,
}

function nimbus_theme.fs(role)
    if nimbus_theme.isSimpleUIActive() then
        local sui_style = package.loaded["features/sui_style"]
        if role == "title" then
            return (sui_style and sui_style.FS_TITLE) or 22
        elseif role == "subtitle" then
            return (sui_style and sui_style.FS_SUBTITLE) or 20
        elseif role == "body" then
            return (sui_style and sui_style.FS_BODY) or 18
        elseif role == "detail" then
            return (sui_style and sui_style.FS_DETAIL) or 15
        elseif role == "caption" then
            return (sui_style and sui_style.FS_CAPTION) or 12
        end
    end
    return DEFAULT_FONT_SIZES[role] or 16
end

function nimbus_theme.icon(base)
    return sc(math.floor((base or 24) * nimbus_theme.getDensity() + 0.5))
end

function nimbus_theme.computeCoverGrid(opts)
    opts = opts or {}
    local sw = opts.sw or 600
    local avail_h = opts.avail_h or 500
    local base_cols = opts.cols or 3
    local margin_h = opts.margin_h or sc(14)
    local grid_gap = opts.grid_gap or sc(12)
    local title_slot_h = opts.title_slot_h or sc(38)
    local title_gap = opts.title_gap or sc(6)
    local tile_extra_h = title_gap + title_slot_h
    local min_gap_v = opts.min_gap_v or sc(8)
    local max_gap_v = opts.max_gap_v or sc(24)
    local aspect = opts.aspect or 1.42
    local min_cover_w = opts.min_cover_w or sc(40)
    local min_fill_ratio = opts.min_fill_ratio or 0.85

    local function evalLayout(c, r)
        local cw = math.floor((sw - (margin_h * 2) - (grid_gap * (c - 1))) / c)
        local rtw = (cw * c) + (grid_gap * (c - 1))
        local mh = math.floor((sw - rtw) / 2)
        local max_row_h = math.floor((avail_h - (min_gap_v * (r + 1))) / r)
        local max_cover_h = max_row_h - tile_extra_h
        local cover_w = math.min(cw, math.floor(max_cover_h / aspect))
        return {
            cols = c,
            rows = r,
            cell_w = cw,
            row_total_w = rtw,
            margin_h = mh,
            cover_w = cover_w,
        }
    end

    local candidates = {
        { cols = base_cols, rows = 3, fill = min_fill_ratio },
        { cols = base_cols, rows = 2, fill = min_fill_ratio },
        { cols = base_cols + 1, rows = 2, fill = 0.75 },
        { cols = base_cols, rows = 2, fill = 0.60 },
    }

    local chosen
    for _, cand in ipairs(candidates) do
        local res = evalLayout(cand.cols, cand.rows)
        if res.cover_w >= min_cover_w and res.cover_w >= math.floor(res.cell_w * cand.fill) then
            chosen = res
            break
        end
    end
    if not chosen then
        chosen = evalLayout(base_cols, 1)
        chosen.cover_w = math.max(min_cover_w, chosen.cover_w)
    end

    local cover_slot_w = chosen.cover_w
    local cover_slot_h = math.floor(cover_slot_w * aspect)
    local cover_row_h = cover_slot_h + tile_extra_h
    local leftover = math.max(0, avail_h - (chosen.rows * cover_row_h))
    local grid_gap_v = math.min(max_gap_v, math.max(min_gap_v, math.floor(leftover / (chosen.rows + 1))))

    return {
        cols = chosen.cols,
        rows = chosen.rows,
        per_page = chosen.cols * chosen.rows,
        cell_w = chosen.cell_w,
        row_total_w = chosen.row_total_w,
        margin_h = chosen.margin_h,
        grid_gap = grid_gap,
        grid_gap_v = grid_gap_v,
        cover_slot_w = cover_slot_w,
        cover_slot_h = cover_slot_h,
        cover_row_h = cover_row_h,
        title_slot_h = title_slot_h,
    }
end

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
