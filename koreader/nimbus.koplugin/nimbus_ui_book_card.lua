--[[--
nimbus_ui_book_card.lua
Mixin for UILibrary: Download helper, dense bordered Book Actions menu,
and Book Details modal.
--]]

local Font = require("ui/font")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local FrameContainer = require("ui/widget/container/framecontainer")
local Blitbuffer = require("ffi/blitbuffer")
local ok_util, util = pcall(require, "util")
local _ = require("gettext")

local Settings = require("nimbus_settings")
local Cloud = require("nimbus_cloud")
local Covers = require("nimbus_covers")
local NimbusProgress = require("nimbus_progress")
local Widgets = require("nimbus_ui_widgets")
local theme = require("nimbus_theme")

local BookCardMixin = {}
local sc = theme.sc

function BookCardMixin.downloadBook(item, open_after, opts)
    opts = opts or {}
    local cfg = Settings.load()
    local ok_sc, Scanner = pcall(require, "nimbus_scanner")
    local dirs = (ok_sc and Scanner and Scanner.getEffectiveBooksDirs) and Scanner.getEffectiveBooksDirs() or {}
    local base_dir = (dirs[1] and dirs[1] ~= "") and dirs[1] or cfg.download_dir
    local rel = tostring(item.relative_dir or ""):gsub("\\", "/"):gsub("^/+", ""):gsub("/+$", "")
    local target_dir = (rel ~= "") and (base_dir .. "/" .. rel) or base_dir
    if ok_util and util and util.makePath then
        util.makePath(target_dir)
    end
    local dest = target_dir .. "/" .. (item.filename or (item.id .. "." .. (item.format or "epub")))
    local prog_dlg = NimbusProgress:new{
        title = _("Downloading Book"),
        subtitle = _("Connecting to cloud storage..."),
        detail = item.filename or item.title,
        progress = 0,
    }
    prog_dlg:show()

    UIManager:nextTick(function()
        Cloud.downloadFile(item.folder .. "/" .. item.filename, dest, function(ok, err)
            prog_dlg:close()
            if ok then
                Settings.linkBook(dest, item.id)
                if open_after and opts.on_open_book then
                    opts.on_open_book(dest)
                else
                    if opts.on_downloaded then opts.on_downloaded(item, dest) end
                    Widgets.showToast(string.format(_("Downloaded '%s'."), tostring(item.title or _("Book"))), 2.5)
                end
            elseif err ~= "canceled" then
                Widgets.showToast(_("Download failed: ") .. tostring(err), 4)
            end
        end, {
            expected_size = item.size_bytes,
            is_canceled = function() return prog_dlg:isCanceled() end,
            on_progress = function(rec, total)
                local p = (total and total > 0) and math.floor((rec / total) * 100) or 0
                prog_dlg:setProgress(p, string.format("%s/%s (%d%%)",
                    NimbusProgress.formatBytes(rec), NimbusProgress.formatBytes(total), p))
            end,
        })
    end)
end

local function promptOffloadLocal(item, opts)
    local local_path = item.local_path
    Widgets.showConfirmDialog{
        title = _("Offload Local Book"),
        text = _("Delete the local file from this device? Your book, progress, and highlights remain safe in Nimbus Cloud."),
        ok_text = _("Offload"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            if opts.on_offload_local then
                opts.on_offload_local(item)
            else
                local paths = item.all_local_paths or { local_path }
                if opts.on_refresh then opts.on_refresh() end
                Widgets.showToast(_("Offloaded from device."), 2)
                UIManager:nextTick(function()
                    for _, p in ipairs(paths) do
                        pcall(os.remove, p)
                    end
                    Settings.unlinkBook(item.cloud_id or item.id, local_path)
                end)
            end
        end,
    }
end

function BookCardMixin.showBookActionsMenu(item, merged_prog, opts)
    opts = opts or {}
    local local_path = item.local_path
    local is_in_cloud = item.is_in_cloud or (item.folder ~= nil)
    local chevron = function()
        return TextWidget:new{ text = "›", face = Font:getFace("cfont", 18), fgcolor = theme.color_label_dim }
    end

    Widgets.showCardDialog{
        title = tostring(item.title or _("Book Actions")),
        body_widget = function(inner_w, closeDlg)
            local rows = {}
            if local_path then
                table.insert(rows, Widgets.createMenuRow(_("Open Book"), chevron(), inner_w, function()
                    closeDlg()
                    if opts.on_open_book then opts.on_open_book(local_path) end
                end))
                if not is_in_cloud and opts.on_upload_single then
                    table.insert(rows, Widgets.createMenuRow(_("Upload to Cloud"), chevron(), inner_w, function()
                        closeDlg()
                        opts.on_upload_single(item)
                    end))
                elseif is_in_cloud then
                    table.insert(rows, Widgets.createMenuRow(_("Offload Local"), chevron(), inner_w, function()
                        closeDlg()
                        promptOffloadLocal(item, opts)
                    end))
                end
            elseif is_in_cloud then
                table.insert(rows, Widgets.createMenuRow(_("Download & Open"), chevron(), inner_w, function()
                    closeDlg()
                    BookCardMixin.downloadBook(item, true, opts)
                end))
                table.insert(rows, Widgets.createMenuRow(_("Download"), chevron(), inner_w, function()
                    closeDlg()
                    BookCardMixin.downloadBook(item, false, opts)
                end))
            end

            table.insert(rows, Widgets.createMenuRow(_("Book Details"), chevron(), inner_w, function()
                closeDlg()
                BookCardMixin.showBookDetailModal(item, merged_prog, opts)
            end))

            return Widgets.createMenuList(rows, inner_w)
        end,
        buttons = { { text = _("Close") } },
    }
end

function BookCardMixin.showBookDetailModal(item, merged_prog, opts)
    opts = opts or {}
    local local_path = item.local_path
    local is_in_cloud = item.is_in_cloud or (item.folder ~= nil)
    local authors_str = type(item.authors) == "table" and table.concat(item.authors, ", ") or tostring(item.authors or "")
    local pct = (merged_prog and merged_prog.percent) or item.percent or 0
    local status = (merged_prog and merged_prog.status) or item.status or "unread"
    local pct_str = string.format("%.1f%% (%s)", pct * 100, status)
    local series_str = item.series
        and (item.series .. (item.series_index and (" #" .. tostring(item.series_index)) or ""))
        or _("None")

    local buttons = {}
    if local_path then
        table.insert(buttons, {
            text = _("Open Book"),
            is_primary = true,
            callback = function()
                if opts.on_open_book then opts.on_open_book(local_path) end
            end,
        })
        if not is_in_cloud and opts.on_upload_single then
            table.insert(buttons, {
                text = _("Upload"),
                callback = function()
                    opts.on_upload_single(item)
                end,
            })
        elseif is_in_cloud then
            table.insert(buttons, {
                text = _("Offload"),
                callback = function()
                    promptOffloadLocal(item, opts)
                end,
            })
        end
    elseif is_in_cloud then
        table.insert(buttons, {
            text = _("Download & Open"),
            is_primary = true,
            callback = function()
                BookCardMixin.downloadBook(item, true, opts)
            end,
        })
        table.insert(buttons, {
            text = _("Download"),
            callback = function()
                BookCardMixin.downloadBook(item, false, opts)
            end,
        })
    end

    table.insert(buttons, { text = _("Close") })

    Widgets.showCardDialog{
        title = tostring(item.title or _("Book Details")),
        body_widget = function(inner_w)
            local cw, ch = sc(84), sc(120)
            local cached = Covers.getCachedCoverPath(item)
            local cover_w = cached and Covers.createCoverImageWidget(cached, cw, ch)
                or Covers.createPlaceholderWidget(cw, ch, item.title)
            local cover_frame = FrameContainer:new{
                bordersize = 0,
                padding = 0,
                cover_w,
            }
            local meta_w = math.max(sc(120), inner_w - cw - sc(14))
            local meta_lines = {
                string.format(_("Author: %s"), authors_str ~= "" and authors_str or _("Unknown")),
                string.format(_("Series: %s"), series_str),
                string.format(_("Format: %s"), tostring(item.format or ""):upper()),
                string.format(_("Progress: %s"), pct_str),
                string.format(_("Cloud: %s"), is_in_cloud and _("Synced") or _("Local Only")),
                string.format(_("Device: %s"), local_path and _("Downloaded") or _("In Cloud")),
            }
            local info_vg = VerticalGroup:new{
                align = "left",
                TextBoxWidget:new{
                    text = table.concat(meta_lines, "\n"),
                    face = Font:getFace("cfont", 15),
                    fgcolor = Blitbuffer.COLOR_BLACK,
                    width = meta_w,
                },
            }
            return HorizontalGroup:new{
                align = "top",
                cover_frame,
                HorizontalSpan:new{ width = sc(12) },
                info_vg,
            }
        end,
        buttons = buttons,
    }
end

return BookCardMixin
