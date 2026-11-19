--[[--
main.lua
Entry point for nimbus.koplugin (KOReader Plugin).
--]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local _ = require("gettext")

local Constants = require("nimbus_constants")
local Settings = require("nimbus_settings")
local Cloud = require("nimbus_cloud")
local Hash = require("nimbus_hash")
local Matcher = require("nimbus_matcher")
local Merge = require("nimbus_merge")
local Sync = require("nimbus_sync")
local UILibrary = require("nimbus_ui_library")
local UISettings = require("nimbus_ui_settings")

local Nimbus = WidgetContainer:extend{
    name = "nimbus",
    is_doc_only = false,
}

function Nimbus:init()
    self._last_sync_ts = 0
    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
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

function Nimbus:openLibrary()
    UILibrary.show(function(filepath)
        self:openBookFile(filepath)
    end)
end

function Nimbus:addToMainMenu(menu_items)
    local cfg = Settings.load()
    menu_items.nimbus = {
        text = _("Nimbus Cloud"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Open Cloud Library"),
                callback = function()
                    self:openLibrary()
                end,
            },
            {
                text = _("Sync Current Book Now"),
                enabled_func = function()
                    return self.ui and self.ui.document ~= nil
                end,
                callback = function()
                    self:syncCurrentBook(true)
                end,
            },
            {
                text = _("Upload Current Book to Cloud"),
                enabled_func = function()
                    return self.ui and self.ui.document ~= nil
                end,
                callback = function()
                    self:uploadCurrentBook()
                end,
            },
            {
                text = _("Sync Reading Statistics"),
                callback = function()
                    Sync.syncStats(function(ok, res)
                        UIManager:show(InfoMessage:new{
                            text = ok and string.format(_("Synced %d reading session(s)."), tonumber(res) or 0)
                                or (_("Stats sync failed: ") .. tostring(res)),
                            timeout = 3,
                        })
                    end)
                end,
                separator = true,
            },
            {
                text = _("Auto-sync on Book Open/Close"),
                checked_func = function() return Settings.load().auto_sync_open end,
                callback = function()
                    local c = Settings.load()
                    c.auto_sync_open = not c.auto_sync_open
                    c.auto_sync_close = c.auto_sync_open
                    Settings.save(c)
                end,
            },
            {
                text = _("Whispersync Auto-Jump Forward"),
                checked_func = function() return Settings.load().whispersync_auto_jump end,
                callback = function()
                    local c = Settings.load()
                    c.whispersync_auto_jump = not c.whispersync_auto_jump
                    Settings.save(c)
                end,
            },
            {
                text = _("Sync Highlights & Notes"),
                checked_func = function() return Settings.load().sync_highlights end,
                callback = function()
                    local c = Settings.load()
                    c.sync_highlights = not c.sync_highlights
                    Settings.save(c)
                end,
            },
            {
                text = _("Sync Reading Statistics"),
                checked_func = function() return Settings.load().sync_stats end,
                callback = function()
                    local c = Settings.load()
                    c.sync_stats = not c.sync_stats
                    Settings.save(c)
                end,
                separator = true,
            },
            {
                text = _("Account & Settings…"),
                callback = function()
                    UISettings.showProviderMenu()
                end,
            },
        },
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

function Nimbus:uploadCurrentBook()
    local filepath, props = self:getDocProps()
    if not filepath then return end
    local msg = InfoMessage:new{ text = _("Uploading book to Nimbus Cloud…") }
    UIManager:show(msg)
    UIManager:forceRePaint()
    Sync.uploadBook(filepath, props, nil, function(ok, res)
        UIManager:close(msg)
        UIManager:show(InfoMessage:new{
            text = ok and string.format(_("Uploaded '%s' to Nimbus Cloud!"), tostring(res.title))
                or (_("Upload failed: ") .. tostring(res)),
            timeout = 3,
        })
    end)
end

function Nimbus:syncCurrentBook(interactive)
    if not Cloud.isConfigured() then return end
    local filepath, props = self:getDocProps()
    if not filepath then return end

    local now = os.time()
    if not interactive and (now - (self._last_sync_ts or 0)) < Constants.AUTO_SYNC_DEBOUNCE_SEC then
        return
    end
    self._last_sync_ts = now

    Sync.loadCatalog(function(ok_cat, catalog)
        if not ok_cat then
            if interactive then
                UIManager:show(InfoMessage:new{ text = _("Sync error: ") .. tostring(catalog), timeout = 3 })
            end
            return
        end

        local book_id = Matcher.resolve(filepath, catalog, props)
        if not book_id then
            if interactive then
                UIManager:show(InfoMessage:new{ text = _("Book is not in Nimbus Cloud yet. Use 'Upload Current Book to Cloud'."), timeout = 3 })
            end
            return
        end

        local cfg = Settings.load()
        local pmd5 = Hash.partialMD5(filepath)
        local local_prog = self:getCurrentProgressState(book_id, pmd5)

        -- Pull remote progress shards & apply Whispersync rule
        Sync.fetchAllDeviceShards("progress.json", function(ok_p, shards)
            if ok_p then
                local merged = Merge.mergeProgress(shards)
                local remote = merged[book_id]
                if remote and remote.device_id ~= cfg.device_id and local_prog then
                    local remote_ts = tonumber(remote.updated_at) or 0
                    local local_ts = tonumber(local_prog.updated_at) or 0
                    local remote_pct = tonumber(remote.percent) or 0
                    local local_pct = tonumber(local_prog.percent) or 0

                    if remote_ts > local_ts and remote_pct > (local_pct + Constants.WHISPERSYNC_FORWARD_THRESHOLD) then
                        if cfg.whispersync_auto_jump then
                            self:jumpToRemotePosition(remote)
                            UIManager:show(InfoMessage:new{
                                text = string.format(_("Jumped to %.1f%% from %s"), remote_pct * 100, tostring(remote.device_id)),
                                timeout = 4,
                            })
                        else
                            UIManager:show(ConfirmBox:new{
                                text = string.format(_("Jump forward to %.1f%% from %s?"), remote_pct * 100, tostring(remote.device_id)),
                                ok_callback = function() self:jumpToRemotePosition(remote) end,
                            })
                        end
                    end
                end
            end
        end)

        -- Push local progress
        if local_prog then
            local st = Sync.loadLocalState()
            st.progress[book_id] = local_prog
            Sync.saveLocalState(st)
            Sync.uploadDeviceProgress(st.progress)
        end

        if interactive then
            UIManager:show(InfoMessage:new{ text = _("Nimbus sync complete."), timeout = 2 })
        end
    end)
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
    if cfg.auto_sync_close then
        self:syncCurrentBook(false)
        if cfg.sync_stats then
            Sync.syncStats()
        end
    end
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
