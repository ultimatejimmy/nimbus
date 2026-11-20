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

local function embedIntoFileManager(fm_self)
    if not fm_self or not fm_self[1] or not fm_self[1][1] then return end
    if not Settings.load().use_as_home_screen or fm_self._nimbus_browsing_files then return end
    if fm_self._nimbus_embedded_view and fm_self[1][1] == fm_self._nimbus_embedded_view then return end

    local ok_err, err = pcall(function()
        fm_self._nimbus_orig_fc = fm_self._nimbus_orig_fc or fm_self[1][1]
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
            on_sync_now = function()
                Sync.syncStats()
            end,
        })
        fm_self._nimbus_embedded_view = view
        fm_self[1][1] = view
    end)
    if not ok_err then
        local ok_log, logger = pcall(require, "logger")
        if ok_log and logger and logger.warn then
            logger.warn("Nimbus: failed to embed into FileManager, falling back:", tostring(err))
        end
        if fm_self._nimbus_orig_fc then
            fm_self[1][1] = fm_self._nimbus_orig_fc
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
    if ok_loc and Localization and Localization.ensureInit then
        Localization:ensureInit(self.path)
    end
    injectIntoToolsMenu()
    local cfg = Settings.load()
    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    installHomeScreenPatch()
    if cfg.use_as_home_screen then
        if _G.G_reader_settings and _G.G_reader_settings.saveSetting then
            _G.G_reader_settings:saveSetting("start_with", "filemanager")
        end
        if self.ui and not self.ui.document and self.ui[1] then
            embedIntoFileManager(self.ui)
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
            Sync.syncStats()
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
    local status = "reading"
    if pct >= 0.99 then status = "finished" elseif pct <= 0 then status = "unread" end
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
    local prog_dlg = NimbusProgress:new{
        title = _("Uploading to Nimbus Cloud"),
        subtitle = _("Preparing upload…"),
        detail = filename,
        progress = 0,
    }
    prog_dlg:show()

    Sync.uploadBook(filepath, props, nil, function(ok, res)
        prog_dlg:close()
        if ok then
            Widgets.showToast(string.format(_("Uploaded '%s' to Nimbus Cloud!"), tostring(res.title)), 3)
        elseif res ~= "canceled" then
            Widgets.showToast(_("Upload failed: ") .. tostring(res), 4)
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

    local best_remote = nil
    local local_prog = self:getCurrentProgressState(pmd5, pmd5)

    if cloud_ok then
        Sync.loadCatalog(function(ok_cat, catalog)
            if not ok_cat then
                if interactive then
                    Widgets.showToast(_("Sync error: ") .. tostring(catalog), 3)
                end
                return
            end

            local book_id = Matcher.resolve(filepath, catalog, props)
            if book_id then
                local_prog = self:getCurrentProgressState(book_id, pmd5)
                Sync.fetchAllDeviceShards("progress.json", function(ok_p, shards)
                    if ok_p then
                        local merged = Merge.mergeProgress(shards)
                        best_remote = merged[book_id]
                    end
                end)

                if local_prog then
                    local st = Sync.loadLocalState()
                    st.progress[book_id] = local_prog
                    Sync.saveLocalState(st)
                    Sync.uploadDeviceProgress(st.progress)
                end
            elseif interactive and not kosync_ok then
                Widgets.showToast(_("Book is not in Nimbus Cloud yet. Use 'Upload Current Book to Cloud'."), 3)
            end
        end)
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

    applyRemoteCandidate(best_remote, local_prog)

    if interactive then
        Widgets.showToast(_("Reading sync complete."), 2)
    end
end

function Nimbus:onReaderReady()
    local cfg = Settings.load()
    if cfg.auto_sync_open then
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
                break
            end
        end
    end

    -- Defer blocking HTTPS uploads until after Home Screen has painted
    UIManager:scheduleIn(0.6, function()
        if Cloud.isConfigured() then
            local cached_cat = Sync.loadCachedCatalog()
            local book_id = Matcher.resolve(filepath, cached_cat, props)
            if book_id then
                local_prog.book_id = book_id
                local st = Sync.loadLocalState()
                st.progress[book_id] = local_prog
                Sync.saveLocalState(st)
                Sync.uploadDeviceProgress(st.progress)
            end
        end
        if KOSync.isConfigured() then
            KOSync.pushProgress(filepath, props, local_prog)
        end
        if cfg.sync_stats and Cloud.isConfigured() then
            Sync.syncStats()
        end
    end)
end

function Nimbus:onSuspend()
    local cfg = Settings.load()
    if cfg.auto_sync_close and self.ui and self.ui.document then
        self:syncCurrentBook(false)
    end
end

function Nimbus:onNetworkConnected()
    Sync.flushQueue()
end

return Nimbus
