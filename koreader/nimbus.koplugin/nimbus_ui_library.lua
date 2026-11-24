--[[--
nimbus_ui_library.lua
Full-screen Option A (Kindle-style) Library Shelf & Embeddable FileManager Home Screen.
Composes nimbus_ui_book_card.lua and nimbus_ui_upload.lua via Widgets.applyMixin.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
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
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local ok_loc, Localization = pcall(require, "localization_nimbus")
local _ = (ok_loc and Localization and Localization.getHelper) and Localization:getHelper() or require("gettext")

local Settings = require("nimbus_settings")
local Cloud = require("nimbus_cloud")
local Sync = require("nimbus_sync")
local Merge = require("nimbus_merge")
local Scanner = require("nimbus_scanner")
local Covers = require("nimbus_covers")
local NimbusProgress = require("nimbus_progress")
local Widgets = require("nimbus_ui_widgets")
local theme = require("nimbus_theme")
local UISettings = require("nimbus_ui_settings")

local UILibrary = {}
Widgets.applyMixin(UILibrary, require("nimbus_ui_book_card"))
Widgets.applyMixin(UILibrary, require("nimbus_ui_upload"))
Widgets.applyMixin(UILibrary, require("nimbus_ui_select"))

local sc = theme.sc
local active_shelf_overlay = nil

local FILTER_LABELS = {
    all = _("All Books"),
    reading = _("Currently Reading"),
    finished = _("Finished"),
    device = _("Downloaded"),
    cloud = _("Cloud Only"),
}

function UILibrary.formatActiveJobStatus(active_job)
    if not active_job then return nil end
    if active_job.kind == "sync" then
        return string.format(_("· Syncing (%d%%)..."), active_job.pct or 0)
    elseif active_job.kind == "download" then
        return string.format(_("· Downloading (%d%%)..."), active_job.pct or 0)
    end
    return string.format(_("· Uploading (%d/%d)..."), active_job.current or 1, active_job.total or 1)
end

local function fileExists(path)
    if not path then return false end
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

local function openKOReaderTopMenu(embedded_fm)
    if embedded_fm and embedded_fm.menu and embedded_fm.menu.onTapShowMenu then
        embedded_fm.menu:onTapShowMenu()
        return true
    end
    local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
    local inst = ok_fm and FM and FM.instance
    if inst and inst.menu and inst.menu.onTapShowMenu then
        inst.menu:onTapShowMenu()
        return true
    end
    return false
end

local function getLocalCloudBookPath(entry, device_by_cloud_id, links, download_dir)
    local b = device_by_cloud_id and device_by_cloud_id[entry.id]
    if b and b.local_path then
        return b.local_path, b.all_local_paths, b
    end
    local linked = links and links.by_id and links.by_id[entry.id]
    if linked and fileExists(linked) then
        return linked, { linked }, nil
    end
    local candidate = (download_dir or "") .. "/" .. (entry.filename or (entry.id .. "." .. (entry.format or "epub")))
    if candidate ~= "/" and fileExists(candidate) then
        return candidate, { candidate }, nil
    end
    return nil, nil, nil
end

local function showSearchDialog(search_query, on_apply_query)
    Widgets.showInputDialog{
        title = _("Search Library"),
        description = _("Filter books by title, author, or series:"),
        input = search_query or "",
        hint = _("Enter search term..."),
        buttons = {
            {
                text = _("Clear"),
                callback = function()
                    on_apply_query("")
                end,
            },
            {
                text = _("Search"),
                is_primary = true,
                callback = function(val)
                    on_apply_query((val or ""):gsub("^%s+", ""):gsub("%s+$", ""))
                end,
            },
        },
        on_submit = function(val)
            on_apply_query((val or ""):gsub("^%s+", ""):gsub("%s+$", ""))
        end,
    }
end

local function showFilterDialog(current_filter, on_apply)
    Widgets.showCardDialog{
        title = _("Filter Books"),
        body_widget = function(inner_w, closeDlg)
            local vg = VerticalGroup:new{ align = "left" }
            local opts_list = {
                { "all", FILTER_LABELS.all },
                { "reading", FILTER_LABELS.reading },
                { "finished", FILTER_LABELS.finished },
                { "device", FILTER_LABELS.device },
                { "cloud", FILTER_LABELS.cloud },
            }
            for _, opt in ipairs(opts_list) do
                local fid, flabel = opt[1], opt[2]
                table.insert(vg, Widgets.createRadioRow(flabel, nil, current_filter == fid, inner_w, function()
                    closeDlg()
                    on_apply(fid)
                end))
            end
            return vg
        end,
        buttons = { { text = _("Close") } },
    }
end

function UILibrary.close()
    if active_shelf_overlay then
        local ov = active_shelf_overlay
        active_shelf_overlay = nil
        ov.onClose = nil
        UIManager:close(ov, "ui")
    end
end

--- Returns true when Nimbus's library overlay or embedded home screen is actively in the foreground.
function UILibrary.isOpen()
    if active_shelf_overlay ~= nil then
        return true
    end
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    local fm = ok_fm and FileManager and FileManager.instance
    if fm and fm._nimbus_embedded_view and not fm._nimbus_browsing_files then
        local ok_ru, ReaderUI = pcall(require, "apps/reader/readerui")
        local reader_active = ok_ru and ReaderUI and ReaderUI.instance ~= nil
        if not reader_active then
            return true
        end
    end
    return false
end

--- Builds an embeddable or overlay-hosted Nimbus shelf container.
function UILibrary.buildView(on_open_book, opts)
    opts = opts or {}
    local embedded_fm = opts.embedded_fm
    local is_home = (opts.is_home_screen == true) or (embedded_fm ~= nil)
    local sw, sh = theme.resolveHomeViewport(opts, is_home)

    local current_page = 1
    local total_pages = 1
    local current_folder = nil
    local current_cloud_dir = ""
    local shelf_cache = {
        folder_page_stack = { device = {}, cloud = {} },
        cloud_books = {},
        folder_info = nil,
        display_books = {},
        data_dirty = true,
    }
    local search_query = ""
    local select_state = { active = false, map = {} }
    local catalog_data, merged_progress, catalog_saved_at = Sync.loadCachedCatalog()
    if Sync.deduplicateCatalog and Sync.deduplicateCatalog(catalog_data) > 0 then
        Sync.saveCachedCatalog(catalog_data, merged_progress)
    end
    function shelf_cache.mergeLocalProgressIntoMerged()
        local local_st = Sync.loadLocalState()
        if type(local_st) == "table" and type(local_st.progress) == "table" then
            merged_progress = merged_progress or {}
            for cid, rec in pairs(local_st.progress) do
                if type(rec) == "table" then
                    local cur = merged_progress[cid]
                    local r_ts = tonumber(rec.updated_at) or 0
                    local c_ts = cur and (tonumber(cur.updated_at) or 0) or 0
                    local r_pct = tonumber(rec.percent) or 0
                    local c_pct = cur and (tonumber(cur.percent) or 0) or 0
                    if not cur or r_ts > c_ts or (r_ts == c_ts and r_pct > c_pct) then
                        merged_progress[cid] = rec
                    end
                end
            end
        end
    end
    shelf_cache.mergeLocalProgressIntoMerged()

    local device_books = {}
    local sync_error = nil
    local bg_syncing = false
    local is_destroyed = false
    local render_gen = 0

    local BaseContainer = (ok_fm and FocusManager) or InputContainer
    local host_container = BaseContainer:new{
        dimen = Geom:new{ w = sw, h = sh },
        layout = {},
    }
    if BaseContainer == FocusManager then
        Widgets.installLazyFocus(host_container)
    end

    local function isAlive()
        if is_destroyed then return false end
        if embedded_fm then
            return embedded_fm[1] ~= nil and not embedded_fm._nimbus_browsing_files
        end
        return active_shelf_overlay ~= nil
    end

    local function dirtyHost()
        local target = embedded_fm or active_shelf_overlay
        if target then
            UIManager:setDirty(target, "ui")
        elseif isAlive() then
            UIManager:setDirty("all", "ui")
        end
    end

    local function refreshLocalBooks(force_rescan)
        if force_rescan then
            device_books = Scanner.scanLocalBooks(catalog_data, opts.open_doc_info)
        else
            device_books = Scanner.getCachedLocalBooks(catalog_data, opts.open_doc_info)
        end
        if not Cloud.isConfigured() then
            for _, b in ipairs(device_books) do
                b.is_in_cloud = false
            end
        end
        shelf_cache.data_dirty = true
    end

    local renderShelf

    local function fetchCloudSilently(force)
        if not Cloud.isConfigured() then return end
        if bg_syncing and not force then return end
        bg_syncing = false
        local started = Sync.startBackgroundCatalogSync(function(ok, info)
            bg_syncing = false
            if ok then
                catalog_data, merged_progress = Sync.loadCachedCatalog()
                shelf_cache.mergeLocalProgressIntoMerged()
                sync_error = nil
                local dl_n = tonumber(info) or 0
                refreshLocalBooks(dl_n > 0)
                if dl_n > 0 and isAlive() then
                    Widgets.showToast(string.format(_("Downloaded %d new book(s) from Nimbus Cloud."), dl_n), 3)
                end
            elseif info == "low_memory" or info == "suspended" or info == "canceled" then
                sync_error = nil
            else
                sync_error = tostring(info or "sync_error")
            end
            if isAlive() and renderShelf then renderShelf() end
        end, force)
        if started then
            bg_syncing = true
            if isAlive() and renderShelf then renderShelf() end
        end
    end

    local function fetchCloudWithBar(run_extra_sync, post_toast_msg)
        if not Cloud.isConfigured() then
            catalog_data = { books = {} }
            merged_progress = {}
            sync_error = nil
            refreshLocalBooks()
            if isAlive() then renderShelf() end
            if post_toast_msg then Widgets.showToast(post_toast_msg, 3) end
            return
        end

        local existing_job = NimbusProgress.getActiveJob()
        if existing_job then
            if existing_job.reopen then existing_job.reopen() end
            return
        end

        local active_cancel_fn = nil
        local finished = false
        local is_canceled = false
        local prog_dlg
        local provider_label = Cloud.getProviderLabel(Settings.load().provider)

        local job = {
            kind = "sync",
            pct = 5,
            subtitle = _("Connecting to cloud storage..."),
            detail = provider_label,
            is_background = false,
        }
        NimbusProgress.setActiveJob(job)

        local function cleanupAndClose()
            if prog_dlg and not prog_dlg.is_closed then
                prog_dlg:close()
            end
            NimbusProgress.clearActiveJob(job)
        end

        local function cancelSync()
            if finished then return end
            finished = true
            is_canceled = true
            if active_cancel_fn then
                local c_fn = active_cancel_fn
                active_cancel_fn = nil
                pcall(c_fn)
            end
            cleanupAndClose()
            Widgets.showToast(_("Sync canceled."), 2)
        end

        local function openProgressDialog()
            if finished then return end
            if prog_dlg and not prog_dlg.is_closed then return end
            job.is_background = false
            prog_dlg = NimbusProgress:new{
                title = _("Syncing Library"),
                subtitle = job.subtitle,
                detail = job.detail,
                progress = job.pct,
                background_text = _("Background"),
                on_background = function()
                    if finished then return end
                    job.is_background = true
                    NimbusProgress.notifyStatus(false)
                    Widgets.showToast(_("Syncing library in background..."), 2.5)
                end,
                on_cancel = cancelSync,
            }
            prog_dlg:show()
            NimbusProgress.notifyStatus(false)
        end

        job.reopen = openProgressDialog
        job.cancel = cancelSync

        openProgressDialog()

        local function updateJobProgress(pct, subtitle, detail)
            if pct ~= nil then job.pct = pct end
            if subtitle ~= nil then job.subtitle = subtitle end
            if detail ~= nil then job.detail = detail end
            if prog_dlg and not prog_dlg.is_closed then
                prog_dlg:setProgress(job.pct, job.subtitle, job.detail)
            end
            if job.is_background then
                NimbusProgress.notifyStatus(true)
            end
        end

        local open_doc_meta = opts.open_doc_info and {
            filepath = opts.open_doc_info.filepath,
            props = opts.open_doc_info.props,
        } or nil

        local function startBackgroundSync()
            if finished or is_canceled then return end
            local _started, cancel_fn = Sync.runInBackground(function(report_progress)
                if report_progress then report_progress(25, _("Scanning local books..."), provider_label) end
                local local_snapshot = Scanner.scanLocalBooks(nil, open_doc_meta)

                if report_progress then report_progress(40, _("Loading library catalog..."), provider_label) end
                local ok_cat, cat_or_err = false, nil
                Sync.loadCatalog(function(ok, res)
                    ok_cat = ok
                    cat_or_err = res
                end)
                if not ok_cat or type(cat_or_err) ~= "table" then
                    return { ok = false, err = tostring(cat_or_err or "sync_error") }
                end
                -- Re-scan/re-link cached local books against the fresh catalog
                local_snapshot = Scanner.getCachedLocalBooks(cat_or_err, open_doc_meta)
                if Covers and Covers.pruneStaleCovers then
                    pcall(Covers.pruneStaleCovers, cat_or_err.books)
                end

                if run_extra_sync and Sync.syncStats then
                    if report_progress then report_progress(55, _("Syncing reading stats..."), provider_label) end
                    pcall(Sync.syncStats, nil, cat_or_err)
                end

                if report_progress then report_progress(70, _("Merging reading progress..."), provider_label) end
                local merged = {}
                Sync.fetchAllDeviceShards("progress.json", function(ok_p, shards)
                    if ok_p then
                        merged = Merge.mergeProgress(shards)
                    end
                end)

                merged = Sync.collectAndUploadLocalProgress(cat_or_err, local_snapshot, merged)
                if Sync.reuploadFixedCovers then
                    pcall(Sync.reuploadFixedCovers, cat_or_err, local_snapshot, function(idx, total)
                        if report_progress then
                            local p = math.min(96, 82 + math.floor((idx / math.max(1, total)) * 14))
                            report_progress(p, string.format(_("Upgrading cloud covers (%d/%d)..."), idx, total), provider_label)
                        end
                    end)
                end
                if Sync.backfillRelativeDirs(cat_or_err, local_snapshot) then
                    Sync.saveCatalog(cat_or_err, function() end)
                end
                Sync.saveCachedCatalog(cat_or_err, merged)
                if Sync.cleanupCloudBookFolders then
                    pcall(Sync.cleanupCloudBookFolders, cat_or_err)
                end
                if report_progress then report_progress(100, _("Sync complete"), provider_label) end
                return { ok = true }
            end, function(ok_bg, res)
                active_cancel_fn = nil
                if finished or is_canceled then return end
                finished = true
                cleanupAndClose()
                if ok_bg and type(res) == "table" and res.ok then
                    catalog_data, merged_progress = Sync.loadCachedCatalog()
                    shelf_cache.mergeLocalProgressIntoMerged()
                    sync_error = nil
                    refreshLocalBooks(false)
                else
                    sync_error = tostring((type(res) == "table" and res.err) or res or "sync_error")
                end
                if isAlive() then renderShelf() end
                if post_toast_msg then
                    Widgets.showToast(post_toast_msg, 3)
                elseif sync_error then
                    Widgets.showToast(_("Sync failed: ") .. tostring(sync_error), 3.5)
                end
            end, {
                user_initiated = true,
                priority = "foreground",
                task = "sync_library",
                lease_s = 90,
                on_progress = function(pct, sub, det)
                    if not finished and not is_canceled then
                        updateJobProgress(pct, sub, det)
                    end
                end,
            })
            active_cancel_fn = cancel_fn
        end

        UIManager:nextTick(function()
            if finished or is_canceled then return end
            if run_extra_sync and opts.on_sync_now then
                updateJobProgress(15, _("Syncing device progress..."))
                UIManager:nextTick(function()
                    if finished or is_canceled then return end
                    opts.on_sync_now()
                    startBackgroundSync()
                end)
            else
                startBackgroundSync()
            end
        end)
    end

    function shelf_cache.rebuildDisplayData()
        local cfg = Settings.load()
        local active_tab = cfg.library_active_tab or "device"
        local current_filter = cfg.library_filter or "all"
        local q_lower = tostring(search_query or ""):lower()
        local links = Settings.loadBookLinks()
        local download_dir = cfg.download_dir

        local device_by_cloud_id = {}
        for _, b in ipairs(device_books or {}) do
            if b.cloud_id and b.local_path and not device_by_cloud_id[b.cloud_id] then
                device_by_cloud_id[b.cloud_id] = b
            end
        end

        -- Build Cloud list in O(N)
        shelf_cache.cloud_books = {}
        for _, entry in pairs((catalog_data and catalog_data.books) or {}) do
            if not entry.deleted then
                local lp, all_lp, dev_b = getLocalCloudBookPath(entry, device_by_cloud_id, links, download_dir)
                local copy = {}
                for k, v in pairs(entry) do copy[k] = v end
                copy.local_path = lp
                copy.all_local_paths = all_lp
                copy.is_in_cloud = true
                copy.cloud_id = entry.id
                if dev_b then
                    if not copy.percent or copy.percent == 0 then copy.percent = dev_b.percent end
                    if not copy.status or copy.status == "unread" then copy.status = dev_b.status end
                    if not copy.last_read_ts then copy.last_read_ts = dev_b.last_read_ts end
                end
                if (not copy.relative_dir or copy.relative_dir == "") and lp then
                    copy.relative_dir = Scanner.getRelativeDir(lp)
                end
                table.insert(shelf_cache.cloud_books, copy)
            end
        end

        shelf_cache.folder_info = nil
        shelf_cache.display_books = {}
        local use_folders = (q_lower == "" and current_filter == "all")

        if use_folders then
            if active_tab == "device" then
                shelf_cache.folder_info = Scanner.listFolderContents(current_folder, device_books, nil, merged_progress)
                current_folder = shelf_cache.folder_info.current_dir
            else
                shelf_cache.folder_info = Scanner.listCloudFolderContents(current_cloud_dir, shelf_cache.cloud_books, merged_progress)
                current_cloud_dir = shelf_cache.folder_info.current_dir
            end
            for _, entry in ipairs(shelf_cache.folder_info.items or {}) do
                table.insert(shelf_cache.display_books, entry)
            end
        else
            local source_list = (active_tab == "device") and device_books or shelf_cache.cloud_books
            for _, item in ipairs(source_list) do
                local prog = merged_progress[item.cloud_id or item.id]
                local status = (prog and prog.status) or item.status or "unread"
                local pass_filter = (current_filter == "all")
                    or (current_filter == "device" and item.local_path ~= nil)
                    or (current_filter == "cloud" and item.local_path == nil)
                    or (current_filter == "reading" and status == "reading")
                    or (current_filter == "finished" and (status == "finished" or status == "complete"))

                local authors_str = type(item.authors) == "table" and table.concat(item.authors, ", ") or tostring(item.authors or "")
                local hay = (tostring(item.title or "") .. " " .. authors_str .. " " .. tostring(item.series or "")):lower()
                local pass_search = (q_lower == "") or hay:find(q_lower, 1, true) ~= nil
                if pass_filter and pass_search then
                    table.insert(shelf_cache.display_books, item)
                end
            end

            Scanner.sortItems(shelf_cache.display_books, merged_progress)
        end
        shelf_cache.data_dirty = false
    end

    renderShelf = function()
        if not isAlive() then return end
        render_gen = render_gen + 1
        local my_gen = render_gen
        Covers.clearFetchQueue()
        if Covers.beginRenderPass then Covers.beginRenderPass() end
        sw, sh = theme.resolveHomeViewport(opts, is_home)
        if host_container.dimen then
            host_container.dimen.w = sw
            host_container.dimen.h = sh
        end
        if shelf_cache.data_dirty then
            shelf_cache.rebuildDisplayData()
        end
        local cfg = Settings.load()
        local active_tab = cfg.library_active_tab or "device"
        local view_mode = cfg.library_view_mode or "cover"
        local current_filter = cfg.library_filter or "all"
        local configured = Cloud.isConfigured()
        local q_lower = tostring(search_query or ""):lower()
        local use_folders = (q_lower == "" and current_filter == "all")
        local cloud_books = shelf_cache.cloud_books
        local folder_info = shelf_cache.folder_info
        local display_books = shelf_cache.display_books

        local function showMoreMenu()
            Widgets.showCardDialog{
                title = is_home and _("Library Menu") or _("Nimbus Menu"),
                body_widget = function(inner_w, closeDlg)
                    local chevron = function()
                        return TextWidget:new{ text = "›", face = Font:getFace("cfont", 18), fgcolor = theme.color_label_dim }
                    end
                    local rows = {
                        Widgets.createMenuRow(_("Upload Books..."), chevron(), inner_w, function()
                            closeDlg()
                            UILibrary.showUploadDialog(device_books, opts.open_doc_info, function(uploaded, _, toast_msg)
                                if uploaded then
                                    catalog_data, merged_progress = Sync.loadCachedCatalog()
                                    refreshLocalBooks(false)
                                    if isAlive() then renderShelf() end
                                end
                                if toast_msg then
                                    Widgets.showToast(toast_msg, 3)
                                end
                            end)
                        end),
                        Widgets.createMenuRow(_("Sync Now"), chevron(), inner_w, function()
                            closeDlg()
                            fetchCloudWithBar(true)
                        end),
                        Widgets.createMenuRow(_("Nimbus Settings..."), chevron(), inner_w, function()
                            closeDlg()
                            local before_cfg = Settings.load()
                            local prev_root = before_cfg.remote_root or ""
                            local prev_prov = before_cfg.provider or ""
                            local prev_conn = Cloud.isConfigured()
                            local prev_dl = before_cfg.download_dir or ""
                            local prev_scan = table.concat(before_cfg.scan_dirs or {}, "\0")
                            UISettings.showSettingsDialog(function()
                                local after_cfg = Settings.load()
                                local now_conn = Cloud.isConfigured()
                                local local_dirs_changed = (after_cfg.download_dir or "") ~= prev_dl
                                    or table.concat(after_cfg.scan_dirs or {}, "\0") ~= prev_scan
                                local cloud_changed = (after_cfg.remote_root or "") ~= prev_root
                                    or (after_cfg.provider or "") ~= prev_prov
                                    or now_conn ~= prev_conn
                                if cloud_changed then
                                    catalog_data = { books = {} }
                                    merged_progress = {}
                                    sync_error = nil
                                    current_cloud_dir = ""
                                    shelf_cache.folder_page_stack.cloud = {}
                                end
                                shelf_cache.data_dirty = true
                                refreshLocalBooks(local_dirs_changed)
                                if isAlive() then renderShelf() end
                                if cloud_changed and now_conn then
                                    fetchCloudSilently(true)
                                end
                            end)
                        end),
                    }
                    if is_home then
                        table.insert(rows, Widgets.createMenuRow(_("Open File Browser"), chevron(), inner_w, function()
                            closeDlg()
                            if embedded_fm and embedded_fm._nimbus_orig_fc then
                                local slot = (embedded_fm._navbar_inner and embedded_fm._navbar_inner[1])
                                    and embedded_fm._navbar_inner or embedded_fm[1]
                                embedded_fm._nimbus_browsing_files = true
                                slot[1] = embedded_fm._nimbus_orig_fc
                                embedded_fm.layout = embedded_fm._nimbus_orig_fc.layout
                                UIManager:setDirty(embedded_fm, "ui")
                            else
                                UILibrary.close()
                            end
                        end))
                    end
                    return Widgets.createMenuList(rows, inner_w)
                end,
                buttons = { { text = _("Close") } },
            }
        end

        -- Option A Header with deterministic OverlapGroup (LeftContainer / CenterContainer / RightContainer)
        local is_sui = theme.isSimpleUIActive and theme.isSimpleUIActive()
        local icon_sz = theme.icon and theme.icon(24) or sc(24)
        local icon_pad = sc(5)
        local left_btn = is_home
            and Widgets.createIconButton{
                icon = "menu.svg",
                size = icon_sz,
                padding = icon_pad,
                callback = function()
                    openKOReaderTopMenu(embedded_fm)
                end,
            }
            or ImageWidget:new{
                file = Widgets.getAssetPath("cloud-lightning.svg"),
                width = sc(26),
                height = sc(26),
                scale_factor = 0,
                is_icon = true,
                alpha = true,
            }

        local right_buttons = {
            Widgets.createIconButton{
                icon = "more-vertical.svg",
                size = icon_sz,
                padding = icon_pad,
                callback = showMoreMenu,
            },
        }
        if not is_home then
            table.insert(right_buttons, HorizontalSpan:new{ width = sc(4) })
            table.insert(right_buttons, Widgets.createIconButton{
                icon = "x.svg",
                size = icon_sz,
                padding = icon_pad,
                callback = function()
                    UILibrary.close()
                end,
            })
        end
        local right_group = HorizontalGroup:new(right_buttons)

        local header_pad_h = sc(10)
        local header_inner_w = sw - (header_pad_h * 2)
        local left_w = left_btn:getSize().w
        local right_w = right_group:getSize().w
        local gap_w = sc(10)
        local side_reserve = math.max(left_w, right_w)
        local search_bar_w = math.max(sc(140), header_inner_w - (side_reserve * 2) - (gap_w * 2))

        local search_icon_sz = theme.icon and theme.icon(16) or sc(16)
        local search_icon = ImageWidget:new{
            file = Widgets.getAssetPath("search.svg"),
            width = search_icon_sz,
            height = search_icon_sz,
            scale_factor = 0,
            is_icon = true,
            alpha = true,
        }
        local has_query = (q_lower ~= "")
        local clear_btn_w = has_query and (search_icon_sz + sc(8)) or 0
        local search_inner_w = search_bar_w - sc(20)
        local search_text_w = math.max(sc(60), search_inner_w - search_icon_sz - sc(8) - clear_btn_w)
        local search_label = TextWidget:new{
            text = has_query and search_query or _("Search library..."),
            face = Font:getFace("cfont", is_sui and theme.fs("body") or 15),
            bold = has_query,
            fgcolor = has_query and Blitbuffer.COLOR_BLACK or theme.color_label_dim,
            max_width = search_text_w,
        }
        local search_inner_h = math.max(sc(24), search_label:getSize().h + sc(2))
        local search_content = OverlapGroup:new{
            dimen = Geom:new{ w = search_inner_w, h = search_inner_h },
            LeftContainer:new{
                dimen = Geom:new{ w = search_inner_w, h = search_inner_h },
                HorizontalGroup:new{
                    align = "center",
                    search_icon,
                    HorizontalSpan:new{ width = sc(8) },
                    search_label,
                },
            },
        }
        if has_query then
            table.insert(search_content, RightContainer:new{
                dimen = Geom:new{ w = search_inner_w, h = search_inner_h },
                Widgets.createIconButton{
                    icon = "x.svg",
                    size = search_icon_sz,
                    padding = sc(3),
                    callback = function()
                        search_query = ""
                        current_page = 1
                        shelf_cache.folder_page_stack[active_tab] = {}
                        shelf_cache.data_dirty = true
                        renderShelf()
                    end,
                },
            })
        end
        local search_bar = Widgets.makeTapItem(
            FrameContainer:new{
                padding = sc(5),
                padding_left = sc(9),
                padding_right = sc(9),
                bordersize = sc(1),
                color = has_query and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
                radius = theme.radius_btn or sc(4),
                background = Blitbuffer.COLOR_WHITE,
                width = search_bar_w,
                search_content,
            },
            function()
                showSearchDialog(search_query, function(next_q)
                    search_query = next_q
                    current_page = 1
                    shelf_cache.folder_page_stack[active_tab] = {}
                    shelf_cache.data_dirty = true
                    renderShelf()
                end)
            end
        )

        local header_row_h = math.max(left_btn:getSize().h, search_bar:getSize().h, right_group:getSize().h)
        local header_row = OverlapGroup:new{
            dimen = Geom:new{ w = header_inner_w, h = header_row_h },
            LeftContainer:new{
                dimen = Geom:new{ w = header_inner_w, h = header_row_h },
                left_btn,
            },
            CenterContainer:new{
                dimen = Geom:new{ w = header_inner_w, h = header_row_h },
                search_bar,
            },
            RightContainer:new{
                dimen = Geom:new{ w = header_inner_w, h = header_row_h },
                right_group,
            },
        }
        local header_frame = FrameContainer:new{
            padding = sc(8),
            padding_left = header_pad_h,
            padding_right = header_pad_h,
            bordersize = 0,
            background = Blitbuffer.COLOR_WHITE,
            width = sw,
            header_row,
        }
        local header_divider = LineWidget:new{
            dimen = Geom:new{ w = sw, h = sc(1) },
            background = Blitbuffer.COLOR_BLACK,
        }

        -- Kindle-Style Two-Tab Switcher (On Device | Cloud)
        local tab_bar = Widgets.createTwoTabBar({
            { id = "device", label = string.format(_("On Device (%d)"), #device_books) },
            { id = "cloud", label = string.format(_("Cloud (%d)"), #cloud_books) },
        }, active_tab, sw, function(next_tab)
            local c = Settings.load()
            c.library_active_tab = next_tab
            Settings.save(c)
            current_page = 1
            shelf_cache.data_dirty = true
            renderShelf()
        end)

        -- Sub-toolbar: Selection bar (when select_mode) or Filter/Folder Up + Grid/List + Sync
        local sub_icon_sz = theme.icon and theme.icon(20) or sc(20)
        local sub_tools
        local sub_left_items = { align = "center" }

        if select_state.active then
            local sel_count = UILibrary.countSelected(select_state)
            table.insert(sub_left_items, TextWidget:new{
                text = string.format(_("%d selected"), sel_count),
                face = Font:getFace("cfont", is_sui and theme.fs("body") or 15),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            })
            sub_tools = HorizontalGroup:new{
                align = "center",
                Widgets.createButton{
                    text = _("All"),
                    padding = sc(3),
                    padding_h = sc(8),
                    text_font_size = theme.fs and theme.fs("detail") or 14,
                    callback = function()
                        for _, it in ipairs(display_books) do
                            local k = UILibrary.getSelectionKey(it)
                            if k then select_state.map[k] = it end
                        end
                        renderShelf()
                    end,
                },
                HorizontalSpan:new{ width = sc(6) },
                Widgets.createButton{
                    text = _("Actions…"),
                    is_primary = true,
                    padding = sc(3),
                    padding_h = sc(8),
                    text_font_size = theme.fs and theme.fs("detail") or 14,
                    callback = function()
                        UILibrary.showBatchActionsDialog(UILibrary.getSelectedList(select_state), {
                            current_folder = (active_tab == "device") and (current_folder or (Scanner.getEffectiveBooksDirs()[1])) or nil,
                            on_exit_select = function() UILibrary.exitSelectMode(select_state) end,
                            on_refresh = function(force_rescan)
                                refreshLocalBooks(force_rescan)
                                if isAlive() then renderShelf() end
                            end,
                            on_upload_batch = function(batch_list)
                                UILibrary.uploadBookBatch(batch_list, opts.open_doc_info and opts.open_doc_info.open_doc, function(ok, _, toast_msg)
                                    if ok then
                                        catalog_data, merged_progress = Sync.loadCachedCatalog()
                                        shelf_cache.mergeLocalProgressIntoMerged()
                                        refreshLocalBooks(false)
                                        if isAlive() then renderShelf() end
                                    end
                                    if toast_msg then Widgets.showToast(toast_msg, 3) end
                                end)
                            end,
                            on_offload_batch = function(off_list)
                                for _, offloaded in ipairs(off_list) do
                                    local paths = offloaded.all_local_paths or { offloaded.local_path }
                                    local target_path = offloaded.local_path
                                    local target_cloud_id = offloaded.cloud_id or offloaded.id
                                    for _, p in ipairs(paths) do pcall(os.remove, p) end
                                    Settings.unlinkBook(target_cloud_id, target_path)
                                end
                                refreshLocalBooks(true)
                                if isAlive() then renderShelf() end
                                Widgets.showToast(string.format(_("Offloaded %d book(s)."), #off_list), 2.5)
                            end,
                            on_delete_cloud_batch = function(cloud_list)
                                for _, target_item in ipairs(cloud_list) do
                                    local target_id = target_item.cloud_id or target_item.id
                                    Sync.deleteCloudBook(target_id, target_item, function(ok)
                                        if ok and catalog_data and catalog_data.books and catalog_data.books[target_id] then
                                            catalog_data.books[target_id].deleted = true
                                        end
                                    end)
                                end
                                Sync.saveCachedCatalog(catalog_data, merged_progress)
                                refreshLocalBooks(false)
                                if isAlive() then renderShelf() end
                                Widgets.showToast(string.format(_("Deleted %d book(s) from Cloud."), #cloud_list), 2.5)
                            end,
                        })
                    end,
                },
                HorizontalSpan:new{ width = sc(6) },
                Widgets.createButton{
                    text = _("Done"),
                    padding = sc(3),
                    padding_h = sc(8),
                    text_font_size = theme.fs and theme.fs("detail") or 14,
                    callback = function()
                        UILibrary.exitSelectMode(select_state)
                        renderShelf()
                    end,
                },
            }
        else
        sub_tools = HorizontalGroup:new{
            align = "center",
            Widgets.createIconButton{
                icon = (view_mode == "cover") and "list.svg" or "grid.svg",
                size = sub_icon_sz,
                padding = sc(4),
                callback = function()
                    local c = Settings.load()
                    c.library_view_mode = (view_mode == "cover") and "list" or "cover"
                    Settings.save(c)
                    current_page = 1
                    renderShelf()
                end,
            },
            HorizontalSpan:new{ width = sc(6) },
            Widgets.createIconButton{
                icon = "refresh-cw.svg",
                size = sub_icon_sz,
                padding = sc(4),
                callback = function()
                    fetchCloudWithBar(true)
                end,
            },
        }
        if use_folders and folder_info and folder_info.can_go_up then
            local up_btn = Widgets.makeTapItem(
                FrameContainer:new{
                    padding = sc(3),
                    padding_left = 0,
                    padding_right = sc(6),
                    bordersize = 0,
                    HorizontalGroup:new{
                        align = "center",
                        ImageWidget:new{
                            file = Widgets.getAssetPath("chevron-left.svg"),
                            width = theme.icon and theme.icon(18) or sc(18),
                            height = theme.icon and theme.icon(18) or sc(18),
                            scale_factor = 0,
                            is_icon = true,
                            alpha = true,
                        },
                        HorizontalSpan:new{ width = sc(2) },
                        TextWidget:new{
                            text = tostring(folder_info.current_label or ""),
                            face = Font:getFace("cfont", is_sui and theme.fs("body") or 15),
                            bold = true,
                            fgcolor = Blitbuffer.COLOR_BLACK,
                        },
                    },
                },
                function()
                    if active_tab == "device" then
                        current_folder = folder_info.parent_dir
                    else
                        current_cloud_dir = folder_info.parent_dir or ""
                    end
                    current_page = table.remove(shelf_cache.folder_page_stack[active_tab]) or 1
                    shelf_cache.data_dirty = true
                    renderShelf()
                end
            )
            table.insert(sub_left_items, up_btn)
        else
            local filter_lbl_text = (FILTER_LABELS[current_filter] or _("All Books")) .. " ▾"
            local filter_btn = Widgets.makeTapItem(
                FrameContainer:new{
                    padding = sc(3),
                    padding_left = sc(2),
                    padding_right = sc(6),
                    bordersize = 0,
                    TextWidget:new{
                        text = filter_lbl_text,
                        face = Font:getFace("cfont", is_sui and (theme.fs("detail") + 1) or 14),
                        bold = (current_filter ~= "all"),
                        fgcolor = Blitbuffer.COLOR_BLACK,
                    },
                },
                function()
                    showFilterDialog(current_filter, function(next_f)
                        local c = Settings.load()
                        c.library_filter = next_f
                        Settings.save(c)
                        current_page = 1
                        shelf_cache.folder_page_stack[active_tab] = {}
                        shelf_cache.data_dirty = true
                        renderShelf()
                    end)
                end
            )
            table.insert(sub_left_items, filter_btn)
        end

        shelf_cache.active_status_widget = nil
        if not select_state.active then
            local status_suffix
            local active_job = NimbusProgress.getActiveJob and NimbusProgress.getActiveJob()
            if active_job then
                status_suffix = UILibrary.formatActiveJobStatus(active_job)
            elseif bg_syncing then
                status_suffix = _("· Syncing...")
            elseif not configured then
                status_suffix = _("· Offline")
            elseif sync_error then
                status_suffix = _("· Sync error")
            else
                status_suffix = string.format("· %d %s", #display_books, #display_books == 1 and _("item") or _("items"))
            end
            local left_fixed_w = sub_left_items[1]:getSize().w
            local status_max_w = math.max(sc(60), sw - sc(24) - left_fixed_w - sub_tools:getSize().w - sc(8))
            local is_tappable = (active_job ~= nil and type(active_job.reopen) == "function") or sync_error ~= nil
            local status_lbl = TextWidget:new{
                text = status_suffix,
                face = Font:getFace("cfont", is_sui and theme.fs("detail") or 13),
                bold = active_job ~= nil,
                fgcolor = (active_job ~= nil) and Blitbuffer.COLOR_BLACK or theme.color_label_dim,
                max_width = status_max_w,
            }
            shelf_cache.active_status_widget = status_lbl
            if is_tappable then
                table.insert(sub_left_items, Widgets.makeTapItem(
                    FrameContainer:new{
                        padding = sc(3),
                        padding_left = sc(4),
                        padding_right = sc(4),
                        bordersize = 0,
                        status_lbl,
                    },
                    function()
                        local cur_job = NimbusProgress.getActiveJob and NimbusProgress.getActiveJob()
                        if cur_job and cur_job.reopen then
                            cur_job.reopen()
                        elseif sync_error then
                            fetchCloudWithBar(true)
                        end
                    end
                ))
            else
                table.insert(sub_left_items, status_lbl)
            end
        end
        end
        local sub_left = HorizontalGroup:new(sub_left_items)

        local sub_toolbar = FrameContainer:new{
            padding = sc(4),
            padding_left = sc(12),
            padding_right = sc(10),
            bordersize = 0,
            width = sw,
            background = Blitbuffer.COLOR_WHITE,
            OverlapGroup:new{
                dimen = Geom:new{ w = sw - sc(22), h = math.max(sub_left:getSize().h, sub_tools:getSize().h) },
                LeftContainer:new{
                    dimen = Geom:new{ w = sw - sc(22), h = math.max(sub_left:getSize().h, sub_tools:getSize().h) },
                    sub_left,
                },
                RightContainer:new{
                    dimen = Geom:new{ w = sw - sc(22), h = math.max(sub_left:getSize().h, sub_tools:getSize().h) },
                    sub_tools,
                },
            },
        }
        local sub_divider = LineWidget:new{
            dimen = Geom:new{ w = sw, h = sc(1) },
            background = theme.color_bg_dim,
        }

        local prev_btn = Widgets.createButton{
            text = _("‹ Prev"),
            padding = sc(8),
            padding_h = sc(14),
            consume_hold = true,
            callback = function()
                if current_page > 1 then current_page = current_page - 1; renderShelf() end
            end,
        }
        local next_btn = Widgets.createButton{
            text = _("Next ›"),
            padding = sc(8),
            padding_h = sc(14),
            consume_hold = true,
            callback = function()
                if current_page < total_pages then current_page = current_page + 1; renderShelf() end
            end,
        }
        local page_label_fs = is_sui and theme.fs("body") or 16
        local page_label_probe = TextWidget:new{
            text = string.format("%d / %d", 1, 1),
            face = Font:getFace("cfont", page_label_fs),
            fgcolor = theme.color_label_dim,
        }
        local header_h = header_frame:getSize().h + sc(1) + tab_bar:getSize().h + sub_toolbar:getSize().h + sc(1)
        local footer_h = math.max(sc(48), prev_btn:getSize().h + sc(10), next_btn:getSize().h + sc(10), page_label_probe:getSize().h + sc(10))
        local avail_h = sh - header_h - footer_h

        local title_fs = theme.fs and theme.fs("detail") or 14
        local grid = theme.computeCoverGrid{
            avail_h = avail_h,
            sw = sw,
            cols = 3,
            margin_h = is_sui and sc(10) or sc(14),
            grid_gap = is_sui and sc(10) or sc(12),
            title_slot_h = 0,
            title_gap = 0,
            min_gap_v = sc(8),
            max_gap_v = sc(24),
        }
        local COLS = grid.cols
        local grid_gap = grid.grid_gap
        local margin_h = grid.margin_h
        local cell_w = grid.cell_w
        local content_w = grid.row_total_w
        local content_inner = content_w - sc(12)
        local grid_gap_v = grid.grid_gap_v
        local cover_slot_w = grid.cover_slot_w
        local cover_slot_h = grid.cover_slot_h
        local cover_row_h = grid.cover_row_h

        local pages = {}
        if #display_books > 0 then
            local per_page = (view_mode == "cover")
                and grid.per_page
                or math.max(1, math.floor(avail_h / sc(is_sui and 100 or 92)))
            for i = 1, #display_books, per_page do
                local chunk = {}
                for k = i, math.min(#display_books, i + per_page - 1) do
                    table.insert(chunk, display_books[k])
                end
                table.insert(pages, chunk)
            end
        end

        total_pages = math.max(1, #pages)
        if current_page > total_pages then current_page = total_pages end
        local cur_page_books = pages[current_page] or {}
        local page_content_vg = VerticalGroup:new{ align = "left" }

        local function getProgressBadge(item)
            if item.is_folder then return nil end
            local prog = merged_progress[item.cloud_id or item.id]
            local pct = (prog and prog.percent) or item.percent or 0
            local status = (prog and prog.status) or item.status
            if status == "finished" or status == "complete" then
                return _("Done"), true
            elseif pct > 0 then
                return string.format("%d%%", math.floor(pct * 100 + 0.5)), false
            end
            return nil
        end

        local function getStatusBadge(item)
            if item.is_folder then
                return string.format("%d", item.book_count or 0), false
            end
            if configured and item.is_in_cloud and item.local_path then
                return _("Synced"), true
            elseif item.local_path then
                return _("Local"), false
            end
            return _("Cloud"), false
        end

        local function makeBookActionOpts()
            return {
                on_open_book = function(path)
                    if not embedded_fm then UILibrary.close() end
                    if on_open_book then on_open_book(path) end
                end,
                on_upload_single = function(single)
                    UILibrary.uploadBookBatch({ single }, opts.open_doc_info and opts.open_doc_info.open_doc, function(ok, _, toast_msg)
                        if ok then
                            catalog_data, merged_progress = Sync.loadCachedCatalog()
                            refreshLocalBooks(false)
                            if isAlive() then renderShelf() end
                        end
                        if toast_msg then
                            Widgets.showToast(toast_msg, 3)
                        end
                    end)
                end,
                on_downloaded = function(dl_item, dest)
                    dl_item.local_path = dest
                    dl_item.all_local_paths = { dest }
                    refreshLocalBooks()
                    if isAlive() then renderShelf() end
                end,
                on_offload_local = function(offloaded)
                    local paths = offloaded.all_local_paths or { offloaded.local_path }
                    local target_path = offloaded.local_path
                    local target_cloud_id = offloaded.cloud_id or offloaded.id
                    for i = #device_books, 1, -1 do
                        local b = device_books[i]
                        if b.local_path == target_path or (target_cloud_id and b.cloud_id == target_cloud_id) then
                            table.remove(device_books, i)
                        end
                    end
                    renderShelf()
                    Widgets.showToast(_("Offloaded from device."), 2)
                    UIManager:nextTick(function()
                        for _, p in ipairs(paths) do
                            pcall(os.remove, p)
                        end
                        Settings.unlinkBook(target_cloud_id, target_path)
                    end)
                end,
                on_delete_cloud = function(target_item)
                    local target_id = target_item.cloud_id or target_item.id
                    local prog_dlg = NimbusProgress:new{
                        title = _("Delete from Cloud"),
                        subtitle = tostring(target_item.title or _("Book")),
                        detail = _("Updating cloud catalog..."),
                        progress = 30,
                    }
                    prog_dlg:show()
                    UIManager:nextTick(function()
                        Sync.deleteCloudBook(target_id, target_item, function(ok, res)
                            prog_dlg:close()
                            if ok then
                                if type(res) == "table" and res.books then
                                    catalog_data = res
                                elseif catalog_data and catalog_data.books and catalog_data.books[target_id] then
                                    catalog_data.books[target_id].deleted = true
                                end
                                Sync.saveCachedCatalog(catalog_data, merged_progress)
                                refreshLocalBooks(false)
                                if isAlive() then renderShelf() end
                                Widgets.showToast(_("Deleted from Nimbus Cloud."), 2)
                            else
                                Widgets.showToast(_("Failed to delete from cloud: ") .. tostring(res), 4)
                            end
                        end)
                    end)
                end,
                on_progress_changed = function()
                    shelf_cache.mergeLocalProgressIntoMerged()
                    shelf_cache.data_dirty = true
                    if isAlive() then renderShelf() end
                end,
                current_folder = (active_tab == "device") and (current_folder or (Scanner.getEffectiveBooksDirs()[1])) or nil,
                on_start_select = function(start_item)
                    select_state.active = true
                    select_state.map = {}
                    local k = UILibrary.getSelectionKey(start_item)
                    if k then select_state.map[k] = start_item end
                    if isAlive() then renderShelf() end
                end,
                on_show_folder = function(target_path)
                    if embedded_fm and embedded_fm._nimbus_orig_fc then
                        local slot = (embedded_fm._navbar_inner and embedded_fm._navbar_inner[1])
                            and embedded_fm._navbar_inner or embedded_fm[1]
                        embedded_fm._nimbus_browsing_files = true
                        slot[1] = embedded_fm._nimbus_orig_fc
                        embedded_fm.layout = embedded_fm._nimbus_orig_fc.layout
                        if embedded_fm.file_chooser and embedded_fm.file_chooser.changeToPath then
                            local dir = target_path:match("^(.*)[/\\][^/\\]+$") or target_path
                            embedded_fm.file_chooser:changeToPath(dir, target_path)
                        end
                        UIManager:setDirty(embedded_fm, "ui")
                    else
                        UILibrary.close()
                        local ok_fm_mod, FM = pcall(require, "apps/filemanager/filemanager")
                        local inst = ok_fm_mod and FM and FM.instance
                        if inst and inst.file_chooser and inst.file_chooser.changeToPath then
                            local dir = target_path:match("^(.*)[/\\][^/\\]+$") or target_path
                            inst.file_chooser:changeToPath(dir, target_path)
                        end
                    end
                end,
                on_refresh = function(force_rescan)
                    refreshLocalBooks(force_rescan)
                    if isAlive() then renderShelf() end
                end,
            }
        end

        local function handlePrimaryTap(item)
            if item.is_folder then
                table.insert(shelf_cache.folder_page_stack[active_tab], current_page)
                if active_tab == "device" then
                    current_folder = item.path
                else
                    current_cloud_dir = item.path
                end
                current_page = 1
                shelf_cache.data_dirty = true
                renderShelf()
                return
            end
            if select_state.active then
                UILibrary.toggleItemSelection(select_state, item)
                renderShelf()
                return
            end
            if item.local_path then
                if not embedded_fm then UILibrary.close() end
                if on_open_book then on_open_book(item.local_path) end
            else
                UILibrary.showBookDetailModal(item, merged_progress[item.cloud_id or item.id], makeBookActionOpts())
            end
        end

        local function openActionsMenu(item)
            if item.is_folder then
                handlePrimaryTap(item)
                return
            end
            if select_state.active then
                if not UILibrary.isItemSelected(select_state, item) then
                    UILibrary.toggleItemSelection(select_state, item)
                end
                UILibrary.showBatchActionsDialog(UILibrary.getSelectedList(select_state), {
                    current_folder = (active_tab == "device") and (current_folder or (Scanner.getEffectiveBooksDirs()[1])) or nil,
                    on_exit_select = function() UILibrary.exitSelectMode(select_state) end,
                    on_refresh = function(force_rescan)
                        refreshLocalBooks(force_rescan)
                        if isAlive() then renderShelf() end
                    end,
                })
                return
            end
            UILibrary.showBookActionsMenu(item, merged_progress[item.cloud_id or item.id], makeBookActionOpts())
        end

        if #display_books == 0 then
            local empty_msg
            if has_query or current_filter ~= "all" then
                empty_msg = _("No books match your search or filter.\n\nTap ✕ in the search bar or change the filter above.")
            elseif active_tab == "device" then
                empty_msg = _("No books found in this folder.\n\nSet your Book Folder in Settings or open a book in KOReader.")
            elseif not configured then
                empty_msg = _("Cloud storage is not connected yet.\n\nTap ⋯ → Nimbus Settings to connect Google Drive, OneDrive, Dropbox, or WebDAV.")
            else
                empty_msg = _("No books in Cloud yet.\n\nSwitch to On Device or tap ⋯ → Upload Books to add books.")
            end
            table.insert(page_content_vg, FrameContainer:new{
                padding = sc(30),
                bordersize = 0,
                width = sw,
                CenterContainer:new{
                    dimen = Geom:new{ w = sw - sc(48), h = sh - sc(260) },
                    TextBoxWidget:new{
                        text = empty_msg,
                        face = Font:getFace("cfont", theme.fs and theme.fs("body") or 16),
                        fgcolor = Blitbuffer.COLOR_BLACK,
                        width = sw - sc(48),
                        alignment = "center",
                    },
                },
            })
        elseif view_mode == "list" then
            for idx, item in ipairs(cur_page_books) do
                local p_text, p_hl = getProgressBadge(item)
                local prog_w = p_text and Widgets.createBadge(p_text, p_hl) or nil
                local s_text, s_hl = getStatusBadge(item)
                local status_w = Widgets.createBadge(s_text, s_hl)
                local dots_w = (not item.is_folder) and Widgets.createIconButton{
                    icon = "more-vertical.svg",
                    size = theme.icon and theme.icon(18) or sc(18),
                    padding = sc(4),
                    callback = function() openActionsMenu(item) end,
                } or nil
                local right_cluster = HorizontalGroup:new{
                    align = "center",
                    status_w or HorizontalSpan:new{ width = 0 },
                    (status_w and prog_w) and HorizontalSpan:new{ width = sc(4) } or HorizontalSpan:new{ width = 0 },
                    prog_w or HorizontalSpan:new{ width = 0 },
                    dots_w and HorizontalSpan:new{ width = sc(4) } or HorizontalSpan:new{ width = 0 },
                    dots_w or HorizontalSpan:new{ width = 0 },
                }
                local right_reserve = right_cluster:getSize().w + sc(8)
                local thumb_w, thumb_h = sc(54), sc(76)
                local text_w = content_inner - right_reserve - thumb_w - sc(10)

                local thumb_frame
                if item.is_folder then
                    thumb_frame = FrameContainer:new{
                        bordersize = sc(1),
                        color = Blitbuffer.COLOR_DARK_GRAY,
                        background = Blitbuffer.COLOR_LIGHT_GRAY,
                        padding = 0,
                        width = thumb_w,
                        height = thumb_h,
                        CenterContainer:new{
                            dimen = Geom:new{ w = thumb_w, h = thumb_h },
                            ImageWidget:new{
                                file = Widgets.getAssetPath("folder.svg"),
                                width = sc(28),
                                height = sc(28),
                                scale_factor = 0,
                                is_icon = true,
                                alpha = true,
                            },
                        },
                    }
                else
                    local cached_cover = Covers.getCachedCoverPath(item)
                    local thumb_widget = cached_cover and Covers.createCoverImageWidget(cached_cover, thumb_w, thumb_h)
                    if not thumb_widget then
                        thumb_widget = Covers.createPlaceholderWidget(thumb_w, thumb_h, item.title)
                    end
                    thumb_frame = FrameContainer:new{
                        bordersize = 0,
                        padding = 0,
                        width = thumb_w,
                        height = thumb_h,
                        CenterContainer:new{
                            dimen = Geom:new{ w = thumb_w, h = thumb_h },
                            thumb_widget,
                        },
                    }
                    local function applyListThumb(new_img)
                        if my_gen ~= render_gen or not new_img or not isAlive() or not thumb_frame or not thumb_frame[1] then return end
                        thumb_frame[1][1] = new_img
                        dirtyHost()
                    end
                    if not cached_cover then
                        Covers.enqueueFetchCover(item, function(loaded_path)
                            if my_gen ~= render_gen or not loaded_path or not isAlive() then return end
                            Covers.enqueueDecodeCover(loaded_path, thumb_w, thumb_h, applyListThumb)
                        end, opts.open_doc_info and opts.open_doc_info.open_doc)
                    end
                end

                local sub_line
                if item.is_folder then
                    sub_line = string.format(_("Folder · %d %s"), item.book_count or 0, (item.book_count == 1) and _("book") or _("books"))
                else
                    local authors_str = type(item.authors) == "table" and table.concat(item.authors, ", ") or tostring(item.authors or "")
                    sub_line = (authors_str ~= "" and (authors_str .. "  ·  ") or "") .. tostring(item.format or ""):upper()
                end
                local sel_cb_w = (select_state.active and not item.is_folder) and ImageWidget:new{
                    file = Widgets.getAssetPath(UILibrary.isItemSelected(select_state, item) and "check-square.svg" or "square.svg"),
                    width = theme.icon and theme.icon(20) or sc(20),
                    height = theme.icon and theme.icon(20) or sc(20),
                    scale_factor = 0,
                    is_icon = true,
                    alpha = true,
                } or nil
                local sel_extra_w = sel_cb_w and (sel_cb_w:getSize().w + sc(8)) or 0
                local row_left_items = { align = "center" }
                if sel_cb_w then
                    table.insert(row_left_items, sel_cb_w)
                    table.insert(row_left_items, HorizontalSpan:new{ width = sc(8) })
                end
                table.insert(row_left_items, thumb_frame)
                table.insert(row_left_items, HorizontalSpan:new{ width = sc(10) })
                table.insert(row_left_items, VerticalGroup:new{
                    align = "left",
                    TextWidget:new{
                        text = tostring(item.title or _("Untitled")),
                        face = Font:getFace("cfont", is_sui and theme.fs("subtitle") or 18),
                        bold = true,
                        fgcolor = Blitbuffer.COLOR_BLACK,
                        max_width = math.max(sc(60), text_w - sel_extra_w),
                    },
                    VerticalSpan:new{ width = sc(2) },
                    TextWidget:new{
                        text = sub_line,
                        face = Font:getFace("cfont", is_sui and (theme.fs("detail") + 1) or 15),
                        fgcolor = theme.color_label_dim,
                        max_width = math.max(sc(60), text_w - sel_extra_w),
                    },
                })
                local row_left = HorizontalGroup:new(row_left_items)
                local total_h = math.max(row_left:getSize().h, right_cluster:getSize().h)
                local tap_left = Widgets.makeTapItem(
                    FrameContainer:new{ padding = 0, bordersize = 0, width = content_inner - right_reserve, row_left },
                    function() handlePrimaryTap(item) end,
                    function() openActionsMenu(item) end
                )
                local row_overlap = OverlapGroup:new{
                    dimen = Geom:new{ w = content_inner, h = total_h },
                    LeftContainer:new{ dimen = Geom:new{ w = content_inner, h = total_h }, tap_left },
                    RightContainer:new{ dimen = Geom:new{ w = content_inner, h = total_h }, right_cluster },
                }

                table.insert(page_content_vg, HorizontalGroup:new{
                    HorizontalSpan:new{ width = margin_h },
                    FrameContainer:new{ padding = sc(8), bordersize = 0, width = content_w, row_overlap },
                    HorizontalSpan:new{ width = margin_h },
                })
                table.insert(page_content_vg, HorizontalGroup:new{
                    HorizontalSpan:new{ width = margin_h },
                    LineWidget:new{ dimen = Geom:new{ w = content_w, h = sc(1) }, background = theme.color_bg_dim },
                    HorizontalSpan:new{ width = margin_h },
                })
            end
        else
            table.insert(page_content_vg, VerticalSpan:new{ width = grid_gap_v })
            local current_row_widgets = {}
            for i, item in ipairs(cur_page_books) do
                local cover_slot
                if item.is_folder then
                    local mosaic = Covers.createFolderMosaicWidget(
                        item.sample_books,
                        cover_slot_w,
                        cover_slot_h,
                        function()
                            if my_gen == render_gen and isAlive() then dirtyHost() end
                        end,
                        opts.open_doc_info and opts.open_doc_info.open_doc,
                        function()
                            return my_gen == render_gen and isAlive()
                        end
                    )
                    cover_slot = BottomContainer:new{
                        dimen = Geom:new{ w = cover_slot_w, h = cover_slot_h },
                        mosaic,
                    }
                else
                    local cached_cover = Covers.getCachedCoverPath(item)
                    local cover_img = cached_cover and Covers.createCoverImageWidget(cached_cover, cover_slot_w, cover_slot_h)
                    if not cover_img then
                        cover_img = Covers.createPlaceholderWidget(cover_slot_w, cover_slot_h, item.title)
                    end
                    cover_slot = BottomContainer:new{
                        dimen = Geom:new{ w = cover_slot_w, h = cover_slot_h },
                        cover_img,
                    }
                    local function applyGridCover(new_img)
                        if my_gen ~= render_gen or not new_img or not isAlive() or not cover_slot then return end
                        cover_slot[1] = new_img
                        dirtyHost()
                    end
                    if not cached_cover then
                        Covers.enqueueFetchCover(item, function(loaded_path)
                            if my_gen ~= render_gen or not loaded_path or not isAlive() then return end
                            Covers.enqueueDecodeCover(loaded_path, cover_slot_w, cover_slot_h, applyGridCover)
                        end, opts.open_doc_info and opts.open_doc_info.open_doc)
                    end
                end

                local cover_with_badge = OverlapGroup:new{
                    dimen = Geom:new{ w = cover_slot_w, h = cover_slot_h },
                    cover_slot,
                }
                if item.is_folder then
                    local folder_lbl = FrameContainer:new{
                        padding = sc(2),
                        padding_left = sc(5),
                        padding_right = sc(5),
                        bordersize = sc(1),
                        color = Blitbuffer.COLOR_BLACK,
                        background = Blitbuffer.COLOR_WHITE,
                        TextWidget:new{
                            text = tostring(item.title or _("Untitled")),
                            face = Font:getFace("cfont", theme.fs and theme.fs("caption") or 12),
                            bold = true,
                            fgcolor = Blitbuffer.COLOR_BLACK,
                            max_width = cover_slot_w - sc(18),
                        },
                    }
                    table.insert(cover_with_badge, CenterContainer:new{
                        dimen = Geom:new{ w = cover_slot_w, h = folder_lbl:getSize().h + sc(8) },
                        FrameContainer:new{
                            padding = sc(4),
                            bordersize = 0,
                            folder_lbl,
                        },
                    })
                    local count_badge = Widgets.createCircleBadge{
                        text = string.format("%d", item.book_count or 0),
                    }
                    table.insert(cover_with_badge, BottomContainer:new{
                        dimen = Geom:new{ w = cover_slot_w, h = cover_slot_h },
                        LeftContainer:new{
                            dimen = Geom:new{ w = cover_slot_w, h = count_badge:getSize().h + sc(12) },
                            FrameContainer:new{
                                padding = sc(6),
                                bordersize = 0,
                                count_badge,
                            },
                        },
                    })
                else
                    local p_text, p_hl = getProgressBadge(item)
                    if p_text then
                        local tag_w = Widgets.createCornerTag(p_hl and string.upper(p_text) or p_text)
                        table.insert(cover_with_badge, RightContainer:new{
                            dimen = Geom:new{ w = cover_slot_w, h = tag_w:getSize().h },
                            FrameContainer:new{
                                padding = 0,
                                padding_right = sc(6),
                                bordersize = 0,
                                tag_w,
                            },
                        })
                    end
                    if active_tab == "cloud" and item.local_path then
                        local check_badge = Widgets.createCircleBadge{ icon = "check-white.svg" }
                        table.insert(cover_with_badge, BottomContainer:new{
                            dimen = Geom:new{ w = cover_slot_w, h = cover_slot_h },
                            LeftContainer:new{
                                dimen = Geom:new{ w = cover_slot_w, h = check_badge:getSize().h + sc(12) },
                                FrameContainer:new{
                                    padding = sc(6),
                                    bordersize = 0,
                                    check_badge,
                                },
                            },
                        })
                    end
                    if select_state.active and UILibrary.isItemSelected(select_state, item) then
                        local sel_badge = Widgets.createCircleBadge{ icon = "check-white.svg" }
                        table.insert(cover_with_badge, LeftContainer:new{
                            dimen = Geom:new{ w = cover_slot_w, h = sel_badge:getSize().h + sc(12) },
                            FrameContainer:new{
                                padding = sc(6),
                                bordersize = 0,
                                sel_badge,
                            },
                        })
                    end
                end

                local cell_content = Widgets.makeTapItem(
                    cover_with_badge,
                    function() handlePrimaryTap(item) end,
                    function() openActionsMenu(item) end
                )
                table.insert(current_row_widgets, FrameContainer:new{
                    padding = 0,
                    bordersize = 0,
                    width = cell_w,
                    cell_content,
                })

                if #current_row_widgets == COLS or i == #cur_page_books then
                    local row_items = { HorizontalSpan:new{ width = margin_h } }
                    for col_i, cell in ipairs(current_row_widgets) do
                        if col_i > 1 then table.insert(row_items, HorizontalSpan:new{ width = grid_gap }) end
                        table.insert(row_items, cell)
                    end
                    table.insert(row_items, HorizontalSpan:new{ width = margin_h })
                    local row_group = HorizontalGroup:new(row_items)
                    row_group.align = "top"
                    table.insert(page_content_vg, row_group)
                    table.insert(page_content_vg, VerticalSpan:new{ width = grid_gap_v })
                    current_row_widgets = {}
                end
            end
        end

        local page_label = TextWidget:new{
            text = string.format("%d / %d", current_page, total_pages),
            face = Font:getFace("cfont", page_label_fs),
            fgcolor = theme.color_label_dim,
        }
        local prev_w, next_w = prev_btn:getSize().w, next_btn:getSize().w
        local nav_gap = sc(20)
        local footer_frame = FrameContainer:new{
            padding_top = sc(4),
            padding_bottom = sc(6),
            padding_left = sc(10),
            padding_right = sc(10),
            bordersize = 0,
            background = Blitbuffer.COLOR_WHITE,
            width = sw,
            height = footer_h,
            CenterContainer:new{
                dimen = Geom:new{ w = sw - sc(20), h = footer_h - sc(10) },
                HorizontalGroup:new{
                    align = "center",
                    current_page > 1 and prev_btn or HorizontalSpan:new{ width = prev_w },
                    HorizontalSpan:new{ width = nav_gap },
                    page_label,
                    HorizontalSpan:new{ width = nav_gap },
                    current_page < total_pages and next_btn or HorizontalSpan:new{ width = next_w },
                },
            },
        }

        local shelf_bg = FrameContainer:new{
            padding = 0,
            bordersize = 0,
            background = Blitbuffer.COLOR_WHITE,
            width = sw,
            height = sh,
            OverlapGroup:new{
                dimen = Geom:new{ w = sw, h = sh },
                VerticalGroup:new{
                    align = "left",
                    header_frame,
                    header_divider,
                    tab_bar,
                    sub_toolbar,
                    sub_divider,
                    VerticalSpan:new{ width = top_margin },
                    FrameContainer:new{ bordersize = 0, padding = 0, width = sw, page_content_vg },
                },
                BottomContainer:new{
                    dimen = Geom:new{ w = sw, h = sh },
                    footer_frame,
                },
            },
        }

        local old_shelf = host_container[1]
        host_container[1] = shelf_bg
        if old_shelf or Covers.pruneMemoryCache then
            UIManager:nextTick(function()
                if old_shelf and old_shelf.free then
                    pcall(function() old_shelf:free() end)
                end
                if Covers.pruneMemoryCache then
                    Covers.pruneMemoryCache()
                end
            end)
        end
        host_container.layout = Widgets.collectFocusableLayout(shelf_bg)
        if #host_container.layout > 0 then
            local sel = host_container.selected or { x = 1, y = 1 }
            local y = math.max(1, math.min(sel.y or 1, #host_container.layout))
            local row = host_container.layout[y]
            local x = math.max(1, math.min(sel.x or 1, #row))
            host_container.selected = { x = x, y = y }
            if host_container._nimbus_focus_active and row[x] and row[x].onFocus then
                row[x]:onFocus()
            end
        end
        dirtyHost()
    end

    host_container.key_events = host_container.key_events or {}
    host_container.key_events.FocusUp = host_container.key_events.FocusUp or { { "Up" }, event = "FocusMove", args = { 0, -1 } }
    host_container.key_events.FocusDown = host_container.key_events.FocusDown or { { "Down" }, event = "FocusMove", args = { 0, 1 } }
    host_container.key_events.FocusLeft = host_container.key_events.FocusLeft or { { "Left" }, event = "FocusMove", args = { -1, 0 } }
    host_container.key_events.FocusRight = host_container.key_events.FocusRight or { { "Right" }, event = "FocusMove", args = { 1, 0 } }
    host_container.key_events.Press = host_container.key_events.Press or { { "Press" }, event = "Press" }
    table.insert(host_container.key_events.Press, { "Return" })
    table.insert(host_container.key_events.Press, { "KP_Enter" })
    host_container.key_events.PrevPage = { { "PgUp" }, { "Prev" }, { "LPgBack" }, { "RPgBack" } }
    host_container.key_events.NextPage = { { "PgDn" }, { "Next" }, { "LPgFwd" }, { "RPgFwd" } }
    host_container.key_events.OpenMenu = { { "Menu" } }
    if not is_home then
        host_container.key_events.Close = { { "Back" }, { "Escape" } }
    end
    if Device and Device.input and Device.input.group then
        if not is_home and Device.input.group.Back then
            table.insert(host_container.key_events.Close, { Device.input.group.Back })
        end
        if Device.input.group.PgBack then table.insert(host_container.key_events.PrevPage, { Device.input.group.PgBack }) end
        if Device.input.group.PgFwd then table.insert(host_container.key_events.NextPage, { Device.input.group.PgFwd }) end
    end
    host_container.ges_events = {
        Swipe = {
            GestureRange:new{
                ges = "swipe",
                range = function()
                    local d = host_container.dimen
                    if d then
                        return Geom:new{ x = d.x or 0, y = d.y or 0, w = d.w or sw, h = d.h or sh }
                    end
                    return Geom:new{ x = 0, y = 0, w = sw, h = sh }
                end,
            },
        },
    }
    host_container.onOpenMenu = function()
        openKOReaderTopMenu(embedded_fm)
        return true
    end
    host_container.onPrevPage = function()
        if current_page > 1 then current_page = current_page - 1; renderShelf(); return true end
    end
    host_container.onNextPage = function()
        if current_page < total_pages then current_page = current_page + 1; renderShelf(); return true end
    end
    host_container.onSwipe = function(self, arg, ges)
        local g = ges or arg
        if type(g) ~= "table" then return false end
        if g == self._last_handled_ges then
            self._last_handled_ges = nil
            return true
        end
        if g.direction == "south" and g.pos and g.pos.y <= math.floor(sh * 0.15) then
            return openKOReaderTopMenu(embedded_fm)
        elseif g.direction == "west" then
            host_container:onNextPage()
            return true
        elseif g.direction == "east" then
            host_container:onPrevPage()
            return true
        end
    end
    host_container.onClose = function()
        if select_state.active then
            UILibrary.exitSelectMode(select_state)
            renderShelf()
            return true
        end
        if is_home then return true end
        UILibrary.close()
        return true
    end
    host_container.onCloseWidget = function()
        is_destroyed = true
        Covers.clearFetchQueue()
        if host_container[1] and host_container[1].free then
            pcall(function() host_container[1]:free() end)
        end
        Covers.clearMemoryCache()
        if UILibrary.setStatusListener then
            UILibrary.setStatusListener(nil)
        end
        collectgarbage("collect")
    end

    NimbusProgress.setStatusListener(function(is_progress_only)
        if not isAlive() then return end
        if is_progress_only and shelf_cache.active_status_widget then
            local active_job = NimbusProgress.getActiveJob()
            if active_job then
                shelf_cache.active_status_widget:setText(UILibrary.formatActiveJobStatus(active_job))
                dirtyHost()
                return
            end
        end
        if renderShelf then
            renderShelf()
        end
    end)
    refreshLocalBooks(false)
    renderShelf()

    local sync_notice = Settings.consumeSyncImportNotice()
    if sync_notice then
        UIManager:scheduleIn(0.1, function()
            if isAlive() then
                Widgets.showToast(sync_notice, 3)
            end
        end)
    end
    if Cloud.isConfigured() then
        UIManager:scheduleIn(0.2, function()
            if isAlive() then
                fetchCloudSilently(not catalog_saved_at or catalog_saved_at == 0)
            end
        end)
    end

    host_container.refreshView = function()
        if isAlive() then
            shelf_cache.data_dirty = true
            renderShelf()
        end
    end

    return host_container
end

function UILibrary.show(on_open_book, opts)
    UILibrary.close()
    opts = opts or {}
    local view = UILibrary.buildView(on_open_book, opts)
    active_shelf_overlay = view
    UIManager:show(active_shelf_overlay, "ui")
end

return UILibrary
