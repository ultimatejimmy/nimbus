--[[--
nimbus_ui_settings.lua
Settings, 1-tap backup.koplugin importer, QR Device OAuth flow, and WebDAV config UI.
--]]

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local ConfirmBox = require("ui/widget/confirmbox")
local ButtonDialog = require("ui/widget/buttondialog")
local Menu = require("ui/widget/menu")
local Screen = require("device").screen
local _ = require("gettext")

local Constants = require("nimbus_constants")
local Settings = require("nimbus_settings")
local Cloud = require("nimbus_cloud")
local OAuth = require("nimbus_cloud_oauth")

local UISettings = {}

function UISettings.startOAuthFlow(provider, on_done)
    local pdef = OAuth.PROVIDERS[provider]
    if not pdef then return end

    local wait_msg = InfoMessage:new{ text = _("Requesting sign-in code…") }
    UIManager:show(wait_msg)
    UIManager:forceRePaint()

    OAuth.requestDeviceCode(provider, nil, function(ok, info_or_err)
        UIManager:close(wait_msg)
        if not ok then
            UIManager:show(InfoMessage:new{ text = _("Failed to start sign-in:\n") .. tostring(info_or_err) })
            return
        end

        local info = info_or_err
        local verify_url = info.verification_uri_complete or info.verification_url
        local prompt_text = string.format(
            _("To connect %s:\n\n1. Visit: %s\n2. Enter code: %s\n\nTap 'I Have Authorized' once completed."),
            pdef.name,
            tostring(info.verification_url),
            tostring(info.user_code)
        )

        local dlg
        local function pollOnce()
            OAuth.pollToken(provider, info.device_code, nil, function(ok_tok, data_or_err)
                if ok_tok then
                    UIManager:close(dlg)
                    local cfg = Settings.load()
                    cfg.provider = provider
                    Settings.save(cfg)
                    UIManager:show(InfoMessage:new{ text = string.format(_("Connected to %s!"), pdef.name), timeout = 3 })
                    if on_done then on_done(true) end
                elseif data_or_err == "authorization_pending" or data_or_err == "slow_down" then
                    UIManager:show(InfoMessage:new{ text = _("Waiting for browser authorization…"), timeout = 2 })
                else
                    UIManager:close(dlg)
                    UIManager:show(InfoMessage:new{ text = _("Authorization failed: ") .. tostring(data_or_err) })
                end
            end)
        end

        local buttons = {
            {
                {
                    text = _("I Have Authorized"),
                    is_enter_default = true,
                    callback = pollOnce,
                },
                {
                    text = _("Cancel"),
                    callback = function() UIManager:close(dlg) end,
                },
            },
        }
        if verify_url then
            table.insert(buttons, 1, {
                {
                    text = _("Show QR Code"),
                    callback = function()
                        local ok_qr, QRMessage = pcall(require, "ui/widget/qrmessage")
                        if ok_qr and QRMessage then
                            UIManager:show(QRMessage:new{
                                text = verify_url,
                                width = Screen:getWidth() * 0.7,
                                height = Screen:getWidth() * 0.7,
                            })
                        end
                    end,
                },
            })
        end

        dlg = ButtonDialog:new{
            title = string.format(_("Connect %s"), pdef.name),
            text = prompt_text,
            buttons = buttons,
        }
        UIManager:show(dlg)
    end)
end

function UISettings.showWebDAVDialog(on_done)
    local cur = Cloud.loadCredentials(Constants.CLOUD_PROVIDERS.WEBDAV)
    local dlg
    dlg = MultiInputDialog:new{
        title = _("WebDAV Configuration"),
        fields = {
            {
                text = cur.url or "",
                hint = _("https://cloud.example.com/remote.php/dav/files/user/"),
            },
            {
                text = cur.username or "",
                hint = _("Username"),
            },
            {
                text = cur.password or "",
                hint = _("Password / App Password"),
                text_type = "password",
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function() UIManager:close(dlg) end,
                },
                {
                    text = _("Save & Test"),
                    is_enter_default = true,
                    callback = function()
                        local fields = dlg:getFields()
                        local creds = {
                            url = fields[1],
                            username = fields[2],
                            password = fields[3],
                        }
                        UIManager:close(dlg)
                        Cloud.saveCredentials(Constants.CLOUD_PROVIDERS.WEBDAV, creds)
                        local cfg = Settings.load()
                        cfg.provider = Constants.CLOUD_PROVIDERS.WEBDAV
                        Settings.save(cfg)
                        Cloud.testConnection(function(ok, msg)
                            UIManager:show(InfoMessage:new{
                                text = ok and (_("WebDAV connected: ") .. tostring(msg)) or (_("WebDAV error: ") .. tostring(msg)),
                                timeout = 3,
                            })
                            if ok and on_done then on_done(true) end
                        end)
                    end,
                },
            },
        },
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function UISettings.showImportFromBackupDialog(on_done)
    local available = Settings.detectBackupPluginAccounts()
    if #available == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No saved cloud accounts found in backup.koplugin."),
            timeout = 3,
        })
        return
    end

    local buttons = {}
    for _, p in ipairs(available) do
        table.insert(buttons, {
            {
                text = _("Import ") .. Cloud.getProviderLabel(p),
                callback = function()
                    local ok, err = Cloud.importFromBackupPlugin(p)
                    UIManager:show(InfoMessage:new{
                        text = ok and (_("Imported ") .. Cloud.getProviderLabel(p) .. _("!")) or tostring(err),
                        timeout = 3,
                    })
                    if ok and on_done then on_done(true) end
                end,
            },
        })
    end
    local dlg
    table.insert(buttons, {
        {
            text = _("Close"),
            callback = function() UIManager:close(dlg) end,
        },
    })
    dlg = ButtonDialog:new{
        title = _("Import from Device Backup & Restore"),
        buttons = buttons,
    }
    UIManager:show(dlg)
end

function UISettings.showProviderMenu(on_done)
    local cfg = Settings.load()
    local available_backup = Settings.detectBackupPluginAccounts()
    local items = {}

    if #available_backup > 0 then
        table.insert(items, {
            text = _("1-Tap Import from backup.koplugin"),
            callback = function()
                UISettings.showImportFromBackupDialog(on_done)
            end,
        })
    end

    for _, p in ipairs({
        Constants.CLOUD_PROVIDERS.GDRIVE,
        Constants.CLOUD_PROVIDERS.ONEDRIVE,
        Constants.CLOUD_PROVIDERS.DROPBOX,
        Constants.CLOUD_PROVIDERS.WEBDAV,
    }) do
        local mark = (cfg.provider == p) and " ✓" or ""
        table.insert(items, {
            text = Cloud.getProviderLabel(p) .. mark,
            callback = function()
                if p == Constants.CLOUD_PROVIDERS.WEBDAV then
                    UISettings.showWebDAVDialog(on_done)
                else
                    UISettings.startOAuthFlow(p, on_done)
                end
            end,
        })
    end

    table.insert(items, {
        text = _("Remote Root Folder: ") .. tostring(cfg.remote_root),
        callback = function()
            local dlg
            dlg = InputDialog:new{
                title = _("Nimbus Remote Root Folder"),
                input = cfg.remote_root,
                buttons = {
                    {
                        { text = _("Cancel"), callback = function() UIManager:close(dlg) end },
                        {
                            text = _("Save"),
                            is_enter_default = true,
                            callback = function()
                                local val = dlg:getInputText()
                                UIManager:close(dlg)
                                if val and val ~= "" then
                                    cfg.remote_root = val
                                    Settings.save(cfg)
                                end
                            end,
                        },
                    },
                },
            }
            UIManager:show(dlg)
            dlg:onShowKeyboard()
        end,
    })

    if Cloud.isConfigured() then
        table.insert(items, {
            text = _("Test Cloud Connection"),
            callback = function()
                Cloud.testConnection(function(ok, msg)
                    UIManager:show(InfoMessage:new{
                        text = ok and (_("Connected: ") .. tostring(msg)) or (_("Error: ") .. tostring(msg)),
                        timeout = 3,
                    })
                end)
            end,
        })
    end

    local menu = Menu:new{
        title = _("Nimbus Cloud Account"),
        item_table = items,
        width = Screen:getWidth() * 0.9,
        height = Screen:getHeight() * 0.8,
    }
    UIManager:show(menu)
end

return UISettings
