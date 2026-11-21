--[[--
nimbus_cloud.lua
Unified CloudFS dispatcher, root path prefixing, credential management, and
1-tap backup.koplugin account importer.
--]]

local ok_loc, Localization = pcall(require, "localization_nimbus")
local _ = (ok_loc and Localization and Localization.getHelper) and Localization:getHelper() or require("gettext")
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

function Cloud.parseProvider(provider)
    if type(provider) ~= "string" then return nil, false end
    local base = provider:match("^backup:(.+)$")
    if base then return base, true end
    return provider, false
end

function Cloud.getDriver(provider)
    local base = Cloud.parseProvider(provider)
    return DRIVERS[base]
end

function Cloud.getProviderLabel(provider)
    local base, is_backup = Cloud.parseProvider(provider)
    local base_label
    if base == Constants.CLOUD_PROVIDERS.GDRIVE then base_label = _("Google Drive")
    elseif base == Constants.CLOUD_PROVIDERS.ONEDRIVE then base_label = _("Microsoft OneDrive")
    elseif base == Constants.CLOUD_PROVIDERS.DROPBOX then base_label = _("Dropbox")
    elseif base == Constants.CLOUD_PROVIDERS.WEBDAV then base_label = _("WebDAV")
    else return _("Not Configured") end
    if is_backup then
        return string.format(_("%s (Device Backup and Restore)"), base_label)
    end
    return base_label
end

function Cloud.getProviderShortLabel(provider)
    local base, is_backup = Cloud.parseProvider(provider)
    local base_label
    if base == Constants.CLOUD_PROVIDERS.GDRIVE then base_label = _("Google Drive")
    elseif base == Constants.CLOUD_PROVIDERS.ONEDRIVE then base_label = _("Microsoft OneDrive")
    elseif base == Constants.CLOUD_PROVIDERS.DROPBOX then base_label = _("Dropbox")
    elseif base == Constants.CLOUD_PROVIDERS.WEBDAV then base_label = _("WebDAV")
    else return _("Not Configured") end
    if is_backup then
        return string.format(_("%s (Backup)"), base_label)
    end
    return base_label
end

function Cloud.loadCredentials(provider)
    local base, is_backup = Cloud.parseProvider(provider)
    if is_backup then
        if base == Constants.CLOUD_PROVIDERS.WEBDAV then
            local _avail, backup_creds = Settings.detectBackupPluginAccounts()
            if type(backup_creds) == "table" and type(backup_creds.webdav) == "table" then
                local copy = {}
                for k, v in pairs(backup_creds.webdav) do copy[k] = v end
                return copy
            end
            return {}
        end
        return { token_slot = provider }
    end
    local path = Settings.getNimbusDir() .. "/creds.lua"
    local all = Settings.readLuaTable(path) or {}
    local c = all[provider] or {}
    if base and base ~= Constants.CLOUD_PROVIDERS.WEBDAV then
        local out = {}
        for k, v in pairs(c) do out[k] = v end
        out.token_slot = provider
        return out
    end
    return c
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

function Cloud.disconnectProvider(provider)
    local cfg = Settings.load()
    local target = provider or cfg.provider
    if not target or target == Constants.CLOUD_PROVIDERS.NONE then
        return false
    end
    Cloud.clearCredentials(target)
    if cfg.provider == target then
        cfg.provider = Constants.CLOUD_PROVIDERS.NONE
        cfg.provider_user_selected = true
        Settings.save(cfg)
        local ok_s, Sync = pcall(require, "nimbus_sync")
        if ok_s and Sync and Sync.clearCachedCatalog then
            Sync.clearCachedCatalog()
        end
    end
    Logger.action("Disconnected cloud provider: " .. tostring(target))
    return true
end

--- Selects a Device Backup and Restore provider slot ("backup:<provider>") without modifying backup.koplugin.
function Cloud.importFromBackupPlugin(provider)
    local available, _c, _t, backup_provider = Settings.detectBackupPluginAccounts()
    if #available == 0 then
        return false, _("No saved cloud accounts found in backup.koplugin.")
    end

    local _base, is_backup_req = Cloud.parseProvider(provider)
    local target = is_backup_req and provider:match("^backup:(.+)$") or provider
    if not target then
        local avail_set = {}
        for _i, p in ipairs(available) do avail_set[p] = true end
        if backup_provider and avail_set[backup_provider] then
            target = backup_provider
        else
            target = available[1]
        end
    end

    local found = false
    for _i, p in ipairs(available) do
        if p == target then found = true break end
    end
    if not found then
        return false, _("No saved account found for this provider in backup.koplugin.")
    end

    local slot = "backup:" .. target
    local cfg = Settings.load()
    cfg.provider = slot
    cfg.provider_user_selected = true
    Settings.save(cfg)
    Logger.action("Selected Device Backup and Restore slot: " .. tostring(slot))
    return true, slot
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
    local base = Cloud.parseProvider(provider)
    if not base or base == Constants.CLOUD_PROVIDERS.NONE then
        return false
    end
    if base == Constants.CLOUD_PROVIDERS.WEBDAV then
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
