--[[--
main.lua
Entry point for nimbus.koplugin (KOReader Plugin).
--]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local ok_loc, Localization = pcall(require, "localization_nimbus")
local _ = (ok_loc and Localization and Localization.getHelper) and Localization:getHelper() or require("gettext")

local Constants = require("nimbus_constants")
local Conductor = require("nimbus_conductor")
local Logger = require("nimbus_logger")
local Settings = require("nimbus_settings")
local Cloud = require("nimbus_cloud")
local Hash = require("nimbus_hash")
local Matcher = require("nimbus_matcher")
local Merge = require("nimbus_merge")
local Sync = require("nimbus_sync")
local KOSync = require("nimbus_kosync")
local UILibrary = require("nimbus_ui_library")
local Widgets = require("nimbus_ui_widgets")
local NimbusProgress = require("nimbus_progress")

local function calculateOptimalPos(order_tools)
    local pos = 2
    for idx, id in ipairs(order_tools) do
        if id == "Storefront" or id == "xray" or id == "backup" then
            if idx >= pos then
                pos = idx + 1
            end
        end
    end
    return pos
end

local function injectIntoToolsMenu()
    local menu_orders = {
        "ui/elements/reader_menu_order",
        "ui/elements/filemanager_menu_order",
        "apps/reader/modules/readermenuorder",
    }
    for _, order_path in ipairs(menu_orders) do
        local ok, order = pcall(require, order_path)
        if ok and type(order) == "table" and type(order.tools) == "table" then
            for i = #order.tools, 1, -1 do
                if order.tools[i] == "nimbus" or order.tools[i] == "Nimbus" then
                    table.remove(order.tools, i)
                end
            end
            local pos = calculateOptimalPos(order.tools)
            table.insert(order.tools, pos, "nimbus")
        end
    end

    local ok_ms, MenuSorter = pcall(require, "ui/menusorter")
    if ok_ms and MenuSorter and not MenuSorter._nimbus_hooked then
        MenuSorter._nimbus_hooked = true
        local orig_sort = MenuSorter.sort
        MenuSorter.sort = function(this, item_table, order)
            if order and type(order.tools) == "table" and item_table and (item_table.nimbus or item_table.Nimbus) then
                for i = #order.tools, 1, -1 do
                    if order.tools[i] == "nimbus" or order.tools[i] == "Nimbus" then
                        table.remove(order.tools, i)
                    end
                end
                local pos = calculateOptimalPos(order.tools)
                table.insert(order.tools, pos, "nimbus")
            end
            return orig_sort(this, item_table, order)
        end
    end
end

local Nimbus = WidgetContainer:extend{
    name = "nimbus",
    is_doc_only = false,
}

local _live_nimbus_plugin = nil

local function getEmbedSlot(fm_self)
    if fm_self and fm_self._navbar_inner and fm_self._navbar_inner[1] then
        return fm_self._navbar_inner
    end
    return fm_self and fm_self[1]
end

local function embedIntoFileManager(fm_self)
    local slot = getEmbedSlot(fm_self)
    if not fm_self or not slot or not slot[1] then return end
    if not Settings.load().use_as_home_screen or fm_self._nimbus_browsing_files then return end
    if fm_self._nimbus_embedded_view and slot[1] == fm_self._nimbus_embedded_view then return end

    local ok_err, err = pcall(function()
        fm_self._nimbus_orig_fc = fm_self._nimbus_orig_fc or slot[1]
        local view = UILibrary.buildView(function(filepath)
            if _live_nimbus_plugin then
                _live_nimbus_plugin:openBookFile(filepath)
            else
                local ok_rm, ReaderUI = pcall(require, "apps/reader/readerui")
                if ok_rm and ReaderUI and ReaderUI.showReader then
                    ReaderUI:showReader(filepath)
                end
            end
        end, {
            is_home_screen = true,
            embedded_fm = fm_self,
        })
        fm_self._nimbus_embedded_view = view
        slot[1] = view
        if not fm_self._nimbus_key_patched then
            fm_self._nimbus_key_patched = true
            local orig_onKeyPress = fm_self.onKeyPress
            fm_self.onKeyPress = function(self_fm, key)
                local cur_slot = getEmbedSlot(self_fm)
                if self_fm._nimbus_embedded_view and cur_slot and cur_slot[1] == self_fm._nimbus_embedded_view
                    and not self_fm._nimbus_browsing_files then
                    if self_fm._nimbus_embedded_view.onKeyPress and self_fm._nimbus_embedded_view:onKeyPress(key) then
                        return true
                    end
                end
                return orig_onKeyPress(self_fm, key)
            end
        end
        if not fm_self._nimbus_swipe_patched and type(fm_self.onSwipeFM) == "function" then
            fm_self._nimbus_swipe_patched = true
            local orig_onSwipeFM = fm_self.onSwipeFM
            fm_self.onSwipeFM = function(self_fm, ges)
                local cur_slot = getEmbedSlot(self_fm)
                if self_fm._nimbus_embedded_view and cur_slot and cur_slot[1] == self_fm._nimbus_embedded_view
                    and not self_fm._nimbus_browsing_files then
                    if ges and self_fm._nimbus_embedded_view.onSwipe then
                        self_fm._nimbus_embedded_view:onSwipe(nil, ges)
                        self_fm._nimbus_embedded_view._last_handled_ges = ges
                        return true
                    end
                end
                return orig_onSwipeFM(self_fm, ges)
            end
        end
    end)
    if not ok_err then
        Logger.warn("Failed to embed into FileManager, falling back: " .. tostring(err))
        if fm_self._nimbus_orig_fc then
            slot[1] = fm_self._nimbus_orig_fc
        end
    end
end

local function installHomeScreenPatch()
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not ok_fm or not FileManager or FileManager._nimbus_setup_patched then return end
    FileManager._nimbus_setup_patched = true
    local orig_setupLayout = FileManager.setupLayout
    FileManager.setupLayout = function(fm_self, ...)
        orig_setupLayout(fm_self, ...)
        embedIntoFileManager(fm_self)
    end

    local ok_fc, FileChooser = pcall(require, "ui/widget/filechooser")
    if ok_fc and FileChooser and not FileChooser._nimbus_refresh_patched then
        FileChooser._nimbus_refresh_patched = true
        local orig_refreshPath = FileChooser.refreshPath
        FileChooser.refreshPath = function(fc_self, ...)
            local res = orig_refreshPath(fc_self, ...)
            local inst = FileManager.instance
            if inst and inst._nimbus_embedded_view and not inst._nimbus_browsing_files and inst._nimbus_embedded_view.refreshView then
                inst._nimbus_embedded_view.refreshView()
            end
            return res
        end
    end
end

function Nimbus:init()
    _live_nimbus_plugin = self
    self._last_sync_ts = 0
    Logger.init(self.path)
    Logger.startSession(Constants.VERSION)
    if ok_loc and Localization and Localization.ensureInit then
        Localization:ensureInit(self.path)
    end
    injectIntoToolsMenu()
    local cfg = Settings.load()
    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    Conductor.setProfile({
        plugin = "nimbus",
        is_foreground = function()
            return self:isForeground()
        end,
        on_reclaim = function(level)
            self:reclaimCaches(level)
        end,
        on_cancel_bg = function()
            if Sync.cancelBackgroundTasks then
                Sync.cancelBackgroundTasks()
            end
            if not self:isForeground() then
                local ok_cov, Covers = pcall(require, "nimbus_covers")
                if ok_cov and Covers and Covers.clearFetchQueue then
                    Covers.clearFetchQueue()
                end
            end
        end,
    })
    if UIManager and UIManager.nextTick then
        UIManager:nextTick(function()
            Conductor.ensureRegistered()
        end)
    end
    installHomeScreenPatch()
    if cfg.use_as_home_screen then
        if _G.G_reader_settings and _G.G_reader_settings.saveSetting then
            _G.G_reader_settings:saveSetting("start_with", "filemanager")
        end
        if self.ui and not self.ui.document and getEmbedSlot(self.ui) then
            embedIntoFileManager(self.ui)
            if package.loaded["infra/sui_core"] then
                UIManager:scheduleIn(0, function()
                    if self.ui and self.ui._nimbus_embedded_view and not self.ui._nimbus_browsing_files
                        and self.ui._nimbus_embedded_view.refreshView then
                        self.ui._nimbus_embedded_view.refreshView()
                    end
                end)
            end
        end
    end
end

function Nimbus:onDispatcherRegisterActions()
    Dispatcher:registerAction("nimbus_open_library", {
        category = "none",
        event = "NimbusOpenLibrary",
        title = _("Nimbus: Open Cloud Library"),
        general = true,
    })
    Dispatcher:registerAction("nimbus_sync_now", {
        category = "none",
        event = "NimbusSyncNow",
        title = _("Nimbus: Sync Current Book"),
        reader = true,
    })
    Dispatcher:registerAction("nimbus_upload_book", {
        category = "none",
        event = "NimbusUploadBook",
        title = _("Nimbus: Upload Current Book"),
        reader = true,
    })
end

function Nimbus:onNimbusOpenLibrary()
    self:openLibrary()
    return true
end

function Nimbus:onNimbusSyncNow()
    self:syncCurrentBook(true)
    return true
end

function Nimbus:onNimbusUploadBook()
    self:uploadCurrentBook()
    return true
end

function Nimbus:openBookFile(filepath)
    if not filepath then return end
    local ok_rm, ReaderUI = pcall(require, "apps/reader/readerui")
    if ok_rm and ReaderUI and ReaderUI.showReader then
        ReaderUI:showReader(filepath)
    elseif self.ui and self.ui.openFile then
        self.ui:openFile(filepath)
    end
end

function Nimbus:openLibrary(is_home_screen)
    local has_doc = (self.ui and self.ui.document ~= nil)
    local open_doc_info = nil
    if has_doc then
        local fp, props = self:getDocProps()
        open_doc_info = {
            filepath = fp,
            props = props,
            open_doc = self.ui.document,
        }
    end
    UILibrary.show(function(filepath)
        self:openBookFile(filepath)
    end, {
        is_home_screen = (is_home_screen == true),
        open_doc_info = open_doc_info,
        on_sync_now = function()
            if has_doc then
                self:syncCurrentBook(false)
            end
        end,
    })
end

function Nimbus:addToMainMenu(menu_items)
    injectIntoToolsMenu()
    menu_items.nimbus = {
        text = _("Nimbus"),
        sorting_hint = "tools",
        callback = function()
            self:openLibrary()
        end,
    }
end

function Nimbus:getDocProps()
    if not self.ui or not self.ui.document then return nil end
    local filepath = self.ui.document.file
    local props = self.ui.doc_props or (self.ui.document.getProps and self.ui.document:getProps()) or {}
    return filepath, {
        title = props.title,
        authors = props.authors,
        series = props.series,
        series_index = props.series_index,
        language = props.language,
        isbn = props.isbn,
    }
end

function Nimbus:getCurrentProgressState(book_id, partial_md5)
    local ui = self.ui
    if not ui or not ui.document then return nil end
    local ds = ui.doc_settings
    local pct = (ds and ds:readSetting("percent_finished")) or 0
    local page = ui.document.getCurrentPage and ui.document:getCurrentPage() or nil
    local total = ui.document.getPageCount and ui.document:getPageCount() or nil
    local xpointer = (ui.document.getXPointer and ui.document:getXPointer())
        or (ds and ds:readSetting("last_xpointer"))
        or nil
    local chapter = nil
    if ui.toc and ui.toc.getTocTitleByPage and page then
        pcall(function() chapter = ui.toc:getTocTitleByPage(page) end)
    end
    local summary = ds and ds:readSetting("summary")
    local raw_status = summary and summary.status
    local status = "reading"
    if raw_status == "complete" or raw_status == "finished" or pct >= 0.99 then
        status = "finished"
    elseif raw_status == "abandoned" then
        status = "abandoned"
    elseif pct <= 0 then
        status = "unread"
    end
    return {
        book_id = book_id,
        partial_md5 = partial_md5,
        percent = pct,
        page = page,
        total_pages = total,
        chapter = chapter,
        xpointer = xpointer,
        cfi = nil,
        text_anchor = nil,
        status = status,
        rating = nil,
        updated_at = os.time(),
    }
end

function Nimbus:jumpToRemotePosition(remote_prog)
    local ui = self.ui
    if not ui or not ui.document or not remote_prog then return end
    if remote_prog.xpointer and ui.rolling and ui.rolling.gotoXPointer then
        ui.rolling:gotoXPointer(remote_prog.xpointer)
    elseif remote_prog.percent and ui.document.getPageFromXPointer == nil and ui.paging and remote_prog.page then
        ui:handleEvent(Event:new("GotoPage", remote_prog.page))
    elseif remote_prog.percent and ui.rolling and ui.rolling.gotoPercent then
        ui.rolling:gotoPercent(remote_prog.percent * 100)
    elseif remote_prog.page then
        ui:handleEvent(Event:new("GotoPage", remote_prog.page))
    end
end

function Nimbus:uploadCurrentBook(on_done)
    local filepath, props = self:getDocProps()
    if not filepath then
        if on_done then on_done(false) end
        return
    end
    local filename = filepath:match("([^/\\]+)$") or filepath
    Logger.action("Uploading current book: " .. filename)
    local prog_dlg = NimbusProgress:new{
        title = _("Uploading to Nimbus Cloud"),
        subtitle = _("Preparing upload…"),
        detail = filename,
        progress = 0,
    }
    prog_dlg:show()

    UIManager:nextTick(function()
        Sync.uploadBook(filepath, props, nil, function(ok, res)
            prog_dlg:close()
            if ok then
                Logger.info("Uploaded book to Nimbus Cloud: " .. tostring(res.title))
                Widgets.showToast(string.format(_("Uploaded '%s' to Nimbus Cloud!"), tostring(res.title)), 3)
            elseif res ~= "canceled" then
                Logger.err("Upload failed for " .. filename .. ": " .. tostring(res))
                Widgets.showToast(_("Upload failed: ") .. tostring(res), 4)
            else
                Logger.info("Upload canceled by user: " .. filename)
            end
            if on_done then on_done(ok) end
        end, {
            is_canceled = function() return prog_dlg:isCanceled() end,
            on_progress = function(sent, total, phase)
                local pct = (total and total > 0) and math.floor((sent / total) * 100) or 0
                local sub = (phase == "finalizing")
                    and _("Finalizing catalog…")
                    or string.format("%s / %s (%d%%)", NimbusProgress.formatBytes(sent), NimbusProgress.formatBytes(total), pct)
                prog_dlg:setProgress(pct, sub)
            end,
        })
    end)
end

function Nimbus:syncCurrentBook(interactive)
    local cloud_ok = Cloud.isConfigured()
    local kosync_ok = KOSync.isConfigured()
    if not cloud_ok and not kosync_ok then return end
    local filepath, props = self:getDocProps()
    if not filepath then return end

    local now = os.time()
    if not interactive and (now - (self._last_sync_ts or 0)) < Constants.AUTO_SYNC_DEBOUNCE_SEC then
        return
    end
    self._last_sync_ts = now

    local cfg = Settings.load()
    local pmd5 = Hash.partialMD5(filepath)

    local function applyRemoteCandidate(remote, local_prog)
        if not remote or remote.device_id == cfg.device_id or not local_prog then return end
        local remote_ts = tonumber(remote.updated_at) or 0
        local local_ts = tonumber(local_prog.updated_at) or 0
        local remote_pct = tonumber(remote.percent) or 0
        local local_pct = tonumber(local_prog.percent) or 0

        if remote_ts > local_ts and remote_pct > (local_pct + Constants.WHISPERSYNC_FORWARD_THRESHOLD) then
            Logger.info(string.format("Remote progress ahead (%.1f%% vs %.1f%%) from %s", remote_pct * 100, local_pct * 100, tostring(remote.device_id)))
            if cfg.whispersync_auto_jump then
                self:jumpToRemotePosition(remote)
                Widgets.showToast(string.format(_("Jumped to %.1f%% from %s"), remote_pct * 100, tostring(remote.device_id)), 4)
            else
                Widgets.showConfirmDialog{
                    title = _("Reading Sync"),
                    text = string.format(_("Jump forward to %.1f%% from %s?"), remote_pct * 100, tostring(remote.device_id)),
                    ok_text = _("Jump"),
                    cancel_text = _("Stay Here"),
                    ok_callback = function() self:jumpToRemotePosition(remote) end,
                }
            end
        end
    end

    local local_prog = self:getCurrentProgressState(pmd5, pmd5)

    Sync.runInBackground(function()
        local best_remote = nil
        local sync_err = nil
        local not_in_cloud = false

        if cloud_ok then
            local ok_cat, catalog = false, nil
            Sync.loadCatalog(function(ok, res)
                ok_cat = ok
                catalog = res
            end)
            if not ok_cat then
                sync_err = tostring(catalog)
            else
                local book_id = Matcher.resolve(filepath, catalog, props)
                if book_id then
                    local merged = nil
                    Sync.fetchAllDeviceShards("progress.json", function(ok_p, shards)
                        if ok_p then
                            merged = Merge.mergeProgress(shards)
                            best_remote = merged[book_id]
                        end
                    end)
                    if merged then
                        Sync.saveCachedCatalog(catalog, merged)
                    end
                    if local_prog then
                        local lp = {}
                        for k, v in pairs(local_prog) do lp[k] = v end
                        lp.book_id = book_id
                        local st = Sync.loadLocalState()
                        st.progress[book_id] = lp
                        Sync.saveLocalState(st)
                        Sync.uploadDeviceProgress(st.progress)
                    end
                elseif not kosync_ok then
                    not_in_cloud = true
                end
            end
        end

        if kosync_ok then
            KOSync.pullProgress(filepath, props, function(ok_k, k_remote)
                if ok_k and k_remote then
                    if not best_remote or (tonumber(k_remote.percent) or 0) > (tonumber(best_remote.percent) or 0) then
                        best_remote = k_remote
                    end
                end
            end)
            if local_prog then
                KOSync.pushProgress(filepath, props, local_prog)
            end
        end

        return {
            best_remote = best_remote,
            sync_err = sync_err,
            not_in_cloud = not_in_cloud,
        }
    end, function(ok_bg, res)
        if not ok_bg or type(res) ~= "table" then
            if not interactive and (res == "low_memory" or res == "suspended" or res == "canceled") then
                Logger.info("Sync current book deferred: " .. tostring(res))
                return
            end
            Logger.warn("Sync current book failed: " .. tostring(res))
            if interactive then
                Widgets.showToast(_("Sync error: ") .. tostring(res), 3)
            end
            return
        end
        if res.sync_err then
            Logger.warn("Sync current book cloud error: " .. tostring(res.sync_err))
            if interactive then
                Widgets.showToast(_("Sync error: ") .. tostring(res.sync_err), 3)
            end
            return
        end
        if res.not_in_cloud then
            if interactive then
                Widgets.showToast(_("Book is not in Nimbus Cloud yet. Use 'Upload Current Book to Cloud'."), 3)
            end
            return
        end
        if self.ui and self.ui.document and res.best_remote then
            applyRemoteCandidate(res.best_remote, local_prog)
        end
        if interactive then
            Widgets.showToast(_("Reading sync complete."), 2)
        end
    end, {
        user_initiated = (interactive == true),
        priority = interactive and "foreground" or "idle_bg",
        task = "sync_current_book",
        dedupe_key = "nimbus:sync_book:" .. tostring(pmd5 or filepath),
    })
end

function Nimbus:onReaderReady()
    local cfg = Settings.load()
    if cfg.auto_sync_open then
        Logger.debug("onReaderReady: scheduling auto-sync")
        UIManager:scheduleIn(1, function()
            self:syncCurrentBook(false)
        end)
    end
end

function Nimbus:onCloseDocument()
    local cfg = Settings.load()
    if not cfg.auto_sync_close then return end

    local filepath, props = self:getDocProps()
    if not filepath then return end
    local pmd5 = Hash.partialMD5(filepath)
    local local_prog = self:getCurrentProgressState(pmd5, pmd5)
    if not local_prog then return end

    -- Update in-memory scanner cache immediately so Home Screen shows the new % without re-scanning disk
    local ok_sc, Scanner = pcall(require, "nimbus_scanner")
    if ok_sc and Scanner and type(Scanner._mem_cache) == "table" then
        for _, item in ipairs(Scanner._mem_cache) do
            if item.local_path == filepath then
                item.percent = local_prog.percent
                item.status = local_prog.status
                item.last_read_ts = local_prog.updated_at or os.time()
                break
            end
        end
    end

    -- Save local progress immediately, then push to cloud in a non-blocking background subprocess
    local cloud_ok = Cloud.isConfigured()
    local kosync_ok = KOSync.isConfigured()
    local upload_progress = nil
    if cloud_ok then
        local cached_cat, merged_prog = Sync.loadCachedCatalog()
        local book_id = Matcher.resolve(filepath, cached_cat, props)
        if book_id then
            local_prog.book_id = book_id
            local_prog.device_id = cfg.device_id
            local st = Sync.loadLocalState()
            st.progress[book_id] = local_prog
            Sync.saveLocalState(st)
            merged_prog = merged_prog or {}
            merged_prog[book_id] = local_prog
            Sync.saveCachedCatalog(cached_cat, merged_prog)
            upload_progress = st.progress
        end
    end

    UIManager:scheduleIn(0.4, function()
        Sync.runInBackground(function()
            if upload_progress then
                Sync.uploadDeviceProgress(upload_progress)
            end
            if kosync_ok then
                KOSync.pushProgress(filepath, props, local_prog)
            end
            if cfg.sync_stats and cloud_ok then
                Sync.syncStats()
            end
        end, nil, {
            priority = "interactive_bg",
            task = "close_sync",
            dedupe_key = "nimbus:close_sync:" .. tostring(pmd5 or filepath),
        })
    end)
end

function Nimbus:isForeground()
    return UILibrary.isOpen ~= nil and UILibrary.isOpen() == true
end

function Nimbus:reclaimCaches(level)
    local is_fg = self:isForeground()
    if level == "critical" or not is_fg then
        local ok_sc, Scanner = pcall(require, "nimbus_scanner")
        if ok_sc and Scanner then Scanner._mem_cache = nil end
        local ok_cov, Covers = pcall(require, "nimbus_covers")
        if ok_cov and Covers and Covers.clearMemoryCache then
            Covers.clearMemoryCache()
        end
    end
    if level == "critical" and not is_fg then
        local ok_cov, Covers = pcall(require, "nimbus_covers")
        if ok_cov and Covers and Covers.clearFetchQueue then
            Covers.clearFetchQueue()
        end
    end
end

function Nimbus:onMemoryReclaim(level)
    self:reclaimCaches(level)
    return false
end

function Nimbus:onSuspend()
    local cfg = Settings.load()
    if cfg.auto_sync_close and self.ui and self.ui.document then
        Logger.debug("onSuspend: triggering auto-sync")
        self:syncCurrentBook(false)
    end
end

function Nimbus:onNetworkConnected()
    Logger.debug("onNetworkConnected: flushing offline queue")
    Sync.runInBackground(function()
        Sync.flushQueue()
    end, nil, {
        priority = "idle_bg",
        task = "flush_queue",
        dedupe_key = "nimbus:flush_queue",
    })
end

return Nimbus
