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

local function applyCloudProgressToSidecar(dest, item, merged_prog)
    local prog = merged_prog
    if not prog and item then
        local _, cached_mp = Sync.loadCachedCatalog()
        prog = cached_mp and cached_mp[item.cloud_id or item.id]
    end
    if type(prog) ~= "table" then return end
    local pct = tonumber(prog.percent) or 0
    local status = prog.status
    if pct <= 0 and (not status or status == "unread") and not prog.xpointer then
        return
    end
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if not ok_ds or not DocSettings or not DocSettings.open then return end
    pcall(function()
        local ds = DocSettings:open(dest)
        if pct > 0 then
            ds:saveSetting("percent_finished", pct)
        end
        if status and status ~= "unread" then
            local kor_status = (status == "finished") and "complete" or status
            local summary = ds:readSetting("summary") or {}
            summary.status = kor_status
            ds:saveSetting("summary", summary)
        end
        if prog.xpointer and prog.xpointer ~= "" then
            ds:saveSetting("last_xpointer", prog.xpointer)
        end
        ds:flush()
    end)
end

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
                applyCloudProgressToSidecar(dest, item, opts.merged_prog)
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
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    local ok_fmu, filemanagerutil = pcall(require, "apps/filemanager/filemanagerutil")
    local ok_dev, Device = pcall(require, "device")
    local fm = ok_fm and FileManager and FileManager.instance or nil
    if not local_path or local_path == "" then
        return {
            file = nil,
            fm = fm,
            filemanagerutil = ok_fmu and filemanagerutil or nil,
            Device = ok_dev and Device or nil,
        }
    end
    local ok_bl, BookList = pcall(require, "ui/widget/booklist")
    local ok_ds, DocSettings = pcall(require, "docsettings")
    local ok_dr, DocumentRegistry = pcall(require, "document/documentregistry")
    local ok_bi, FileManagerBookInfo = pcall(require, "apps/filemanager/filemanagerbookinfo")
    local ok_conv, FileManagerConverter = pcall(require, "apps/filemanager/filemanagerconverter")
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
        Converter = ok_conv and FileManagerConverter or nil,
        Device = ok_dev and Device or nil,
        has_provider = has_provider,
        been_opened = been_opened,
        doc_settings_or_file = doc_settings_or_file,
        book_props = book_props,
        annotations = annotations,
    }
end

local function buildStatusPillsRow(ctx, item, merged_prog, inner_w, closeDlg, opts)
    local is_in_cloud = item.is_in_cloud or (item.folder ~= nil)
    local has_local_ds = (ctx and ctx.DocSettings ~= nil)
    if not has_local_ds and not is_in_cloud then return nil end

    local current_status
    if has_local_ds and ctx.been_opened and type(ctx.doc_settings_or_file) == "table" and ctx.doc_settings_or_file.readSetting then
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
                if has_local_ds then
                    local ds = ctx.DocSettings:open(ctx.file)
                    local summary = ds:readSetting("summary") or {}
                    summary.status = st.id
                    ds:saveSetting("summary", summary)
                    if st.id == "complete" then
                        local cur_p = ds:readSetting("percent_finished") or 0
                        if cur_p < 0.99 then ds:saveSetting("percent_finished", 1) end
                    end
                    ds:flush()
                    if ctx.BookList and ctx.BookList.setBookInfoCacheProperty then
                        ctx.BookList.setBookInfoCacheProperty(ctx.file, "status", st.id)
                    end
                end
                local cloud_status = (st.id == "complete") and "finished" or st.id
                item.status = cloud_status
                if merged_prog then
                    merged_prog.status = cloud_status
                    if cloud_status == "finished" and (tonumber(merged_prog.percent) or 0) < 0.99 then
                        merged_prog.percent = 1
                    end
                end
                local cid = item.cloud_id or (is_in_cloud and item.id) or nil
                if cid and Cloud.isConfigured() then
                    local cfg = Settings.load()
                    local local_st = Sync.loadLocalState()
                    local cur_rec = local_st.progress[cid] or {}
                    local cur_pct = tonumber(cur_rec.percent) or (merged_prog and tonumber(merged_prog.percent)) or tonumber(item.percent) or 0
                    if cloud_status == "finished" and cur_pct < 0.99 then cur_pct = 1 end
                    local updated_rec = {
                        book_id = cid,
                        partial_md5 = (item.hashes and item.hashes.partial_md5) or item.partial_md5 or cur_rec.partial_md5,
                        percent = cur_pct,
                        status = cloud_status,
                        xpointer = cur_rec.xpointer or (merged_prog and merged_prog.xpointer),
                        updated_at = os.time(),
                        device_id = cfg.device_id,
                    }
                    local_st.progress[cid] = updated_rec
                    Sync.saveLocalState(local_st)
                    local cached_cat, cached_mp = Sync.loadCachedCatalog()
                    cached_mp = cached_mp or {}
                    cached_mp[cid] = updated_rec
                    Sync.saveCachedCatalog(cached_cat, cached_mp)
                    local upload_prog = local_st.progress
                    Sync.runInBackground(function()
                        Sync.uploadDeviceProgress(upload_prog)
                    end, nil, { priority = "interactive_bg" })
                end
                closeDlg()
                if opts.on_progress_changed then
                    opts.on_progress_changed(cid, cloud_status)
                elseif opts.on_refresh then
                    opts.on_refresh()
                end
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

local function addNativeAction(actions, btn, closeDlg)
    if not btn or btn.enabled == false or not btn.text or not btn.callback then return end
    table.insert(actions, {
        text = btn.text,
        callback = function()
            if closeDlg then closeDlg() end
            btn.callback()
        end,
    })
end

local function buildClipboardButtonsRow(ctx, item, inner_w, closeDlg, opts)
    local local_path = item.local_path
    local fm = ctx and ctx.fm
    local can_select = type(opts.on_start_select) == "function"
    local can_cut_copy = (local_path ~= nil and fm ~= nil)
    local can_paste = (fm ~= nil and fm.clipboard ~= nil and fm.pasteFileFromClipboard ~= nil
        and (local_path ~= nil or (opts.current_folder ~= nil and opts.current_folder ~= "")))
    if not (can_select or can_cut_copy or can_paste) then
        return nil
    end

    local specs = {
        {
            text = ko_gettext("Select"),
            enabled = can_select,
            callback = function()
                closeDlg()
                if opts.on_start_select then opts.on_start_select(item) end
            end,
        },
        {
            text = ko_gettext("Cut"),
            enabled = can_cut_copy and fm.cutFile ~= nil,
            callback = function()
                closeDlg()
                fm:cutFile(local_path)
                Widgets.showToast(_("Cut book to clipboard."), 2)
            end,
        },
        {
            text = ko_gettext("Copy"),
            enabled = can_cut_copy and fm.copyFile ~= nil,
            callback = function()
                closeDlg()
                fm:copyFile(local_path)
                Widgets.showToast(_("Copied book to clipboard."), 2)
            end,
        },
        {
            text = ko_gettext("Paste"),
            enabled = can_paste,
            callback = function()
                closeDlg()
                fm:pasteFileFromClipboard(opts.current_folder or local_path)
                if opts.on_refresh then opts.on_refresh(true) end
            end,
        },
    }

    local gap = sc(6)
    local n = #specs
    local btn_w = math.floor((inner_w - (gap * (n - 1))) / n)
    local row_items = { align = "center" }
    local used_w = 0
    for idx, sp in ipairs(specs) do
        if idx > 1 then
            table.insert(row_items, HorizontalSpan:new{ width = gap })
            used_w = used_w + gap
        end
        local w = (idx == n) and math.max(sc(40), inner_w - used_w) or btn_w
        used_w = used_w + w
        table.insert(row_items, Widgets.createButton{
            text = sp.text,
            enabled = sp.enabled,
            width = w,
            padding = sc(6),
            padding_h = sc(3),
            text_font_size = theme.fs and theme.fs("detail") or 14,
            callback = sp.callback,
        })
    end
    return HorizontalGroup:new(row_items)
end

local function showMoreBookActionsMenu(item, merged_prog, opts, ctx)
    local local_path = item.local_path
    local is_in_cloud = item.is_in_cloud or (item.folder ~= nil)
    local page = 1

    local function renderMorePage()
        local total_pages = 1
        local prev_page_fn = function()
            if page > 1 then
                page = page - 1
                renderMorePage()
                return true
            end
        end
        local next_page_fn = function()
            if page < total_pages then
                page = page + 1
                renderMorePage()
                return true
            end
        end

        Widgets.showCardDialog{
            title = tostring(item.title or _("Book Actions")),
            on_prev_page = prev_page_fn,
            on_next_page = next_page_fn,
            body_widget = function(inner_w, closeDlg)
                local actions = {}
                local noop = function() end
                local refresh_cb = function(force)
                    if opts.on_refresh then opts.on_refresh(force) end
                end
                local force_refresh_cb = function()
                    refresh_cb(true)
                end
                local close_and_refresh = function()
                    closeDlg()
                    refresh_cb(true)
                end

                if local_path and ctx and ctx.fm and ctx.filemanagerutil then
                    if ctx.has_provider then
                        addNativeAction(actions, ctx.filemanagerutil.genBookCoverButton(local_path, ctx.book_props, noop), closeDlg)
                        addNativeAction(actions, ctx.filemanagerutil.genBookDescriptionButton(local_path, ctx.book_props, noop), closeDlg)
                    end
                    if ctx.fm.showOpenWithDialog then
                        table.insert(actions, {
                            text = ko_gettext("Open with…"),
                            callback = function()
                                closeDlg()
                                ctx.fm:showOpenWithDialog(local_path)
                            end,
                        })
                    end
                    if opts.on_show_folder then
                        table.insert(actions, {
                            text = ko_gettext("Show folder"),
                            callback = function()
                                closeDlg()
                                opts.on_show_folder(local_path)
                            end,
                        })
                    elseif ctx.filemanagerutil.genShowFolderButton then
                        addNativeAction(actions, ctx.filemanagerutil.genShowFolderButton(local_path, noop), closeDlg)
                    end
                    if ctx.has_provider or ctx.been_opened then
                        addNativeAction(actions, ctx.filemanagerutil.genResetSettingsButton(ctx.doc_settings_or_file, force_refresh_cb), closeDlg)
                    end
                    if ctx.Converter and ctx.Converter.isSupported and ctx.Converter:isSupported(local_path) then
                        addNativeAction(actions, ctx.Converter:genConvertButton(local_path, noop, force_refresh_cb), closeDlg)
                    end
                    if ctx.annotations and #ctx.annotations > 0 and ctx.fm.collections and ctx.fm.collections.genExportHighlightsButton then
                        addNativeAction(actions, ctx.fm.collections:genExportHighlightsButton({ [local_path] = true }, noop), closeDlg)
                    end
                    if ctx.Device and ctx.Device.canExecuteScript and ctx.Device:canExecuteScript(local_path) then
                        addNativeAction(actions, ctx.filemanagerutil.genExecuteScriptButton(local_path, noop), closeDlg)
                    end
                    if ctx.fm.file_dialog_added_buttons then
                        for _, row_func in ipairs(ctx.fm.file_dialog_added_buttons) do
                            local ok_r, row = pcall(row_func, local_path, true, ctx.book_props, close_and_refresh)
                            if ok_r and type(row) == "table" then
                                for _, btn in ipairs(row) do
                                    addNativeAction(actions, btn, closeDlg)
                                end
                            end
                        end
                    end
                    if ctx.fm.showRenameFileDialog then
                        table.insert(actions, {
                            text = ko_gettext("Rename"),
                            callback = function()
                                closeDlg()
                                ctx.fm:showRenameFileDialog(local_path, true)
                            end,
                        })
                    end
                    if ctx.fm.showDeleteFileDialog then
                        table.insert(actions, {
                            text = ko_gettext("Delete"),
                            callback = function()
                                closeDlg()
                                ctx.fm:showDeleteFileDialog(local_path, force_refresh_cb)
                            end,
                        })
                    end
                end

                table.insert(actions, {
                    text = _("Book Details"),
                    callback = function()
                        closeDlg()
                        BookCardMixin.showBookDetailModal(item, merged_prog, opts)
                    end,
                })

                if is_in_cloud then
                    table.insert(actions, {
                        text = _("Delete from Cloud"),
                        callback = function()
                            closeDlg()
                            promptDeleteFromCloud(item, opts)
                        end,
                    })
                end

                local grid_rows = Widgets.buildActionGridRows(actions, 2)
                local sh = (ctx and ctx.Device and ctx.Device.screen and ctx.Device.screen.getHeight and ctx.Device.screen:getHeight()) or 800
                local max_rows = math.max(4, math.floor((sh - sc(210)) / sc(46)))
                total_pages = math.max(1, math.ceil(#grid_rows / max_rows))
                if page > total_pages then page = total_pages end

                local start_r = (page - 1) * max_rows + 1
                local end_r = math.min(#grid_rows, start_r + max_rows - 1)
                local page_rows = {}
                for i = start_r, end_r do
                    table.insert(page_rows, grid_rows[i])
                end

                local grid_w = Widgets.createActionGrid(page_rows, inner_w, {
                    is_grouped = true,
                    cols = 2,
                    gap = sc(8),
                    gap_v = sc(8),
                    padding = sc(7),
                    padding_h = sc(6),
                })

                if total_pages <= 1 then
                    return grid_w
                end

                local prev_btn = Widgets.createButton{
                    text = _("‹ Prev"),
                    enabled = page > 1,
                    padding = sc(4),
                    padding_h = sc(10),
                    text_font_size = theme.fs and theme.fs("detail") or 14,
                    callback = function()
                        closeDlg()
                        page = page - 1
                        renderMorePage()
                    end,
                }
                local next_btn = Widgets.createButton{
                    text = _("Next ›"),
                    enabled = page < total_pages,
                    padding = sc(4),
                    padding_h = sc(10),
                    text_font_size = theme.fs and theme.fs("detail") or 14,
                    callback = function()
                        closeDlg()
                        page = page + 1
                        renderMorePage()
                    end,
                }
                local page_lbl = TextWidget:new{
                    text = string.format("%d / %d", page, total_pages),
                    face = Font:getFace("cfont", theme.fs and theme.fs("detail") or 14),
                    fgcolor = theme.color_label_dim,
                }
                local spacer_w = math.max(sc(8), math.floor((inner_w - prev_btn:getSize().w - next_btn:getSize().w - page_lbl:getSize().w) / 2))
                return VerticalGroup:new{
                    align = "left",
                    grid_w,
                    VerticalSpan:new{ width = sc(10) },
                    HorizontalGroup:new{
                        align = "center",
                        prev_btn,
                        HorizontalSpan:new{ width = spacer_w },
                        page_lbl,
                        HorizontalSpan:new{ width = spacer_w },
                        next_btn,
                    },
                }
            end,
            buttons = { { text = _("Close") } },
        }
    end

    renderMorePage()
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
                local dl_opts = {}
                for k, v in pairs(opts) do dl_opts[k] = v end
                dl_opts.merged_prog = merged_prog
                table.insert(rows, Widgets.createMenuRow(_("Download & Open"), chevron(), inner_w, function()
                    closeDlg()
                    BookCardMixin.downloadBook(item, true, dl_opts)
                end))
                table.insert(rows, Widgets.createMenuRow(_("Download"), chevron(), inner_w, function()
                    closeDlg()
                    BookCardMixin.downloadBook(item, false, dl_opts)
                end))
            end

            if local_path and ctx and ctx.fm and ctx.filemanagerutil then
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
            local clip_row = buildClipboardButtonsRow(ctx, item, inner_w, closeDlg, opts)
            if status_row or clip_row then
                local vg = VerticalGroup:new{ align = "left" }
                if status_row then
                    table.insert(vg, status_row)
                    table.insert(vg, VerticalSpan:new{ width = sc(8) })
                end
                if clip_row then
                    table.insert(vg, clip_row)
                    table.insert(vg, VerticalSpan:new{ width = sc(10) })
                end
                table.insert(vg, menu_list)
                return vg
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
        local dl_opts = {}
        for k, v in pairs(opts) do dl_opts[k] = v end
        dl_opts.merged_prog = merged_prog
        table.insert(buttons, {
            text = _("Read"),
            is_primary = true,
            callback = function()
                BookCardMixin.downloadBook(item, true, dl_opts)
            end,
        })
        table.insert(buttons, {
            text = _("Download"),
            callback = function()
                BookCardMixin.downloadBook(item, false, dl_opts)
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
