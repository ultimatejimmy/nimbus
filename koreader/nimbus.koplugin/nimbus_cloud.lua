--[[--
nimbus_cloud.lua
Unified CloudFS dispatcher, root path prefixing, credential management, and
1-tap backup.koplugin account importer.
--]]

local _ = require("gettext")
local Constants = require("nimbus_constants")
local Logger = require("nimbus_logger")
local Settings = require("nimbus_settings")
local OAuth = require("nimbus_cloud_oauth")
local GDrive = require("nimbus_cloud_gdrive")
local OneDrive = require("nimbus_cloud_onedrive")
local Dropbox = require("nimbus_cloud_dropbox")
local WebDAV = require("nimbus_cloud_webdav")

local Cloud = {}

local DRIVERS = {
    [Constants.CLOUD_PROVIDERS.GDRIVE] = GDrive,
    [Constants.CLOUD_PROVIDERS.ONEDRIVE] = OneDrive,
    [Constants.CLOUD_PROVIDERS.DROPBOX] = Dropbox,
    [Constants.CLOUD_PROVIDERS.WEBDAV] = WebDAV,
}

function Cloud.getDriver(provider)
    return DRIVERS[provider]
end

function Cloud.getProviderLabel(provider)
    if provider == Constants.CLOUD_PROVIDERS.GDRIVE then return _("Google Drive")
    elseif provider == Constants.CLOUD_PROVIDERS.ONEDRIVE then return _("Microsoft OneDrive")
    elseif provider == Constants.CLOUD_PROVIDERS.DROPBOX then return _("Dropbox")
    elseif provider == Constants.CLOUD_PROVIDERS.WEBDAV then return _("WebDAV")
    end
    return _("Not Configured")
end

function Cloud.loadCredentials(provider)
    local path = Settings.getNimbusDir() .. "/creds.lua"
    local all = Settings.readLuaTable(path) or {}
    return all[provider] or {}
end

function Cloud.saveCredentials(provider, creds)
    local path = Settings.getNimbusDir() .. "/creds.lua"
    local all = Settings.readLuaTable(path) or {}
    all[provider] = creds or {}
    return Settings.writeLuaTable(path, all)
end

function Cloud.clearCredentials(provider)
    local path = Settings.getNimbusDir() .. "/creds.lua"
    local all = Settings.readLuaTable(path) or {}
    all[provider] = nil
    Settings.writeLuaTable(path, all)
    OAuth.clearTokens(provider)
    local d = Cloud.getDriver(provider)
    if d and d.clearFolderCache then d.clearFolderCache() end
end

--- Imports credentials/OAuth tokens for a provider (or best available) from backup.koplugin.
function Cloud.importFromBackupPlugin(provider)
    local available, creds, tokens, backup_provider = Settings.detectBackupPluginAccounts()
    if #available == 0 then
        return false, _("No saved cloud accounts found in backup.koplugin.")
    end

    local target = provider
    if not target then
        local avail_set = {}
        for _, p in ipairs(available) do avail_set[p] = true end
        if backup_provider and avail_set[backup_provider] then
            target = backup_provider
        else
            target = available[1]
        end
    end

    local found = false
    for _, p in ipairs(available) do
        if p == target then found = true break end
    end
    if not found then
        return false, _("No saved account found for this provider in backup.koplugin.")
    end

    if target == Constants.CLOUD_PROVIDERS.WEBDAV then
        Cloud.saveCredentials(target, creds.webdav)
    else
        OAuth.saveTokens(target, tokens[target])
    end

    local cfg = Settings.load()
    cfg.provider = target
    cfg.provider_user_selected = true
    Settings.save(cfg)
    Logger.action("Imported cloud credentials from backup.koplugin for provider: " .. tostring(target))
    return true, target
end

function Cloud.withRoot(rel_path)
    local cfg = Settings.load()
    local root = tostring(cfg.remote_root or Constants.DEFAULT_REMOTE_ROOT):gsub("^/+", ""):gsub("/+$", "")
    local rel = tostring(rel_path or ""):gsub("^/+", ""):gsub("/+$", "")
    if root == "" then return rel end
    if rel == "" then return root end
    return root .. "/" .. rel
end

function Cloud.isProviderConfigured(provider)
    if not provider or provider == Constants.CLOUD_PROVIDERS.NONE then
        return false
    end
    if provider == Constants.CLOUD_PROVIDERS.WEBDAV then
        local c = Cloud.loadCredentials(provider)
        return c.url ~= nil and c.url ~= ""
    end
    local t = OAuth.loadTokens(provider)
    return t ~= nil and (t.access_token ~= nil or t.refresh_token ~= nil)
end

function Cloud.isConfigured(provider)
    local cfg = Settings.load()
    return Cloud.isProviderConfigured(provider or cfg.provider)
end

local function getActive()
    local cfg = Settings.load()
    local driver = Cloud.getDriver(cfg.provider)
    if not driver then return nil, nil, _("No cloud provider configured.") end
    local creds = Cloud.loadCredentials(cfg.provider)
    return driver, creds
end

function Cloud.testConnection(cb)
    local driver, creds, err = getActive()
    if not driver then
        Logger.warn("Cloud testConnection aborted: " .. tostring(err))
        return cb(false, err)
    end
    local provider = Settings.load().provider
    Logger.action("Testing cloud connection for provider: " .. tostring(provider))
    driver.testConnection(creds, function(ok, msg)
        if ok then
            Logger.info("Cloud connection succeeded (" .. tostring(provider) .. "): " .. tostring(msg))
        else
            Logger.warn("Cloud connection failed (" .. tostring(provider) .. "): " .. tostring(msg))
        end
        if cb then cb(ok, msg) end
    end)
end

function Cloud.uploadString(rel_path, content_str, content_type, cb)
    local driver, creds, err = getActive()
    if not driver then return cb(false, err) end
    driver.uploadString(Cloud.withRoot(rel_path), content_str, content_type, creds, cb)
end

function Cloud.uploadFile(rel_path, local_path, cb, opts)
    local driver, creds, err = getActive()
    if not driver then return cb(false, err) end
    driver.uploadFile(Cloud.withRoot(rel_path), local_path, creds, cb, opts)
end

function Cloud.downloadString(rel_path, cb)
    local driver, creds, err = getActive()
    if not driver then return cb(false, err) end
    driver.downloadString(Cloud.withRoot(rel_path), creds, cb)
end

function Cloud.downloadFile(rel_path, local_dest_path, cb, opts)
    local driver, creds, err = getActive()
    if not driver then return cb(false, err) end
    driver.downloadFile(Cloud.withRoot(rel_path), local_dest_path, creds, cb, opts)
end

function Cloud.listDir(rel_dir, cb)
    local driver, creds, err = getActive()
    if not driver then return cb(false, err) end
    driver.listDir(Cloud.withRoot(rel_dir), creds, cb)
end

function Cloud.deletePath(rel_path, cb)
    local driver, creds, err = getActive()
    if not driver then return cb(false, err) end
    driver.deletePath(Cloud.withRoot(rel_path), creds, cb)
end

return Cloud
