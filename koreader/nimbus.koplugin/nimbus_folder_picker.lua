--[[--
nimbus_folder_picker.lua
Directory browser modal (adapted from Storefront's FolderPicker, styled for Nimbus e-ink theme)
for choosing the local Book Folder.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local TextWidget = require("ui/widget/textwidget")
local ImageWidget = require("ui/widget/imagewidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local ok_util, util = pcall(require, "util")
local ok_loc, Localization = pcall(require, "localization_nimbus")
local _ = (ok_loc and Localization and Localization.getHelper) and Localization:getHelper() or require("gettext")

local Scanner = require("nimbus_scanner")
local Widgets = require("nimbus_ui_widgets")
local theme = require("nimbus_theme")

local FolderPicker = {}
local sc = theme.sc

local function getLfs()
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs then
        ok_lfs, lfs = pcall(require, "lfs")
    end
    return ok_lfs and lfs or nil
end

function FolderPicker.getParentPath(path)
    if not path or path == "" or path == "/" then return nil end
    local clean = tostring(path):match("^%s*(.-)%s*$"):gsub("[/\\]+$", "")
    if clean == "" or clean == "/" then return nil end
    local parent = clean:match("^(.-)[/\\]+[^/\\]+$")
    if not parent or parent == "" then
        if clean:match("^/[^/]+$") then return "/" end
        if clean:match("^[a-zA-Z]:$") then return nil end
        return "/"
    end
    return parent
end

function FolderPicker.scanDirectory(path)
    local subdirs = {}
    local book_count = 0
    local lfs = getLfs()
    if not lfs or not lfs.dir then
        return subdirs, book_count
    end

    pcall(function()
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." and not entry:match("^%.") then
                local full_path = (path == "/" and "/" .. entry) or (path .. "/" .. entry)
                local ok_attr, attr = pcall(lfs.attributes, full_path)
                if ok_attr and attr and attr.mode == "directory" then
                    if not entry:match("%.sdr$") then
                        table.insert(subdirs, {
                            name = entry,
                            path = full_path,
                        })
                    end
                elseif ok_attr and attr and attr.mode == "file" and Scanner.isBookFile(entry) then
                    book_count = book_count + 1
                end
            end
        end
    end)

    table.sort(subdirs, function(a, b)
        return (a.name or ""):lower() < (b.name or ""):lower()
    end)
    return subdirs, book_count
end

function FolderPicker.show(options)
    options = options or {}
    local title_text = options.title or _("Select Folder")
    local current_path = options.initial_path
    local current_page = 1

    if not current_path or current_path == "" then
        local ok_ds, DataStorage = pcall(require, "datastorage")
        current_path = (ok_ds and DataStorage and DataStorage.getDataDir and DataStorage:getDataDir()) or "/"
    end
    current_path = tostring(current_path):gsub("[/\\]+$", "")
    if current_path == "" then current_path = "/" end

    local lfs = getLfs()
    if lfs and lfs.attributes and lfs.attributes(current_path, "mode") ~= "directory" then
        local p = FolderPicker.getParentPath(current_path)
        while p and lfs.attributes(p, "mode") ~= "directory" do
            p = FolderPicker.getParentPath(p)
        end
        current_path = p or "/"
    end

    local sw = (Device.screen and Device.screen:getWidth()) or 600
    local sh = (Device.screen and Device.screen:getHeight()) or 800
    local dialog_w = math.min(sw - sc(24), sc(460))
    local pad = sc(14)
    local border = theme.border_window or sc(2)
    local inner_w = dialog_w - (pad * 2) - (border * 2)

    local overlay
    local refresh

    local function closePicker()
        if overlay then
            local ov = overlay
            overlay = nil
            UIManager:close(ov, "ui")
        end
    end

    local function cancelPicker()
        closePicker()
        if options.on_cancel then options.on_cancel() end
    end

    local function confirmPicker()
        closePicker()
        if options.on_select then options.on_select(current_path) end
    end

    local function promptNewFolder()
        Widgets.showInputDialog{
            title = _("Create Folder"),
            description = _("Folder name:"),
            input = "",
            save_text = _("Create"),
            on_cancel = function() end,
            on_submit = function(name)
                local clean = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("[/\\]", "")
                if clean == "" then return end
                local new_path = (current_path == "/" and ("/" .. clean)) or (current_path .. "/" .. clean)
                local ok_mk = false
                if ok_util and util and util.makePath then
                    ok_mk = pcall(util.makePath, new_path)
                elseif lfs and lfs.mkdir then
                    ok_mk = lfs.mkdir(new_path) and true or false
                end
                if ok_mk then
                    current_path = new_path
                    current_page = 1
                    Widgets.showToast(string.format(_("Created '%s'."), clean), 2)
                    refresh()
                else
                    Widgets.showToast(_("Failed to create folder."), 2.5)
                end
            end,
        }
    end

    refresh = function()
        local subdirs, book_count = FolderPicker.scanDirectory(current_path)
        local parent_path = FolderPicker.getParentPath(current_path)

        local rows_data = {}
        if parent_path then
            table.insert(rows_data, {
                is_up = true,
                name = "..",
                path = parent_path,
            })
        end
        for _i, sd in ipairs(subdirs) do
            table.insert(rows_data, sd)
        end

        local items_per_page = 7
        local total_pages = math.max(1, math.ceil(#rows_data / items_per_page))
        if current_page > total_pages then current_page = total_pages end

        local content_vg = VerticalGroup:new{ align = "left" }

        -- Header
        local close_btn = Widgets.createIconButton{
            icon = "x.svg",
            size = sc(22),
            padding = sc(6),
            callback = cancelPicker,
        }
        local title_w = TextWidget:new{
            text = title_text,
            face = Font:getFace(theme.getTitleFontName(), 20),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
            max_width = inner_w - sc(36),
        }
        table.insert(content_vg, HorizontalGroup:new{
            title_w,
            HorizontalSpan:new{ width = math.max(sc(8), inner_w - title_w:getSize().w - close_btn:getSize().w) },
            close_btn,
        })
        table.insert(content_vg, VerticalSpan:new{ width = sc(6) })
        table.insert(content_vg, LineWidget:new{
            dimen = Geom:new{ w = inner_w, h = sc(1) },
            background = Blitbuffer.COLOR_BLACK,
        })
        table.insert(content_vg, VerticalSpan:new{ width = sc(8) })

        -- Current path + book count summary
        local path_text = current_path
        if #path_text > 44 then path_text = "..." .. path_text:sub(-41) end
        table.insert(content_vg, TextWidget:new{
            text = path_text,
            face = Font:getFace(theme.getBodyFontName(), 14),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
            max_width = inner_w,
        })
        table.insert(content_vg, TextWidget:new{
            text = string.format(_("%d %s in this folder"), book_count, (book_count == 1) and _("book") or _("books")),
            face = Font:getFace(theme.getBodyFontName(), 13),
            fgcolor = Blitbuffer.COLOR_BLACK,
            max_width = inner_w,
        })
        table.insert(content_vg, VerticalSpan:new{ width = sc(8) })

        -- Directory list
        local start_idx = (current_page - 1) * items_per_page + 1
        local end_idx = math.min(#rows_data, start_idx + items_per_page - 1)
        local list_rows = {}
        for i = start_idx, end_idx do
            local item = rows_data[i]
            local icon_file = item.is_up and "chevron-left.svg" or "folder.svg"
            local icon_w = ImageWidget:new{
                file = Widgets.getAssetPath(icon_file),
                width = sc(18),
                height = sc(18),
                scale_factor = 0,
                is_icon = true,
                alpha = true,
            }
            local lbl = TextWidget:new{
                text = item.is_up and _("Parent Folder") or item.name,
                face = Font:getFace(theme.getBodyFontName(), 15),
                bold = item.is_up == true,
                fgcolor = Blitbuffer.COLOR_BLACK,
                max_width = inner_w - sc(48),
            }
            local chevron_w = ImageWidget:new{
                file = Widgets.getAssetPath("chevron-right.svg"),
                width = sc(16),
                height = sc(16),
                scale_factor = 0,
                is_icon = true,
                alpha = true,
            }
            local left_hg = HorizontalGroup:new{
                align = "center",
                icon_w,
                HorizontalSpan:new{ width = sc(8) },
                lbl,
            }
            local spacer_w = math.max(sc(8), inner_w - sc(24) - left_hg:getSize().w - chevron_w:getSize().w)
            local row_frame = FrameContainer:new{
                padding_top = sc(7),
                padding_bottom = sc(7),
                padding_left = sc(10),
                padding_right = sc(10),
                bordersize = 0,
                width = inner_w - sc(2),
                HorizontalGroup:new{
                    align = "center",
                    left_hg,
                    HorizontalSpan:new{ width = spacer_w },
                    chevron_w,
                },
            }
            table.insert(list_rows, Widgets.makeTapItem(row_frame, function()
                current_path = item.path
                current_page = 1
                refresh()
            end))
        end

        if #list_rows > 0 then
            table.insert(content_vg, Widgets.createMenuList(list_rows, inner_w))
        else
            table.insert(content_vg, TextWidget:new{
                text = _("No subfolders"),
                face = Font:getFace(theme.getBodyFontName(), 14),
                fgcolor = Blitbuffer.COLOR_BLACK,
                max_width = inner_w,
            })
        end

        -- Pagination
        if total_pages > 1 then
            table.insert(content_vg, VerticalSpan:new{ width = sc(8) })
            local prev_btn = Widgets.createIconButton{
                icon = "chevron-left.svg",
                size = sc(18),
                padding = sc(4),
                callback = current_page > 1 and function()
                    current_page = current_page - 1
                    refresh()
                end or nil,
            }
            local next_btn = Widgets.createIconButton{
                icon = "chevron-right.svg",
                size = sc(18),
                padding = sc(4),
                callback = current_page < total_pages and function()
                    current_page = current_page + 1
                    refresh()
                end or nil,
            }
            local page_lbl = TextWidget:new{
                text = string.format(_("Page %d of %d"), current_page, total_pages),
                face = Font:getFace(theme.getBodyFontName(), 14),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
            table.insert(content_vg, CenterContainer:new{
                dimen = Geom:new{ w = inner_w, h = sc(28) },
                HorizontalGroup:new{
                    align = "center",
                    prev_btn,
                    HorizontalSpan:new{ width = sc(16) },
                    page_lbl,
                    HorizontalSpan:new{ width = sc(16) },
                    next_btn,
                },
            })
        end

        -- Bottom buttons: Cancel | + New | Select Folder
        table.insert(content_vg, VerticalSpan:new{ width = sc(10) })
        local btn_gap = sc(8)
        local cancel_str = _("Cancel")
        local new_str = _("+ New")
        local select_str = _("Select Folder")
        local labels = { cancel_str, new_str, select_str }
        local nat_w, sum_nat = {}, 0
        local avail_w = inner_w - (btn_gap * 2)
        for idx, txt in ipairs(labels) do
            local tw = TextWidget:new{
                text = txt,
                face = Font:getFace(theme.getBodyFontName(), 15),
                bold = (idx == 3),
            }
            local w = tw:getSize().w + sc(20)
            nat_w[idx] = w
            sum_nat = sum_nat + w
        end
        local widths = {}
        if sum_nat <= avail_w then
            local extra = math.floor((avail_w - sum_nat) / 3)
            local rem = avail_w - sum_nat - (extra * 3)
            for idx = 1, 3 do
                widths[idx] = nat_w[idx] + extra + (idx == 1 and rem or 0)
            end
        else
            local eq = math.floor(avail_w / 3)
            for idx = 1, 3 do widths[idx] = eq end
        end

        table.insert(content_vg, HorizontalGroup:new{
            Widgets.createButton{
                text = cancel_str,
                padding_h = sc(6),
                width = widths[1],
                callback = cancelPicker,
            },
            HorizontalSpan:new{ width = btn_gap },
            Widgets.createButton{
                text = new_str,
                padding_h = sc(6),
                width = widths[2],
                callback = promptNewFolder,
            },
            HorizontalSpan:new{ width = btn_gap },
            Widgets.createButton{
                text = select_str,
                is_primary = true,
                padding_h = sc(6),
                width = widths[3],
                callback = confirmPicker,
            },
        })

        local card = FrameContainer:new{
            padding = pad,
            radius = theme.radius_window or sc(4),
            bordersize = border,
            color = Blitbuffer.COLOR_BLACK,
            background = Blitbuffer.COLOR_WHITE,
            width = dialog_w,
            content_vg,
        }

        local next_overlay = InputContainer:new{
            dimen = Geom:new{ w = sw, h = sh },
            key_events = { Close = { { "Back" }, { "Escape" } } },
            CenterContainer:new{
                dimen = Geom:new{ w = sw, h = sh },
                card,
            },
        }
        next_overlay.onClose = function()
            cancelPicker()
            return true
        end
        next_overlay.onCloseDialog = next_overlay.onClose

        if overlay then
            UIManager:close(overlay, "ui")
        end
        overlay = next_overlay
        UIManager:show(overlay, "ui")
    end

    refresh()
end

return FolderPicker
