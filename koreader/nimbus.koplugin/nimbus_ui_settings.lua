--[[--
nimbus_ui_settings.lua
Storefront/Libbee/Beeline card-styled Cloud Storage, Library, & Reading Sync Settings
organized into compact submenus, plus QR OAuth, WebDAV, and CrossPoint/Sink/KOSync setup.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local NetworkMgr = require("ui/network/manager")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local ok_qr, QRWidget = pcall(require, "ui/widget/qrwidget")
if not ok_qr or not QRWidget then
    QRWidget = nil
end
local _ = require("gettext")

local Constants = require("nimbus_constants")
local Settings = require("nimbus_settings")
local Cloud = require("nimbus_cloud")
local OAuth = require("nimbus_cloud_oauth")
local KOSync = require("nimbus_kosync")
local Widgets = require("nimbus_ui_widgets")
local theme = require("nimbus_theme")

local UISettings = {}
local sc = theme.sc

local function refreshMenuState(refresh_cb, touch_menu)
    if touch_menu and touch_menu.updateItems then
        touch_menu:updateItems()
    end
    if type(refresh_cb) == "function" then
        refresh_cb()
    end
end

local function rightChevron(text, bold_black)
    return TextWidget:new{
        text = text .. " ›",
        face = Font:getFace("cfont", 14),
        bold = bold_black,
        fgcolor = bold_black and Blitbuffer.COLOR_BLACK or theme.color_label_dim,
    }
end

--- Shows the provider-specific configuration card dialog.
function UISettings.showCloudConfigDialog(provider, on_finish_cb)
    local cfg = Settings.load()
    provider = provider or cfg.provider

    if provider == Constants.CLOUD_PROVIDERS.GDRIVE
        or provider == Constants.CLOUD_PROVIDERS.ONEDRIVE
        or provider == Constants.CLOUD_PROVIDERS.DROPBOX then
        local prov_label = Cloud.getProviderLabel(provider)

        if Cloud.isConfigured(provider) then
            Widgets.showCardDialog{
                title = string.format(_("%s Account"), prov_label),
                on_close = function()
                    if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                end,
                body_widget = function(inner_w, closeDlg)
                    local vg = VerticalGroup:new{ align = "left" }
                    table.insert(vg, Widgets.createSettingRow(_("Test Connection"),
                        rightChevron(_("Run"), false), inner_w, function()
                            Widgets.showToast(string.format(_("Testing %s connection..."), prov_label), 10)
                            UIManager:nextTick(function()
                                Cloud.testConnection(function(ok, msg)
                                    Widgets.showToast(
                                        ok and string.format(_("Connected: %s"), tostring(msg))
                                            or string.format(_("Connection failed: %s"), tostring(msg)),
                                        4
                                    )
                                end)
                            end)
                        end))
                    table.insert(vg, Widgets.createSettingRow(_("Disconnect/Log Out"),
                        rightChevron("", false), inner_w, function()
                            closeDlg()
                            OAuth.clearTokens(provider)
                            Widgets.showToast(string.format(_("Disconnected from %s."), prov_label), 3)
                            if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                        end))
                    return vg
                end,
                buttons = {
                    {
                        text = _("Done"),
                        is_primary = true,
                        callback = function()
                            if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                        end,
                    },
                },
            }
            return
        end

        NetworkMgr:runWhenOnline(function()
            Widgets.showToast(string.format(_("Contacting %s..."), prov_label), 10)

            OAuth.requestDeviceCode(provider, {}, function(ok, info)
                Widgets.closeToast()

                if not ok or not info then
                    Widgets.showConfirmDialog{
                        title = string.format(_("Connect %s"), prov_label),
                        text = string.format(_("Failed to start %s authorization:\n%s"), prov_label, tostring(info)),
                        ok_text = _("Retry"),
                        cancel_text = _("Cancel"),
                        ok_callback = function()
                            UISettings.showCloudConfigDialog(provider, on_finish_cb)
                        end,
                        cancel_callback = function()
                            if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                        end,
                    }
                    return
                end

                local flow_active = true
                local close_auth_card = nil
                local function closeAuth()
                    flow_active = false
                    if close_auth_card then
                        local fn = close_auth_card
                        close_auth_card = nil
                        fn()
                    end
                end

                local disp_url = info.verification_url
                    or (provider == Constants.CLOUD_PROVIDERS.ONEDRIVE and "https://www.microsoft.com/link"
                        or (provider == Constants.CLOUD_PROVIDERS.DROPBOX and (Constants.OAUTH_DEFAULT_RELAY_URL .. "/link")
                            or "https://www.google.com/device"))

                local qr_target_url = info.verification_uri_complete or info.verification_url or disp_url
                if provider == Constants.CLOUD_PROVIDERS.DROPBOX and info.user_code and info.user_code ~= "" then
                    qr_target_url = disp_url .. "?session=" .. info.user_code
                end

                local _, closeFn = Widgets.showCardDialog{
                    title = string.format(_("Connect %s"), prov_label),
                    on_close = function()
                        flow_active = false
                        if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                    end,
                    body_widget = function(inner_w)
                        local content_items = { align = "center" }
                        if QRWidget then
                            local qr_size = math.min(sc(150), math.floor(inner_w * 0.45))
                            local ok_gen, qr_img = pcall(function()
                                return QRWidget:new{
                                    text = qr_target_url,
                                    width = qr_size,
                                    height = qr_size,
                                }
                            end)
                            if ok_gen and qr_img then
                                table.insert(content_items, CenterContainer:new{
                                    dimen = Geom:new{ w = inner_w, h = qr_size + sc(12) },
                                    FrameContainer:new{
                                        background = Blitbuffer.COLOR_WHITE,
                                        padding = sc(6),
                                        bordersize = sc(1),
                                        color = Blitbuffer.COLOR_BLACK,
                                        qr_img,
                                    },
                                })
                                table.insert(content_items, VerticalSpan:new{ width = sc(6) })
                            end
                        end

                        table.insert(content_items, TextBoxWidget:new{
                            text = _("On your phone or computer, open:"),
                            face = Font:getFace("cfont", 16),
                            alignment = "center",
                            width = inner_w,
                        })
                        table.insert(content_items, VerticalSpan:new{ width = sc(4) })
                        table.insert(content_items, TextBoxWidget:new{
                            text = disp_url,
                            face = Font:getFace("cfont", 17),
                            bold = true,
                            alignment = "center",
                            width = inner_w,
                        })
                        table.insert(content_items, VerticalSpan:new{ width = sc(8) })
                        table.insert(content_items, TextBoxWidget:new{
                            text = _("And enter this code:"),
                            face = Font:getFace("cfont", 16),
                            alignment = "center",
                            width = inner_w,
                        })
                        table.insert(content_items, VerticalSpan:new{ width = sc(6) })
                        table.insert(content_items, FrameContainer:new{
                            bordersize = sc(2),
                            color = Blitbuffer.COLOR_BLACK,
                            radius = sc(4),
                            padding_top = sc(6),
                            padding_bottom = sc(6),
                            padding_left = sc(20),
                            padding_right = sc(20),
                            background = Blitbuffer.COLOR_WHITE,
                            TextWidget:new{
                                text = info.user_code or "",
                                face = Font:getFace("tfont", 28),
                                bold = true,
                            },
                        })
                        table.insert(content_items, VerticalSpan:new{ width = sc(10) })
                        table.insert(content_items, TextBoxWidget:new{
                            text = _("Waiting for authorization..."),
                            face = Font:getFace("cfont", 15),
                            fgcolor = theme.color_label_dim,
                            alignment = "center",
                            width = inner_w,
                        })
                        return VerticalGroup:new(content_items)
                    end,
                    buttons = {
                        {
                            text = _("Cancel"),
                            callback = function()
                                flow_active = false
                                if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                            end,
                        },
                    },
                }
                close_auth_card = closeFn

                local poll_interval = math.max(3, info.interval or 5)
                local consecutive_errors = 0
                local MAX_CONSECUTIVE_ERRORS = 5

                local function pollStep()
                    if not flow_active then return end
                    OAuth.pollToken(provider, info.device_code, {}, function(poll_ok, token_data, raw_res)
                        if not flow_active then return end

                        if poll_ok and token_data and token_data.access_token then
                            closeAuth()
                            OAuth.saveTokens(provider, token_data)
                            cfg.provider = provider
                            cfg.provider_user_selected = true
                            Settings.save(cfg)
                            Widgets.showToast(string.format(_("Connected to %s successfully!"), prov_label), 3)
                            if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                            return
                        end

                        if token_data == "authorization_pending" then
                            consecutive_errors = 0
                            UIManager:scheduleIn(poll_interval, pollStep)
                        elseif token_data == "slow_down" then
                            consecutive_errors = 0
                            poll_interval = poll_interval + 5
                            UIManager:scheduleIn(poll_interval, pollStep)
                        elseif token_data == "access_denied" then
                            closeAuth()
                            Widgets.showToast(string.format(_("%s authorization was denied."), prov_label), 4)
                            if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                        elseif token_data == "expired_token" then
                            closeAuth()
                            Widgets.showToast(_("Authorization code expired. Please try again."), 4)
                            if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                        elseif token_data == "invalid_request" or token_data == "invalid_client"
                            or token_data == "unauthorized_client" or token_data == "server_error"
                            or token_data == "relay_error" then
                            closeAuth()
                            local detail = (raw_res and (raw_res.error_description or raw_res.error)) or token_data
                            Widgets.showToast(string.format(_("%s authentication error: %s"), prov_label, tostring(detail)), 5)
                            if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                        else
                            consecutive_errors = consecutive_errors + 1
                            if consecutive_errors >= MAX_CONSECUTIVE_ERRORS then
                                closeAuth()
                                local detail = (raw_res and (raw_res.error_description or raw_res.error))
                                    or token_data or _("Connection timed out")
                                Widgets.showToast(string.format(_("%s authorization failed: %s"), prov_label, tostring(detail)), 5)
                                if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                            else
                                UIManager:scheduleIn(poll_interval, pollStep)
                            end
                        end
                    end)
                end

                UIManager:scheduleIn(poll_interval, pollStep)
            end)
        end, function()
            if on_finish_cb then UIManager:nextTick(on_finish_cb) end
        end)

    elseif provider == Constants.CLOUD_PROVIDERS.WEBDAV then
        local creds = Cloud.loadCredentials(Constants.CLOUD_PROVIDERS.WEBDAV)
        Widgets.showInputDialog{
            title = _("WebDAV Server Settings"),
            on_cancel = function()
                if on_finish_cb then UIManager:nextTick(on_finish_cb) end
            end,
            fields = {
                { label = _("Server URL"), text = creds.url or "", hint = "https://cloud.example.com/remote.php/dav/files/user" },
                { label = _("Username"), text = creds.username or "", hint = _("Username") },
                { label = _("Password or App Token"), text = creds.password or "", hint = _("Password"), text_type = "password" },
            },
            buttons = {
                {
                    text = _("Cancel"),
                    callback = function()
                        if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                    end,
                },
                {
                    text = _("Test"),
                    keep_open = true,
                    callback = function(_, all_v)
                        local driver = Cloud.getDriver(Constants.CLOUD_PROVIDERS.WEBDAV)
                        local test_creds = { url = all_v[1], username = all_v[2], password = all_v[3] }
                        Widgets.showToast(_("Testing WebDAV connection..."), 10)
                        UIManager:nextTick(function()
                            driver.testConnection(test_creds, function(ok, msg)
                                Widgets.showToast(
                                    ok and string.format(_("Connected: %s"), tostring(msg))
                                        or string.format(_("Connection failed: %s"), tostring(msg)),
                                    4
                                )
                            end)
                        end)
                    end,
                },
                {
                    text = _("Save"),
                    is_primary = true,
                    callback = function(_, all_v)
                        creds.url = all_v[1]
                        creds.username = all_v[2]
                        creds.password = all_v[3]
                        Cloud.saveCredentials(Constants.CLOUD_PROVIDERS.WEBDAV, creds)
                        cfg.provider = Constants.CLOUD_PROVIDERS.WEBDAV
                        cfg.provider_user_selected = true
                        Settings.save(cfg)
                        Widgets.showToast(_("WebDAV settings saved."), 2)
                        if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                    end,
                },
            },
        }
    end
end

--- Native KOReader submenu items for Cloud Storage.
function UISettings.getCloudSettingsSubmenu(refresh_cb)
    local cfg = Settings.load()
    local provider_list = {
        Constants.CLOUD_PROVIDERS.NONE,
        Constants.CLOUD_PROVIDERS.GDRIVE,
        Constants.CLOUD_PROVIDERS.ONEDRIVE,
        Constants.CLOUD_PROVIDERS.DROPBOX,
        Constants.CLOUD_PROVIDERS.WEBDAV,
    }
    local provider_subitems = {}
    for _, p in ipairs(provider_list) do
        table.insert(provider_subitems, {
            text = Cloud.getProviderLabel(p),
            radio = true,
            keep_menu_open = true,
            checked_func = function() return (Settings.load().provider or Constants.CLOUD_PROVIDERS.NONE) == p end,
            callback = function(touch_menu)
                local cur = Settings.load()
                cur.provider = p
                cur.provider_user_selected = true
                Settings.save(cur)
                refreshMenuState(refresh_cb, touch_menu)
            end,
        })
    end
    local items = {
        {
            text_func = function()
                return string.format(_("Storage Provider: %s"), Cloud.getProviderLabel(Settings.load().provider or "none"))
            end,
            keep_menu_open = true,
            sub_item_table = provider_subitems,
        },
    }
    if cfg.provider and cfg.provider ~= Constants.CLOUD_PROVIDERS.NONE then
        table.insert(items, {
            text_func = function()
                local p = Settings.load().provider
                return Cloud.isConfigured(p)
                    and string.format(_("Configure %s..."), Cloud.getProviderLabel(p))
                    or string.format(_("Connect %s..."), Cloud.getProviderLabel(p))
            end,
            keep_menu_open = true,
            callback = function(touch_menu)
                UISettings.showCloudConfigDialog(Settings.load().provider, function()
                    refreshMenuState(refresh_cb, touch_menu)
                end)
            end,
        })
    end
    return items
end

--- Native KOReader submenu items for Sync preferences.
function UISettings.getSyncSettingsSubmenu(refresh_cb)
    return {
        {
            text = _("Use Nimbus as Home Screen"),
            keep_menu_open = true,
            checked_func = function() return Settings.load().use_as_home_screen == true end,
            callback = function(touch_menu)
                local c = Settings.load()
                c.use_as_home_screen = not (c.use_as_home_screen == true)
                Settings.save(c)
                if c.use_as_home_screen and _G.G_reader_settings and _G.G_reader_settings.saveSetting then
                    _G.G_reader_settings:saveSetting("start_with", "filemanager")
                end
                refreshMenuState(refresh_cb, touch_menu)
            end,
        },
        {
            text = _("Sync on Book Open/Close"),
            keep_menu_open = true,
            checked_func = function() return Settings.load().auto_sync_open end,
            callback = function(touch_menu)
                local c = Settings.load()
                c.auto_sync_open = not c.auto_sync_open
                c.auto_sync_close = c.auto_sync_open
                Settings.save(c)
                refreshMenuState(refresh_cb, touch_menu)
            end,
        },
        {
            text = _("Auto-Jump to Latest Page"),
            keep_menu_open = true,
            checked_func = function() return Settings.load().whispersync_auto_jump end,
            callback = function(touch_menu)
                local c = Settings.load()
                c.whispersync_auto_jump = not c.whispersync_auto_jump
                Settings.save(c)
                refreshMenuState(refresh_cb, touch_menu)
            end,
        },
    }
end

--- Shows the compact submenu-organized Storefront/Libbee/Beeline Settings dialog.
function UISettings.showSettingsDialog(on_finish_cb)
    local Scanner = require("nimbus_scanner")

    local function showProviderPicker(on_picked)
        local cur_p = Settings.load().provider or Constants.CLOUD_PROVIDERS.NONE
        Widgets.showCardDialog{
            title = _("Select Cloud Provider"),
            on_close = on_picked,
            body_widget = function(inner_w, closeDlg)
                local vg = VerticalGroup:new{ align = "left" }
                for _, p in ipairs({
                    Constants.CLOUD_PROVIDERS.GDRIVE,
                    Constants.CLOUD_PROVIDERS.ONEDRIVE,
                    Constants.CLOUD_PROVIDERS.DROPBOX,
                    Constants.CLOUD_PROVIDERS.WEBDAV,
                    Constants.CLOUD_PROVIDERS.NONE,
                }) do
                    table.insert(vg, Widgets.createRadioRow(Cloud.getProviderLabel(p), nil, cur_p == p, inner_w, function()
                        closeDlg()
                        local c = Settings.load()
                        c.provider = p
                        c.provider_user_selected = true
                        Settings.save(c)
                        if on_picked then on_picked() end
                    end))
                end
                return vg
            end,
            buttons = { { text = _("Cancel"), callback = on_picked } },
        }
    end

    local openRootDialog

    local function showCloudStorageMenu()
        local cfg = Settings.load()
        local cur_p = cfg.provider or Constants.CLOUD_PROVIDERS.NONE
        local is_conn = Cloud.isConfigured(cur_p)
        local reopen = function() UIManager:nextTick(showCloudStorageMenu) end

        Widgets.showCardDialog{
            title = _("Cloud Storage"),
            on_close = function() UIManager:nextTick(openRootDialog) end,
            body_widget = function(inner_w, closeDlg)
                local vg = VerticalGroup:new{ align = "left" }
                table.insert(vg, Widgets.createSettingRow(_("Storage Provider"),
                    rightChevron(Cloud.getProviderLabel(cur_p), true), inner_w, function()
                        closeDlg()
                        showProviderPicker(reopen)
                    end))

                if cur_p ~= Constants.CLOUD_PROVIDERS.NONE then
                    table.insert(vg, Widgets.createSettingRow(_("Account"),
                        rightChevron(is_conn and _("Connected") or _("Connect"), is_conn), inner_w, function()
                            closeDlg()
                            UISettings.showCloudConfigDialog(cur_p, reopen)
                        end))
                    table.insert(vg, Widgets.createSettingRow(_("Test Connection"),
                        rightChevron(_("Run"), false), inner_w, function()
                            Widgets.showToast(_("Testing cloud connection..."), 10)
                            UIManager:nextTick(function()
                                Cloud.testConnection(function(ok, msg)
                                    Widgets.showToast(
                                        ok and string.format(_("Connected: %s"), tostring(msg))
                                            or string.format(_("Connection failed: %s"), tostring(msg)),
                                        4
                                    )
                                end)
                            end)
                        end))
                    table.insert(vg, Widgets.createSettingRow(_("Remote Folder"),
                        rightChevron(cfg.remote_root or Constants.DEFAULT_REMOTE_ROOT, false), inner_w, function()
                            closeDlg()
                            Widgets.showInputDialog{
                                title = _("Remote Nimbus Folder"),
                                description = _("Name of root folder on cloud storage:"),
                                input = cfg.remote_root or Constants.DEFAULT_REMOTE_ROOT,
                                on_cancel = reopen,
                                on_submit = function(v)
                                    if v and v ~= "" then
                                        cfg.remote_root = v:gsub("\\", "/"):gsub("^/+", ""):gsub("/+$", "")
                                        Settings.save(cfg)
                                    end
                                    reopen()
                                end,
                            }
                        end))
                end

                local avail_backup = Settings.detectBackupPluginAccounts()
                if #avail_backup > 0 then
                    table.insert(vg, Widgets.createSettingRow(_("Backup & Restore Auth"),
                        rightChevron(_("Import"), false), inner_w, function()
                            local ok, res = Cloud.importFromBackupPlugin(nil)
                            closeDlg()
                            reopen()
                            UIManager:nextTick(function()
                                Widgets.showToast(
                                    ok and string.format(_("Imported %s!"), Cloud.getProviderLabel(res)) or tostring(res),
                                    2.5
                                )
                            end)
                        end))
                end
                return vg
            end,
            buttons = {
                { text = _("Back"), callback = function() UIManager:nextTick(openRootDialog) end },
                { text = _("Done"), is_primary = true, callback = function()
                    if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                end },
            },
        }
    end

    local function showLibraryHomeMenu()
        local cfg = Settings.load()
        local dirs = Scanner.getEffectiveBooksDirs()
        local book_dir_label = dirs[1] or cfg.download_dir or ""
        if #book_dir_label > 24 then book_dir_label = "..." .. book_dir_label:sub(-21) end
        local reopen = function() UIManager:nextTick(showLibraryHomeMenu) end

        Widgets.showCardDialog{
            title = _("Library & Home Screen"),
            on_close = function() UIManager:nextTick(openRootDialog) end,
            body_widget = function(inner_w, closeDlg)
                local vg = VerticalGroup:new{ align = "left" }
                table.insert(vg, Widgets.createCheckboxRow(
                    _("Use as Home Screen"),
                    _("Show your library at startup instead of KOReader's file list"),
                    cfg.use_as_home_screen == true,
                    inner_w,
                    function()
                        closeDlg()
                        cfg.use_as_home_screen = not (cfg.use_as_home_screen == true)
                        Settings.save(cfg)
                        if cfg.use_as_home_screen and _G.G_reader_settings and _G.G_reader_settings.saveSetting then
                            _G.G_reader_settings:saveSetting("start_with", "filemanager")
                        end
                        reopen()
                    end
                ))
                table.insert(vg, Widgets.createSettingRow(_("Book Folder"),
                    rightChevron(book_dir_label, false), inner_w, function()
                        closeDlg()
                        Widgets.showInputDialog{
                            title = _("Local Book Folder"),
                            description = _("Directory path scanned for local books:"),
                            input = dirs[1] or "",
                            on_cancel = reopen,
                            on_submit = function(v)
                                if v and v ~= "" then
                                    cfg.custom_books_dirs = { v }
                                    Settings.save(cfg)
                                end
                                reopen()
                            end,
                        }
                    end))
                return vg
            end,
            buttons = {
                { text = _("Back"), callback = function() UIManager:nextTick(openRootDialog) end },
                { text = _("Done"), is_primary = true, callback = function()
                    if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                end },
            },
        }
    end

    local showReadingSyncMenu

    local function showKOSyncMenu()
        local cfg = Settings.load()
        local reopen = function() UIManager:nextTick(showKOSyncMenu) end
        local srv_label = tostring(cfg.kosync_server or "")
        if #srv_label > 24 then srv_label = "..." .. srv_label:sub(-21) end

        Widgets.showCardDialog{
            title = _("CrossPoint / Sink / KOSync"),
            on_close = function() UIManager:nextTick(showReadingSyncMenu) end,
            body_widget = function(inner_w, closeDlg)
                local vg = VerticalGroup:new{ align = "left" }
                table.insert(vg, Widgets.createCheckboxRow(
                    _("Enable CrossPoint/KOSync Bridge"),
                    _("Sync reading progress with CrossPoint, Readest, & Sink Worker"),
                    cfg.kosync_enabled == true,
                    inner_w,
                    function()
                        closeDlg()
                        cfg.kosync_enabled = not (cfg.kosync_enabled == true)
                        cfg.kosync_user_configured = true
                        Settings.save(cfg)
                        reopen()
                    end
                ))
                table.insert(vg, Widgets.createSettingRow(_("Server URL"),
                    rightChevron(srv_label ~= "" and srv_label or _("Set"), false), inner_w, function()
                        closeDlg()
                        Widgets.showInputDialog{
                            title = _("Sink / KOSync Server URL"),
                            description = _("Cloudflare Worker URL or KOSync server:"),
                            input = cfg.kosync_server or "https://sync.koreader.rocks",
                            on_cancel = reopen,
                            on_submit = function(v)
                                if v and v ~= "" then
                                    cfg.kosync_server = v:gsub("/+$", "")
                                    cfg.kosync_user_configured = true
                                    Settings.save(cfg)
                                end
                                reopen()
                            end,
                        }
                    end))
                table.insert(vg, Widgets.createSettingRow(_("Username"),
                    rightChevron(cfg.kosync_username ~= "" and cfg.kosync_username or _("Set"), false), inner_w, function()
                        closeDlg()
                        Widgets.showInputDialog{
                            title = _("KOSync Username"),
                            input = cfg.kosync_username or "",
                            on_cancel = reopen,
                            on_submit = function(v)
                                cfg.kosync_username = v or ""
                                cfg.kosync_user_configured = true
                                Settings.save(cfg)
                                reopen()
                            end,
                        }
                    end))
                table.insert(vg, Widgets.createSettingRow(_("Password"),
                    rightChevron(cfg.kosync_userkey ~= "" and "••••••" or _("Set"), false), inner_w, function()
                        closeDlg()
                        Widgets.showInputDialog{
                            title = _("KOSync Password"),
                            description = _("Stored locally as MD5 key (compatible with Sink/CrossPoint):"),
                            input = "",
                            text_type = "password",
                            on_cancel = reopen,
                            on_submit = function(v)
                                if v and v ~= "" then
                                    cfg.kosync_userkey = KOSync.hashPassword(v)
                                    cfg.kosync_user_configured = true
                                    Settings.save(cfg)
                                end
                                reopen()
                            end,
                        }
                    end))
                local method_label = (cfg.kosync_checksum_method == "binary") and _("Binary") or _("Filename")
                table.insert(vg, Widgets.createSettingRow(_("Book Matching"),
                    rightChevron(method_label, false), inner_w, function()
                        closeDlg()
                        cfg.kosync_checksum_method = (cfg.kosync_checksum_method == "binary") and "filename" or "binary"
                        Settings.save(cfg)
                        reopen()
                    end))
                table.insert(vg, Widgets.createSettingRow(_("Test Connection"),
                    rightChevron(_("Run"), false), inner_w, function()
                        Widgets.showToast(_("Testing KOSync connection..."), 10)
                        UIManager:nextTick(function()
                            KOSync.testConnection(cfg.kosync_server, cfg.kosync_username, cfg.kosync_userkey, function(ok, msg)
                                Widgets.showToast(
                                    ok and string.format(_("KOSync connected (%s)"), tostring(msg))
                                        or string.format(_("KOSync failed: %s"), tostring(msg)),
                                    4
                                )
                            end)
                        end)
                    end))
                local detected = Settings.detectSyncPlugins()
                if #detected > 0 then
                    table.insert(vg, VerticalSpan:new{ width = sc(6) })
                    table.insert(vg, Widgets.createSectionHeader(_("Detected Sync Plugins"), inner_w))
                    for _, prof in ipairs(detected) do
                        local is_sel = (cfg.kosync_source == prof.id) or (cfg.kosync_username == prof.username and cfg.kosync_server == prof.server)
                        table.insert(vg, Widgets.createRadioRow(
                            prof.label,
                            prof.username .. " · " .. prof.server,
                            is_sel,
                            inner_w,
                            function()
                                closeDlg()
                                Settings.applySyncPluginProfile(cfg, prof)
                                cfg.kosync_user_configured = true
                                Settings.save(cfg)
                                reopen()
                                UIManager:nextTick(function()
                                    Widgets.showToast(string.format(_("Imported %s settings!"), prof.label), 2.5)
                                end)
                            end
                        ))
                    end
                end
                return vg
            end,
            buttons = {
                { text = _("Back"), callback = function() UIManager:nextTick(showReadingSyncMenu) end },
                { text = _("Done"), is_primary = true, callback = function()
                    if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                end },
            },
        }
    end

    showReadingSyncMenu = function()
        local cfg = Settings.load()
        local reopen = function() UIManager:nextTick(showReadingSyncMenu) end
        local ko_status = KOSync.isConfigured(cfg) and _("On") or _("Off")

        Widgets.showCardDialog{
            title = _("Reading Sync"),
            on_close = function() UIManager:nextTick(openRootDialog) end,
            body_widget = function(inner_w, closeDlg)
                local vg = VerticalGroup:new{ align = "left" }
                table.insert(vg, Widgets.createCheckboxRow(
                    _("Sync on Book Open/Close"),
                    _("Pull/push progress automatically when opening or closing a book"),
                    cfg.auto_sync_open,
                    inner_w,
                    function()
                        closeDlg()
                        cfg.auto_sync_open = not cfg.auto_sync_open
                        cfg.auto_sync_close = cfg.auto_sync_open
                        Settings.save(cfg)
                        reopen()
                    end
                ))
                table.insert(vg, Widgets.createCheckboxRow(
                    _("Auto-Jump to Latest Page"),
                    _("Jump automatically when another device is ahead (otherwise ask)"),
                    cfg.whispersync_auto_jump,
                    inner_w,
                    function()
                        closeDlg()
                        cfg.whispersync_auto_jump = not cfg.whispersync_auto_jump
                        Settings.save(cfg)
                        reopen()
                    end
                ))
                table.insert(vg, Widgets.createCheckboxRow(
                    _("Sync Highlights & Notes"),
                    _("Merge bookmarks, highlights, and notes across devices"),
                    cfg.sync_highlights,
                    inner_w,
                    function()
                        closeDlg()
                        cfg.sync_highlights = not cfg.sync_highlights
                        Settings.save(cfg)
                        reopen()
                    end
                ))
                table.insert(vg, Widgets.createCheckboxRow(
                    _("Sync Reading Statistics"),
                    _("Merge reading time and session history across devices"),
                    cfg.sync_stats,
                    inner_w,
                    function()
                        closeDlg()
                        cfg.sync_stats = not cfg.sync_stats
                        Settings.save(cfg)
                        reopen()
                    end
                ))
                table.insert(vg, VerticalSpan:new{ width = sc(4) })
                table.insert(vg, Widgets.createSettingRow(
                    _("CrossPoint / Sink / KOSync"),
                    rightChevron(ko_status, ko_status == _("On")),
                    inner_w,
                    function()
                        closeDlg()
                        showKOSyncMenu()
                    end
                ))
                return vg
            end,
            buttons = {
                { text = _("Back"), callback = function() UIManager:nextTick(openRootDialog) end },
                { text = _("Done"), is_primary = true, callback = function()
                    if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                end },
            },
        }
    end

    openRootDialog = function()
        local cfg = Settings.load()
        local cur_p = cfg.provider or Constants.CLOUD_PROVIDERS.NONE
        local cloud_summary = Cloud.isConfigured(cur_p)
            and Cloud.getProviderLabel(cur_p)
            or _("Not Connected")
        local home_summary = cfg.use_as_home_screen and _("Home Screen") or _("Book Folder")
        local sync_summary = (cfg.auto_sync_open and _("Auto") or _("Manual"))
            .. (KOSync.isConfigured(cfg) and " + KOSync" or "")

        Widgets.showCardDialog{
            title = _("Nimbus Settings"),
            on_close = on_finish_cb,
            body_widget = function(inner_w, closeDlg)
                local vg = VerticalGroup:new{ align = "left" }

                table.insert(vg, Widgets.createSectionHeader(_("Configuration"), inner_w))
                table.insert(vg, VerticalSpan:new{ width = sc(4) })
                table.insert(vg, Widgets.createMenuList({
                    Widgets.createMenuRow(_("Cloud Storage"),
                        rightChevron(cloud_summary, Cloud.isConfigured(cur_p)), inner_w, function()
                            closeDlg()
                            showCloudStorageMenu()
                        end),
                    Widgets.createMenuRow(_("Library & Home Screen"),
                        rightChevron(home_summary, false), inner_w, function()
                            closeDlg()
                            showLibraryHomeMenu()
                        end),
                    Widgets.createMenuRow(_("Reading Sync"),
                        rightChevron(sync_summary, false), inner_w, function()
                            closeDlg()
                            showReadingSyncMenu()
                        end),
                }, inner_w))

                table.insert(vg, VerticalSpan:new{ width = sc(8) })
                table.insert(vg, Widgets.createSectionHeader(_("Device & About"), inner_w))
                table.insert(vg, VerticalSpan:new{ width = sc(4) })
                table.insert(vg, Widgets.createMenuList({
                    Widgets.createMenuRow(_("Device ID"),
                        TextWidget:new{ text = tostring(cfg.device_id or ""), face = Font:getFace("cfont", 14), fgcolor = theme.color_label_dim }, inner_w),
                    Widgets.createMenuRow(_("Version"),
                        TextWidget:new{ text = "v" .. Constants.VERSION, face = Font:getFace("cfont", 14), fgcolor = theme.color_label_dim }, inner_w),
                }, inner_w))

                return vg
            end,
            buttons = {
                {
                    text = _("Close"),
                    is_primary = true,
                    callback = function()
                        if on_finish_cb then UIManager:nextTick(on_finish_cb) end
                    end,
                },
            },
        }
    end

    openRootDialog()
end

return UISettings
