--[[--
nimbus_ui_library.lua
Cloud Library Shelf UI for nimbus.koplugin:
- Filter tabs (All / On Device / In Cloud / Reading / Finished)
- Search by title / author / series / tag
- Book detail dialog with Download & Open, Offload from Device, and Link Local Book
--]]

local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local InfoMessage = require("ui/widget/infomessage")
local ButtonDialog = require("ui/widget/buttondialog")
local InputDialog = require("ui/widget/inputdialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Screen = require("device").screen
local ok_util, util = pcall(require, "util")
local _ = require("gettext")

local Settings = require("nimbus_settings")
local Cloud = require("nimbus_cloud")
local Sync = require("nimbus_sync")
local Merge = require("nimbus_merge")

local UILibrary = {}

local function fileExists(path)
    if not path then return false end
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

local function getLocalBookPath(entry)
    local links = Settings.loadBookLinks()
    local linked = links.by_id[entry.id]
    if linked and fileExists(linked) then
        return linked
    end
    local cfg = Settings.load()
    local candidate = cfg.download_dir .. "/" .. (entry.filename or (entry.id .. "." .. (entry.format or "epub")))
    if fileExists(candidate) then
        return candidate
    end
    return nil
end

local function showBookDetail(entry, merged_prog, on_open_book, on_refresh)
    local local_path = getLocalBookPath(entry)
    local authors_str = type(entry.authors) == "table" and table.concat(entry.authors, ", ") or tostring(entry.authors or "")
    local pct_str = merged_prog and string.format("%.1f%% (%s)", (merged_prog.percent or 0) * 100, merged_prog.status or "reading") or _("Unread")
    local series_str = entry.series and (entry.series .. (entry.series_index and (" #" .. tostring(entry.series_index)) or "")) or _("None")

    local detail_text = string.format(
        _("Title: %s\nAuthor(s): %s\nSeries: %s\nFormat: %s\nProgress: %s\nStatus: %s"),
        tostring(entry.title),
        authors_str,
        series_str,
        tostring(entry.format or ""):upper(),
        pct_str,
        local_path and _("Downloaded on Device") or _("In Cloud Only")
    )

    local dlg
    local buttons = {}

    if local_path then
        table.insert(buttons, {
            {
                text = _("Open Book"),
                is_enter_default = true,
                callback = function()
                    UIManager:close(dlg)
                    if on_open_book then on_open_book(local_path) end
                end,
            },
            {
                text = _("Offload from Device"),
                callback = function()
                    UIManager:close(dlg)
                    UIManager:show(ConfirmBox:new{
                        text = _("Delete the local file from this device? Your book, progress, and highlights remain safe in Nimbus Cloud."),
                        ok_callback = function()
                            os.remove(local_path)
                            Settings.unlinkBook(entry.id, local_path)
                            UIManager:show(InfoMessage:new{ text = _("Offloaded from device."), timeout = 2 })
                            if on_refresh then on_refresh() end
                        end,
                    })
                end,
            },
        })
    else
        table.insert(buttons, {
            {
                text = _("Download & Open"),
                is_enter_default = true,
                callback = function()
                    UIManager:close(dlg)
                    local cfg = Settings.load()
                    if ok_util and util and util.makePath then
                        util.makePath(cfg.download_dir)
                    end
                    local dest = cfg.download_dir .. "/" .. (entry.filename or (entry.id .. "." .. (entry.format or "epub")))
                    local msg = InfoMessage:new{ text = _("Downloading ") .. tostring(entry.title) .. "…" }
                    UIManager:show(msg)
                    UIManager:forceRePaint()
                    Cloud.downloadFile(entry.folder .. "/" .. entry.filename, dest, function(ok, err)
                        UIManager:close(msg)
                        if ok then
                            Settings.linkBook(dest, entry.id)
                            if on_open_book then on_open_book(dest) end
                        else
                            UIManager:show(InfoMessage:new{ text = _("Download failed: ") .. tostring(err) })
                        end
                    end)
                end,
            },
        })
    end

    table.insert(buttons, {
        {
            text = _("Close"),
            callback = function() UIManager:close(dlg) end,
        },
    })

    dlg = ButtonDialog:new{
        title = entry.title,
        text = detail_text,
        buttons = buttons,
    }
    UIManager:show(dlg)
end

function UILibrary.show(on_open_book)
    if not Cloud.isConfigured() then
        UIManager:show(InfoMessage:new{
            text = _("Please configure a Nimbus Cloud account first in Nimbus Cloud → Account & Settings."),
            timeout = 4,
        })
        return
    end

    local loading = InfoMessage:new{ text = _("Loading Nimbus Cloud Library…") }
    UIManager:show(loading)
    UIManager:forceRePaint()

    Sync.loadCatalog(function(ok_cat, catalog_or_err)
        if not ok_cat then
            UIManager:close(loading)
            UIManager:show(InfoMessage:new{ text = _("Failed to load catalog: ") .. tostring(catalog_or_err) })
            return
        end

        local merged_progress = {}
        Sync.fetchAllDeviceShards("progress.json", function(ok_p, shards)
            if ok_p then
                merged_progress = Merge.mergeProgress(shards)
            end
        end)
        UIManager:close(loading)

        local current_filter = "all"
        local search_query = ""
        local menu

        local function buildItems()
            local items = {
                {
                    text = string.format(_("Filter: [%s]  |  Search: %s"),
                        current_filter:upper(),
                        search_query ~= "" and search_query or _("(none)")),
                    callback = function()
                        local fdlg
                        fdlg = ButtonDialog:new{
                            title = _("Filter & Search"),
                            buttons = {
                                {
                                    { text = _("All"), callback = function() UIManager:close(fdlg); current_filter = "all"; menu:switchItemTable(nil, buildItems()) end },
                                    { text = _("On Device"), callback = function() UIManager:close(fdlg); current_filter = "device"; menu:switchItemTable(nil, buildItems()) end },
                                    { text = _("In Cloud"), callback = function() UIManager:close(fdlg); current_filter = "cloud"; menu:switchItemTable(nil, buildItems()) end },
                                },
                                {
                                    { text = _("Reading"), callback = function() UIManager:close(fdlg); current_filter = "reading"; menu:switchItemTable(nil, buildItems()) end },
                                    { text = _("Finished"), callback = function() UIManager:close(fdlg); current_filter = "finished"; menu:switchItemTable(nil, buildItems()) end },
                                    {
                                        text = _("Search…"),
                                        callback = function()
                                            UIManager:close(fdlg)
                                            local sdlg
                                            sdlg = InputDialog:new{
                                                title = _("Search Cloud Library"),
                                                input = search_query,
                                                buttons = {
                                                    {
                                                        { text = _("Clear"), callback = function() UIManager:close(sdlg); search_query = ""; menu:switchItemTable(nil, buildItems()) end },
                                                        { text = _("Search"), is_enter_default = true, callback = function() search_query = sdlg:getInputText() or ""; UIManager:close(sdlg); menu:switchItemTable(nil, buildItems()) end },
                                                    },
                                                },
                                            }
                                            UIManager:show(sdlg)
                                            sdlg:onShowKeyboard()
                                        end,
                                    },
                                },
                            },
                        }
                        UIManager:show(fdlg)
                    end,
                },
            }

            local sorted = {}
            for _, entry in pairs(catalog_or_err.books or {}) do
                if not entry.deleted then
                    table.insert(sorted, entry)
                end
            end
            table.sort(sorted, function(a, b)
                return tostring(a.title or ""):lower() < tostring(b.title or ""):lower()
            end)

            local q_lower = search_query:lower()
            for _, entry in ipairs(sorted) do
                local local_path = getLocalBookPath(entry)
                local prog = merged_progress[entry.id]
                local status = prog and prog.status or "unread"
                local pass_filter = (current_filter == "all")
                    or (current_filter == "device" and local_path ~= nil)
                    or (current_filter == "cloud" and local_path == nil)
                    or (current_filter == "reading" and status == "reading")
                    or (current_filter == "finished" and status == "finished")

                local authors_str = type(entry.authors) == "table" and table.concat(entry.authors, ", ") or tostring(entry.authors or "")
                local hay = (tostring(entry.title) .. " " .. authors_str .. " " .. tostring(entry.series or "")).lower()
                local pass_search = (q_lower == "") or hay:find(q_lower, 1, true) ~= nil

                if pass_filter and pass_search then
                    local badge = local_path and "📱" or "☁️"
                    local pct_str = prog and string.format(" · %d%%", math.floor((prog.percent or 0) * 100 + 0.5)) or ""
                    table.insert(items, {
                        text = string.format("%s %s — %s%s", badge, tostring(entry.title), authors_str, pct_str),
                        callback = function()
                            showBookDetail(entry, prog, function(path)
                                UIManager:close(menu)
                                if on_open_book then on_open_book(path) end
                            end, function()
                                menu:switchItemTable(nil, buildItems())
                            end)
                        end,
                    })
                end
            end
            return items
        end

        menu = Menu:new{
            title = _("Nimbus Cloud Library"),
            item_table = buildItems(),
            width = Screen:getWidth() * 0.92,
            height = Screen:getHeight() * 0.88,
        }
        UIManager:show(menu)
    end)
end

return UILibrary
