--[[--
nimbus_ui_select.lua
Mixin for UILibrary: Multi-select mode helpers and 2-column batch actions dialog.
--]]

local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local ko_gettext = require("gettext")
local ok_loc, Localization = pcall(require, "localization_nimbus")
local _ = (ok_loc and Localization and Localization.getHelper) and Localization:getHelper() or ko_gettext

local Cloud = require("nimbus_cloud")
local Settings = require("nimbus_settings")
local Sync = require("nimbus_sync")
local Widgets = require("nimbus_ui_widgets")
local theme = require("nimbus_theme")

local SelectMixin = {}
local sc = theme.sc

function SelectMixin.getSelectionKey(item)
    if not item or item.is_folder then return nil end
    return item.local_path or item.cloud_id or item.id
end

function SelectMixin.countSelected(state)
    local n = 0
    for _ in pairs((state and state.map) or {}) do n = n + 1 end
    return n
end

function SelectMixin.isItemSelected(state, item)
    local k = SelectMixin.getSelectionKey(item)
    return k ~= nil and state ~= nil and state.map[k] ~= nil
end

function SelectMixin.toggleItemSelection(state, item)
    local k = SelectMixin.getSelectionKey(item)
    if not k or not state then return end
    if state.map[k] then
        state.map[k] = nil
    else
        state.map[k] = item
    end
end

function SelectMixin.getSelectedList(state)
    local list = {}
    for _, it in pairs((state and state.map) or {}) do
        table.insert(list, it)
    end
    return list
end

function SelectMixin.exitSelectMode(state)
    if not state then return end
    state.active = false
    state.map = {}
end

local function applyBatchStatus(selected_items, st_id, opts)
    local ok_ds, DocSettings = pcall(require, "docsettings")
    local ok_bl, BookList = pcall(require, "ui/widget/booklist")
    local cloud_status = (st_id == "complete") and "finished" or st_id
    local cfg = Settings.load()
    local local_st = Sync.loadLocalState()
    local any_cloud = false

    for _, item in ipairs(selected_items) do
        if item.local_path and ok_ds and DocSettings and DocSettings.open then
            pcall(function()
                local ds = DocSettings:open(item.local_path)
                local summary = ds:readSetting("summary") or {}
                summary.status = st_id
                ds:saveSetting("summary", summary)
                if st_id == "complete" then
                    local cur_p = ds:readSetting("percent_finished") or 0
                    if cur_p < 0.99 then ds:saveSetting("percent_finished", 1) end
                end
                ds:flush()
                if ok_bl and BookList and BookList.setBookInfoCacheProperty then
                    BookList.setBookInfoCacheProperty(item.local_path, "status", st_id)
                end
            end)
        end
        item.status = cloud_status
        local is_in_cloud = item.is_in_cloud or (item.folder ~= nil)
        local cid = item.cloud_id or (is_in_cloud and item.id) or nil
        if cid and Cloud.isConfigured() then
            local cur_rec = local_st.progress[cid] or {}
            local cur_pct = tonumber(cur_rec.percent) or tonumber(item.percent) or 0
            if cloud_status == "finished" and cur_pct < 0.99 then cur_pct = 1 end
            local_st.progress[cid] = {
                book_id = cid,
                partial_md5 = (item.hashes and item.hashes.partial_md5) or item.partial_md5 or cur_rec.partial_md5,
                percent = cur_pct,
                status = cloud_status,
                xpointer = cur_rec.xpointer,
                updated_at = os.time(),
                device_id = cfg.device_id,
            }
            any_cloud = true
        end
    end

    if any_cloud then
        Sync.saveLocalState(local_st)
        local cached_cat, cached_mp = Sync.loadCachedCatalog()
        cached_mp = cached_mp or {}
        for cid, rec in pairs(local_st.progress) do
            cached_mp[cid] = rec
        end
        Sync.saveCachedCatalog(cached_cat, cached_mp)
        local upload_prog = local_st.progress
        Sync.runInBackground(function()
            Sync.uploadDeviceProgress(upload_prog)
        end, nil, {
            priority = "interactive_bg",
            task = "upload_progress",
            dedupe_key = "nimbus:upload_progress",
        })
    end

    if opts.on_exit_select then opts.on_exit_select() end
    if opts.on_refresh then opts.on_refresh(true) end
end

local function buildBatchStatusRow(selected_items, inner_w, closeDlg, opts)
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
        table.insert(row_items, Widgets.createButton{
            text = st.label,
            width = btn_w,
            padding = sc(6),
            padding_h = sc(4),
            text_font_size = theme.fs and theme.fs("detail") or 14,
            callback = function()
                closeDlg()
                applyBatchStatus(selected_items, st.id, opts)
            end,
        })
    end
    return HorizontalGroup:new(row_items)
end

function SelectMixin.showBatchActionsDialog(selected_items, opts)
    opts = opts or {}
    if not selected_items or #selected_items == 0 then
        Widgets.showToast(_("No books selected."), 2)
        return
    end

    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    local ok_fmu, filemanagerutil = pcall(require, "apps/filemanager/filemanagerutil")
    local fm = ok_fm and FileManager and FileManager.instance or nil
    local fmu = ok_fmu and filemanagerutil or nil

    local local_items, local_map = {}, {}
    local unsynced_items, offload_items, cloud_items = {}, {}, {}
    for _, item in ipairs(selected_items) do
        local is_in_cloud = item.is_in_cloud or (item.folder ~= nil)
        if item.local_path then
            table.insert(local_items, item)
            local_map[item.local_path] = true
            if is_in_cloud then
                table.insert(offload_items, item)
            else
                table.insert(unsynced_items, item)
            end
        end
        if is_in_cloud then
            table.insert(cloud_items, item)
        end
    end

    Widgets.showCardDialog{
        title = string.format(_("%d Selected"), #selected_items),
        body_widget = function(inner_w, closeDlg)
            local actions = {}
            local noop = function() end
            local finish_refresh = function()
                if opts.on_exit_select then opts.on_exit_select() end
                if opts.on_refresh then opts.on_refresh(true) end
            end

            if #unsynced_items > 0 and opts.on_upload_batch then
                table.insert(actions, {
                    text = string.format(_("Upload (%d)"), #unsynced_items),
                    is_primary = true,
                    callback = function()
                        closeDlg()
                        if opts.on_exit_select then opts.on_exit_select() end
                        opts.on_upload_batch(unsynced_items)
                    end,
                })
            end

            if #offload_items > 0 and opts.on_offload_batch then
                table.insert(actions, {
                    text = string.format(_("Offload (%d)"), #offload_items),
                    callback = function()
                        closeDlg()
                        Widgets.showConfirmDialog{
                            title = _("Offload Local Books"),
                            text = string.format(_("Delete %d local book file(s) from this device? Cloud copies and progress remain safe."), #offload_items),
                            ok_text = _("Offload"),
                            cancel_text = _("Cancel"),
                            ok_callback = function()
                                if opts.on_exit_select then opts.on_exit_select() end
                                opts.on_offload_batch(offload_items)
                            end,
                        }
                    end,
                })
            end

            if #local_items > 0 and fm then
                table.insert(actions, {
                    text = ko_gettext("Cut"),
                    callback = function()
                        closeDlg()
                        if #local_items == 1 and fm.cutFile then
                            fm:cutFile(local_items[1].local_path)
                        else
                            fm.selected_files = local_map
                            fm.cutfile = true
                        end
                        if opts.on_exit_select then opts.on_exit_select() end
                        Widgets.showToast(string.format(_("Cut %d book(s) to clipboard."), #local_items), 2)
                    end,
                })
                table.insert(actions, {
                    text = ko_gettext("Copy"),
                    callback = function()
                        closeDlg()
                        if #local_items == 1 and fm.copyFile then
                            fm:copyFile(local_items[1].local_path)
                        else
                            fm.selected_files = local_map
                            fm.cutfile = false
                        end
                        if opts.on_exit_select then opts.on_exit_select() end
                        Widgets.showToast(string.format(_("Copied %d book(s) to clipboard."), #local_items), 2)
                    end,
                })
            end

            local has_batch_clip = fm and fm.selected_files and next(fm.selected_files) ~= nil
            if fm and opts.current_folder and (fm.clipboard or has_batch_clip) then
                table.insert(actions, {
                    text = ko_gettext("Paste"),
                    callback = function()
                        closeDlg()
                        if fm.clipboard and fm.pasteFileFromClipboard then
                            fm:pasteFileFromClipboard(opts.current_folder)
                            finish_refresh()
                        elseif has_batch_clip and fm.showCopyMoveSelectedFilesDialog then
                            fm:showCopyMoveSelectedFilesDialog(finish_refresh, opts.current_folder)
                        end
                    end,
                })
            end

            if #local_items > 0 and fm and fm.collections then
                if fm.collections.genAddToCollectionButton then
                    local btn = fm.collections:genAddToCollectionButton(local_map, noop, finish_refresh)
                    if btn and btn.enabled ~= false and btn.callback then
                        table.insert(actions, {
                            text = btn.text,
                            callback = function()
                                closeDlg()
                                btn.callback()
                            end,
                        })
                    end
                end
                if fm.collections.genExportHighlightsButton then
                    local btn = fm.collections:genExportHighlightsButton(local_map, noop)
                    if btn and btn.enabled ~= false and btn.callback then
                        table.insert(actions, {
                            text = btn.text,
                            callback = function()
                                closeDlg()
                                btn.callback()
                            end,
                        })
                    end
                end
            end

            if #local_items > 0 and fmu and fmu.genMultipleResetSettingsButton then
                local btn = fmu.genMultipleResetSettingsButton(local_map, finish_refresh)
                if btn and btn.enabled ~= false and btn.callback then
                    table.insert(actions, {
                        text = btn.text,
                        callback = function()
                            closeDlg()
                            btn.callback()
                        end,
                    })
                end
            end

            if #local_items > 0 then
                table.insert(actions, {
                    text = string.format(_("Delete (%d)"), #local_items),
                    callback = function()
                        closeDlg()
                        Widgets.showConfirmDialog{
                            title = _("Delete Local Books"),
                            text = string.format(_("Permanently delete %d selected file(s) from this device?"), #local_items),
                            ok_text = _("Delete"),
                            cancel_text = _("Cancel"),
                            ok_callback = function()
                                for _, it in ipairs(local_items) do
                                    if fm and fm.deleteFile then
                                        pcall(fm.deleteFile, fm, it.local_path, true)
                                    else
                                        pcall(os.remove, it.local_path)
                                    end
                                end
                                finish_refresh()
                                Widgets.showToast(string.format(_("Deleted %d file(s)."), #local_items), 2.5)
                            end,
                        }
                    end,
                })
            end

            if #cloud_items > 0 and opts.on_delete_cloud_batch then
                table.insert(actions, {
                    text = string.format(_("Delete Cloud (%d)"), #cloud_items),
                    callback = function()
                        closeDlg()
                        Widgets.showConfirmDialog{
                            title = _("Delete from Cloud"),
                            text = string.format(_("Delete %d selected book(s) from Nimbus Cloud?"), #cloud_items),
                            ok_text = _("Delete"),
                            cancel_text = _("Cancel"),
                            ok_callback = function()
                                if opts.on_exit_select then opts.on_exit_select() end
                                opts.on_delete_cloud_batch(cloud_items)
                            end,
                        }
                    end,
                })
            end

            local status_row = buildBatchStatusRow(selected_items, inner_w, closeDlg, opts)
            local grid_w = Widgets.createActionGrid(actions, inner_w, {
                cols = 2,
                gap = sc(8),
                gap_v = sc(8),
                padding = sc(7),
                padding_h = sc(6),
            })
            return VerticalGroup:new{
                align = "left",
                status_row,
                VerticalSpan:new{ width = sc(10) },
                grid_w,
            }
        end,
        buttons = { { text = _("Cancel") } },
    }
end

return SelectMixin
