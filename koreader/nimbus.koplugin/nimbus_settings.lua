--[[--
nimbus_settings.lua
Settings persistence, device slug generation, book link map, and 1-tap backup.koplugin importer.
--]]

local ok_ds, DataStorage = pcall(require, "datastorage")
local ok_util, util = pcall(require, "util")
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs or not lfs then
    ok_lfs, lfs = pcall(require, "lfs")
end

local Constants = require("nimbus_constants")

local Settings = {}

local function getDataDir()
    return (ok_ds and DataStorage and DataStorage.getDataDir and DataStorage:getDataDir()) or "."
end

function Settings.getNimbusDir()
    return getDataDir() .. "/settings/nimbus"
end

function Settings.getCacheDir()
    return getDataDir() .. "/cache/nimbus"
end

function Settings.getCoversCacheDir()
    return Settings.getCacheDir() .. "/covers"
end

function Settings.getDefaultDownloadDir()
    return getDataDir() .. "/nimbus_books"
end

local function ensureDir(path)
    if util and util.makePath then
        util.makePath(path)
    elseif lfs and lfs.mkdir then
        lfs.mkdir(path)
    end
end

local function serializeLua(tbl)
    local seen = {}
    local function ser(o, indent)
        indent = indent or ""
        local next_indent = indent .. "    "
        local t = type(o)
        if t == "number" then
            if o ~= o or o == math.huge or o == -math.huge then
                return "nil"
            end
            return tostring(o)
        elseif t == "boolean" then
            return tostring(o)
        elseif t == "string" then
            return string.format("%q", o)
        elseif t == "table" then
            if seen[o] then return "{}" end
            seen[o] = true
            local lines = { "{\n" }
            for k, v in pairs(o) do
                local kt = type(k)
                local vt = type(v)
                if (kt == "string" or kt == "number" or kt == "boolean")
                    and (vt == "string" or vt == "number" or vt == "boolean" or vt == "table") then
                    local key_str
                    if kt == "string" and k:match("^[%a_][%a%d_]*$") then
                        key_str = k
                    else
                        key_str = "[" .. ser(k) .. "]"
                    end
                    table.insert(lines, string.format("%s%s = %s,\n", next_indent, key_str, ser(v, next_indent)))
                end
            end
            seen[o] = nil
            table.insert(lines, indent .. "}")
            return table.concat(lines)
        end
        return "nil"
    end
    return "return " .. ser(tbl) .. "\n"
end

function Settings.readLuaTable(path)
    local ok, data = pcall(dofile, path)
    if ok and type(data) == "table" then
        return data
    end
    return nil
end

function Settings.writeLuaTable(path, tbl)
    local dir = path:match("^(.*)/[^/]+$")
    if dir then ensureDir(dir) end
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(serializeLua(tbl))
    f:close()
    return true
end

local function sanitizeDeviceModel(model)
    local s = tostring(model or "KOReader")
    s = s:gsub("[^%w%-_]", "-")
    s = s:gsub("%-+", "-")
    s = s:gsub("^%-+", ""):gsub("%-+$", "")
    if s == "" then s = "KOReader" end
    return s:sub(1, 24)
end

local function randomHex4()
    math.randomseed(os.time() + math.floor((os.clock() or 0) * 1000))
    return string.format("%04x", math.random(0, 0xFFFF))
end

local function detectDeviceModel()
    local ok_dev, Device = pcall(require, "device")
    if ok_dev and Device and Device.model then
        return tostring(Device.model)
    end
    return "KOReader"
end

Settings.DEFAULTS = {
    provider = Constants.CLOUD_PROVIDERS.NONE,
    provider_user_selected = false,
    remote_root = Constants.DEFAULT_REMOTE_ROOT,
    download_dir = nil, -- computed lazily
    device_id = nil,    -- generated once and persisted
    auto_sync_open = true,
    auto_sync_close = true,
    whispersync_auto_jump = true,
    sync_highlights = true,
    sync_stats = true,
    import_remote_stats = false,
    library_view_mode = "cover",
    library_filter = "all",
    library_active_tab = "device",
    custom_books_dirs = nil,
    use_as_home_screen = false,
    auto_download_new_books = true,
    kosync_enabled = false,
    kosync_server = "https://sync.koreader.rocks",
    kosync_username = "",
    kosync_userkey = "",
    kosync_checksum_method = "filename",
    kosync_user_configured = false,
    kosync_source = nil, -- "sink", "kosync", or "custom"
}

local _settings_cache = nil

--- Detects whether backup.koplugin has saved credentials, OAuth tokens, or active cloud_provider.
function Settings.detectBackupPluginAccounts()
    local data_dir = getDataDir()
    local backup_cfg = Settings.readLuaTable(data_dir .. "/settings/backup.lua") or {}
    local creds = Settings.readLuaTable(data_dir .. "/settings/backup_cloud_creds.lua") or {}
    local tokens = Settings.readLuaTable(data_dir .. "/settings/backup_cloud_tokens.lua")
        or Settings.readLuaTable(data_dir .. "/settings/backup_cloud_oauth.lua")
        or {}

    local available = {}
    for _, p in ipairs({ "gdrive", "onedrive", "dropbox" }) do
        if type(tokens[p]) == "table" and (tokens[p].refresh_token or tokens[p].access_token) then
            table.insert(available, p)
        end
    end
    if type(creds.webdav) == "table" and creds.webdav.url and creds.webdav.url ~= "" then
        table.insert(available, "webdav")
    end
    return available, creds, tokens, backup_cfg.cloud_provider
end

--- Automatically imports OAuth tokens / WebDAV creds (and active provider) from backup.koplugin.
function Settings.autoImportFromBackupPlugin(merged, force_provider)
    local available, backup_creds, backup_tokens, backup_provider = Settings.detectBackupPluginAccounts()
    if #available == 0 then
        return false
    end

    local changed = false
    local oauth_path = Settings.getNimbusDir() .. "/oauth.lua"
    local nimbus_oauth = Settings.readLuaTable(oauth_path) or {}
    local oauth_dirty = false
    for _, p in ipairs({ "gdrive", "onedrive", "dropbox" }) do
        if type(backup_tokens[p]) == "table" and (backup_tokens[p].refresh_token or backup_tokens[p].access_token) then
            local cur = nimbus_oauth[p]
            if not cur or (not cur.refresh_token and not cur.access_token) then
                nimbus_oauth[p] = backup_tokens[p]
                oauth_dirty = true
            end
        end
    end
    if oauth_dirty then
        Settings.writeLuaTable(oauth_path, nimbus_oauth)
        changed = true
    end

    if type(backup_creds.webdav) == "table" and backup_creds.webdav.url and backup_creds.webdav.url ~= "" then
        local creds_path = Settings.getNimbusDir() .. "/creds.lua"
        local nimbus_creds = Settings.readLuaTable(creds_path) or {}
        if not nimbus_creds.webdav or not nimbus_creds.webdav.url or nimbus_creds.webdav.url == "" then
            nimbus_creds.webdav = backup_creds.webdav
            Settings.writeLuaTable(creds_path, nimbus_creds)
            changed = true
        end
    end

    local should_pick_provider = force_provider
        or ((not merged.provider or merged.provider == Constants.CLOUD_PROVIDERS.NONE) and not merged.provider_user_selected)
    if should_pick_provider then
        local available_set = {}
        for _, p in ipairs(available) do available_set[p] = true end

        local chosen = nil
        if backup_provider and available_set[backup_provider] then
            chosen = backup_provider
        else
            for _, p in ipairs({ "gdrive", "onedrive", "dropbox", "webdav" }) do
                if available_set[p] then
                    chosen = p
                    break
                end
            end
        end
        if chosen then
            merged.provider = chosen
            changed = true
        end
    end

    return changed
end

local _pending_sync_import_notice = nil

function Settings.consumeSyncImportNotice()
    local msg = _pending_sync_import_notice
    _pending_sync_import_notice = nil
    return msg
end

local SYNC_PLUGIN_ADAPTERS = {
    {
        id = "sink",
        label = "Sink",
        detect = function(data_dir)
            local raw = Settings.readLuaTable(data_dir .. "/settings/sink_settings.lua")
            local sink_cfg = (type(raw) == "table" and type(raw.sink_sync) == "table") and raw.sink_sync or raw
            if type(sink_cfg) == "table"
                and type(sink_cfg.server_url) == "string" and sink_cfg.server_url ~= ""
                and type(sink_cfg.username) == "string" and sink_cfg.username ~= ""
                and type(sink_cfg.userkey) == "string" and sink_cfg.userkey ~= "" then
                return {
                    id = "sink",
                    label = "Sink",
                    server = sink_cfg.server_url:gsub("/+$", ""),
                    username = sink_cfg.username,
                    userkey = sink_cfg.userkey,
                    checksum_method = sink_cfg.checksum_method or "filename",
                }
            end
            return nil
        end,
    },
    {
        id = "kosync",
        label = "KOReader KOSync",
        detect = function(data_dir)
            local raw = Settings.readLuaTable(data_dir .. "/settings/kosync.lua")
            local ko_cfg = (type(raw) == "table" and type(raw.settings) == "table") and raw.settings or raw
            if type(ko_cfg) == "table"
                and type(ko_cfg.username) == "string" and ko_cfg.username ~= ""
                and type(ko_cfg.userkey) == "string" and ko_cfg.userkey ~= "" then
                local srv = (type(ko_cfg.custom_server) == "string" and ko_cfg.custom_server ~= "")
                    and ko_cfg.custom_server:gsub("/+$", "")
                    or "https://sync.koreader.rocks"
                local method = (ko_cfg.checksum_method == 1 or ko_cfg.checksum_method == "filename")
                    and "filename" or "binary"
                return {
                    id = "kosync",
                    label = "KOReader KOSync",
                    server = srv,
                    username = ko_cfg.username,
                    userkey = ko_cfg.userkey,
                    checksum_method = method,
                }
            end
            return nil
        end,
    },
}

--- Detects all installed & configured sync plugins (Sink, KOReader KOSync, etc.) in priority order.
function Settings.detectSyncPlugins()
    local data_dir = getDataDir()
    local found = {}
    for _, adapter in ipairs(SYNC_PLUGIN_ADAPTERS) do
        local ok, profile = pcall(adapter.detect, data_dir)
        if ok and profile then
            table.insert(found, profile)
        end
    end
    return found
end

function Settings.applySyncPluginProfile(merged, profile)
    if type(merged) ~= "table" or type(profile) ~= "table" then return false end
    merged.kosync_server = profile.server
    merged.kosync_username = profile.username
    merged.kosync_userkey = profile.userkey
    merged.kosync_checksum_method = profile.checksum_method or "filename"
    merged.kosync_enabled = true
    merged.kosync_source = profile.id
    return true
end

function Settings.autoImportSyncPlugin(merged, force, source_id)
    local found = Settings.detectSyncPlugins()
    if #found == 0 then return false end
    if not force and (merged.kosync_user_configured or (merged.kosync_username and merged.kosync_username ~= "")) then
        return false
    end
    local chosen = found[1]
    if source_id then
        for _, p in ipairs(found) do
            if p.id == source_id then chosen = p; break end
        end
    end
    Settings.applySyncPluginProfile(merged, chosen)
    if not force then
        _pending_sync_import_notice = string.format("Detected %s: imported", chosen.label)
    end
    return true
end

--- Backward-compatible Sink detector/importer aliases.
function Settings.detectSinkPluginConfig()
    for _, p in ipairs(Settings.detectSyncPlugins()) do
        if p.id == "sink" then return p end
    end
    return nil
end

function Settings.autoImportFromSinkPlugin(merged, force)
    return Settings.autoImportSyncPlugin(merged, force, "sink")
end

function Settings.load()
    if _settings_cache then return _settings_cache end
    local path = Settings.getNimbusDir() .. "/settings.lua"
    local saved = Settings.readLuaTable(path) or {}
    local merged = {}
    for k, v in pairs(Settings.DEFAULTS) do
        merged[k] = v
    end
    for k, v in pairs(saved) do
        merged[k] = v
    end
    local dirty = false
    if not merged.download_dir or merged.download_dir == "" then
        merged.download_dir = Settings.getDefaultDownloadDir()
        dirty = true
    end
    if not merged.device_id or merged.device_id == "" then
        merged.device_id = sanitizeDeviceModel(detectDeviceModel()) .. "_" .. randomHex4()
        dirty = true
    end
    if Settings.autoImportFromBackupPlugin(merged, false) then
        dirty = true
    end
    if Settings.autoImportSyncPlugin(merged, false) then
        dirty = true
    end
    if dirty then
        Settings.writeLuaTable(path, merged)
    end
    _settings_cache = merged
    return _settings_cache
end

function Settings.save(tbl)
    _settings_cache = tbl
    return Settings.writeLuaTable(Settings.getNimbusDir() .. "/settings.lua", tbl)
end

function Settings.clearCache()
    _settings_cache = nil
end

--- Local book_links map: { [filepath] = book_id, by_book_id = { [book_id] = filepath } }
function Settings.loadBookLinks()
    local path = Settings.getNimbusDir() .. "/book_links.lua"
    local tbl = Settings.readLuaTable(path) or {}
    tbl.by_path = tbl.by_path or {}
    tbl.by_id = tbl.by_id or {}
    return tbl
end

function Settings.saveBookLinks(links)
    return Settings.writeLuaTable(Settings.getNimbusDir() .. "/book_links.lua", links)
end

function Settings.linkBook(filepath, book_id)
    if not filepath or not book_id then return false end
    local links = Settings.loadBookLinks()
    links.by_path[filepath] = book_id
    links.by_id[book_id] = filepath
    return Settings.saveBookLinks(links)
end

function Settings.unlinkBook(book_id, filepath)
    local links = Settings.loadBookLinks()
    if book_id then
        links.by_id[book_id] = nil
        for p, id in pairs(links.by_path) do
            if id == book_id then
                links.by_path[p] = nil
            end
        end
    end
    if filepath and links.by_path[filepath] then
        local id = links.by_path[filepath]
        links.by_path[filepath] = nil
        if id then links.by_id[id] = nil end
    end
    return Settings.saveBookLinks(links)
end

return Settings
