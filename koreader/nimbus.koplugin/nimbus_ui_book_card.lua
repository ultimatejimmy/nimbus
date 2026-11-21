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
local VerticalSpan = require("ui/widget/verticalspan")
local FrameContainer = require("ui/widget/container/framecontainer")
local Blitbuffer = require("ffi/blitbuffer")
local ok_util, util = pcall(require, "util")
local ko_gettext = require("gettext")
local ok_loc, Localization = pcall(require, "localization_nimbus")
local _ = (ok_loc and Localization and Localization.getHelper) and Localization:getHelper() or ko_gettext

local Settings = require("nimbus_settings")
local Cloud = require("nimbus_cloud")
local Sync = require("nimbus_sync")
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

local function promptDeleteFromCloud(item, opts)
    local msg = item.local_path
        and _("Delete this book from Nimbus Cloud? Any local copy on your device will stay.")
        or _("Delete this book from Nimbus Cloud? This cannot be undone.")
    Widgets.showConfirmDialog{
        title = _("Delete from Cloud"),
        text = msg,
        ok_text = _("Delete"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            if opts.on_delete_cloud then
                opts.on_delete_cloud(item)
            else
                Sync.deleteCloudBook(item.cloud_id or item.id, item, function(ok, err)
                    if ok then
                        if opts.on_refresh then opts.on_refresh() end
                        Widgets.showToast(_("Deleted from Nimbus Cloud."), 2)
                    else
                        Widgets.showToast(_("Failed to delete from cloud: ") .. tostring(err), 4)
                    end
                end)
            end
        end,
    }
end

local function getNativeFileContext(local_path)
    if not local_path or local_path == "" then return nil end
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    local ok_fmu, filemanagerutil = pcall(require, "apps/filemanager/filemanagerutil")
    local ok_bl, BookList = pcall(require, "ui/widget/booklist")
    local ok_ds, DocSettings = pcall(require, "docsettings")
    local ok_dr, DocumentRegistry = pcall(require, "document/documentregistry")
    local ok_bi, FileManagerBookInfo = pcall(require, "apps/filemanager/filemanagerbookinfo")
    local fm = ok_fm and FileManager and FileManager.instance or nil
    local has_provider = ok_dr and DocumentRegistry and DocumentRegistry:hasProvider(local_path) or false
    local been_opened = ok_bl and BookList and BookList.hasBookBeenOpened(local_path) or false
    local doc_settings_or_file = local_path
    local book_props = fm and fm.coverbrowser and fm.coverbrowser.getBookInfo and fm.coverbrowser:getBookInfo(local_path) or nil
    if been_opened and ok_bl and BookList and BookList.getDocSettings then
        doc_settings_or_file = BookList.getDocSettings(local_path)
        if not book_props and ok_bi and FileManagerBookInfo and doc_settings_or_file then
            local props = doc_settings_or_file:readSetting("doc_props")
            book_props = FileManagerBookInfo.extendProps(props, local_path)
            book_props.has_cover = true
        end
    end
    local annotations = (been_opened and type(doc_settings_or_file) == "table" and doc_settings_or_file.readSetting)
        and doc_settings_or_file:readSetting("annotations") or nil
    return {
        file = local_path,
        fm = fm,
        filemanagerutil = ok_fmu and filemanagerutil or nil,
        BookList = ok_bl and BookList or nil,
        DocSettings = ok_ds and DocSettings or nil,
        has_provider = has_provider,
        been_opened = been_opened,
        doc_settings_or_file = doc_settings_or_file,
        book_props = book_props,
        annotations = annotations,
    }
end

local function buildStatusPillsRow(ctx, item, merged_prog, inner_w, closeDlg, opts)
    if not (ctx and ctx.DocSettings) then return nil end
    local current_status
    if ctx.been_opened and type(ctx.doc_settings_or_file) == "table" and ctx.doc_settings_or_file.readSetting then
        local summary = ctx.doc_settings_or_file:readSetting("summary")
        current_status = summary and summary.status
    end
    if not current_status then
        current_status = (merged_prog and merged_prog.status) or item.status
    end
    if current_status == "finished" then current_status = "complete" end

    local statuses = {
        { id = "reading", label = ko_gettext("Reading") },
        { id = "abandoned", label = ko_gettext("On hold") },
        { id = "complete", label = ko_gettext("Finished") },
    }
    local gap = sc(6)
    local btn_w = math.floor((inner_w - (gap * 2)) / 3)
    local row_items = { align = "center" }
    for idx, st in ipairs(statuses) do
        if idx > 1 then table.insert(row_items, HorizontalSpan:new{ width = gap }) end
        local is_active = (current_status == st.id)
        local btn = Widgets.createButton{
            text = is_active and (st.label .. " ✓") or st.label,
            is_primary = is_active,
            width = btn_w,
            padding = sc(6),
            padding_h = sc(4),
            text_font_size = theme.fs and theme.fs("detail") or 14,
            callback = function()
                local ds = ctx.DocSettings:open(ctx.file)
                local summary = ds:readSetting("summary") or {}
                summary.status = st.id
                ds:saveSetting("summary", summary)
                ds:flush()
                if ctx.BookList and ctx.BookList.setBookInfoCacheProperty then
                    ctx.BookList.setBookInfoCacheProperty(ctx.file, "status", st.id)
                end
                item.status = st.id
                if merged_prog then merged_prog.status = st.id end
                closeDlg()
                if opts.on_refresh then opts.on_refresh() end
            end,
        }
        table.insert(row_items, btn)
    end
    return HorizontalGroup:new(row_items)
end

local function addNativeRow(rows, btn, chevron, inner_w, closeDlg)
    if not btn or btn.enabled == false or not btn.text or not btn.callback then return end
    table.insert(rows, Widgets.createMenuRow(btn.text, chevron(), inner_w, function()
        closeDlg()
        btn.callback()
    end))
end

local function showMoreBookActionsMenu(item, merged_prog, opts, ctx)
    local local_path = item.local_path
    local is_in_cloud = item.is_in_cloud or (item.folder ~= nil)
    local chevron = function()
        return TextWidget:new{ text = "›", face = Font:getFace("cfont", theme.fs and theme.fs("subtitle") or 18), fgcolor = theme.color_label_dim }
    end

    Widgets.showCardDialog{
        title = tostring(item.title or _("Book Actions")),
        body_widget = function(inner_w, closeDlg)
            local rows = {}
            local noop = function() end
            local refresh_cb = function()
                if opts.on_refresh then opts.on_refresh() end
            end
            local close_and_refresh = function()
                closeDlg()
                refresh_cb()
            end

            if ctx and ctx.fm and ctx.filemanagerutil then
                if ctx.has_provider then
                    addNativeRow(rows, ctx.filemanagerutil.genBookCoverButton(local_path, ctx.book_props, noop), chevron, inner_w, closeDlg)
                    addNativeRow(rows, ctx.filemanagerutil.genBookDescriptionButton(local_path, ctx.book_props, noop), chevron, inner_w, closeDlg)
                end
                if ctx.annotations and #ctx.annotations > 0 and ctx.fm.collections and ctx.fm.collections.genExportHighlightsButton then
                    addNativeRow(rows, ctx.fm.collections:genExportHighlightsButton({ [local_path] = true }, noop), chevron, inner_w, closeDlg)
                end
                if ctx.fm.showOpenWithDialog then
                    table.insert(rows, Widgets.createMenuRow(ko_gettext("Open with…"), chevron(), inner_w, function()
                        closeDlg()
                        ctx.fm:showOpenWithDialog(local_path)
                    end))
                end
                if ctx.has_provider or ctx.been_opened then
                    addNativeRow(rows, ctx.filemanagerutil.genResetSettingsButton(ctx.doc_settings_or_file, refresh_cb), chevron, inner_w, closeDlg)
                end
                if ctx.fm.file_dialog_added_buttons then
                    for _, row_func in ipairs(ctx.fm.file_dialog_added_buttons) do
                        local row = row_func(local_path, true, ctx.book_props)
                        if type(row) == "table" then
                            for _, btn in ipairs(row) do
                                addNativeRow(rows, btn, chevron, inner_w, closeDlg)
                            end
                        end
                    end
                end
                if ctx.fm.showRenameFileDialog then
                    table.insert(rows, Widgets.createMenuRow(ko_gettext("Rename"), chevron(), inner_w, function()
                        closeDlg()
                        ctx.fm:showRenameFileDialog(local_path, true)
                    end))
                end
                if ctx.fm.showDeleteFileDialog then
                    table.insert(rows, Widgets.createMenuRow(ko_gettext("Delete"), chevron(), inner_w, function()
                        closeDlg()
                        ctx.fm:showDeleteFileDialog(local_path, refresh_cb)
                    end))
                end
            end

            if is_in_cloud then
                table.insert(rows, Widgets.createMenuRow(_("Delete from Cloud"), chevron(), inner_w, function()
                    closeDlg()
                    promptDeleteFromCloud(item, opts)
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

function BookCardMixin.showBookActionsMenu(item, merged_prog, opts)
    opts = opts or {}
    local local_path = item.local_path
    local is_in_cloud = item.is_in_cloud or (item.folder ~= nil)
    local ctx = getNativeFileContext(local_path)
    local chevron = function()
        return TextWidget:new{ text = "›", face = Font:getFace("cfont", theme.fs and theme.fs("subtitle") or 18), fgcolor = theme.color_label_dim }
    end

    Widgets.showCardDialog{
        title = tostring(item.title or _("Book Actions")),
        body_widget = function(inner_w, closeDlg)
            local rows = {}
            local noop = function() end
            local refresh_cb = function()
                if opts.on_refresh then opts.on_refresh() end
            end

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

            if ctx and ctx.fm and ctx.filemanagerutil then
                if ctx.has_provider or ctx.been_opened then
                    if ctx.fm.collections and ctx.fm.collections.genAddToCollectionButton then
                        addNativeRow(rows, ctx.fm.collections:genAddToCollectionButton(local_path, noop, refresh_cb), chevron, inner_w, closeDlg)
                    end
                end
                if ctx.annotations and #ctx.annotations > 0 and ctx.fm.collections and ctx.fm.collections.genBookmarkBrowserButton then
                    addNativeRow(rows, ctx.fm.collections:genBookmarkBrowserButton({ [local_path] = true }, noop), chevron, inner_w, closeDlg)
                end
                addNativeRow(rows, ctx.filemanagerutil.genBookInformationButton(ctx.doc_settings_or_file, ctx.book_props, noop), chevron, inner_w, closeDlg)
            else
                table.insert(rows, Widgets.createMenuRow(_("Book Details"), chevron(), inner_w, function()
                    closeDlg()
                    BookCardMixin.showBookDetailModal(item, merged_prog, opts)
                end))
            end

            if local_path or is_in_cloud then
                table.insert(rows, Widgets.createMenuRow(ko_gettext("More…"), chevron(), inner_w, function()
                    closeDlg()
                    showMoreBookActionsMenu(item, merged_prog, opts, ctx)
                end))
            end

            local menu_list = Widgets.createMenuList(rows, inner_w)
            local status_row = buildStatusPillsRow(ctx, item, merged_prog, inner_w, closeDlg, opts)
            if status_row then
                return VerticalGroup:new{
                    align = "left",
                    status_row,
                    VerticalSpan:new{ width = sc(10) },
                    menu_list,
                }
            end
            return menu_list
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
        body_widget = function(inner_w, closeDlg)
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
            local top_row = HorizontalGroup:new{
                align = "top",
                cover_frame,
                HorizontalSpan:new{ width = sc(12) },
                info_vg,
            }
            if not is_in_cloud then
                return top_row
            end
            return VerticalGroup:new{
                align = "left",
                top_row,
                VerticalSpan:new{ width = sc(10) },
                Widgets.createButton{
                    text = _("Delete from Cloud"),
                    width = inner_w,
                    callback = function()
                        closeDlg()
                        promptDeleteFromCloud(item, opts)
                    end,
                },
            }
        end,
        buttons = buttons,
    }
end

return BookCardMixin
