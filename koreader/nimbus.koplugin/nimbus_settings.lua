--[[--
nimbus_settings.lua
Settings persistence, device slug generation, book link map, and 1-tap backup.koplugin importer.
--]]

local ok_ds, DataStorage = pcall(require, "datastorage")
local ok_util, util = pcall(require, "util")
local ok_dump, dump = pcall(require, "dump")
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
    if ok_dump and type(dump) == "function" then
        return "return " .. dump(tbl) .. "\n"
    end
    local function ser(o, indent)
        indent = indent or ""
        local next_indent = indent .. "    "
        local t = type(o)
        if t == "number" or t == "boolean" then
            return tostring(o)
        elseif t == "string" then
            return string.format("%q", o)
        elseif t == "table" then
            local lines = { "{\n" }
            for k, v in pairs(o) do
                local key_str
                if type(k) == "string" and k:match("^[%a_][%a%d_]*$") then
                    key_str = k
                else
                    key_str = "[" .. ser(k) .. "]"
                end
                table.insert(lines, string.format("%s%s = %s,\n", next_indent, key_str, ser(v, next_indent)))
            end
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
    remote_root = Constants.DEFAULT_REMOTE_ROOT,
    download_dir = nil, -- computed lazily
    device_id = nil,    -- generated once and persisted
    auto_sync_open = true,
    auto_sync_close = true,
    whispersync_auto_jump = true,
    sync_highlights = true,
    sync_stats = true,
    import_remote_stats = false,
}

local _settings_cache = nil

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
    if not merged.download_dir or merged.download_dir == "" then
        merged.download_dir = Settings.getDefaultDownloadDir()
    end
    if not merged.device_id or merged.device_id == "" then
        merged.device_id = sanitizeDeviceModel(detectDeviceModel()) .. "_" .. randomHex4()
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
    if book_id and links.by_id[book_id] then
        local p = links.by_id[book_id]
        links.by_path[p] = nil
        links.by_id[book_id] = nil
    end
    if filepath and links.by_path[filepath] then
        local id = links.by_path[filepath]
        links.by_path[filepath] = nil
        if id then links.by_id[id] = nil end
    end
    return Settings.saveBookLinks(links)
end

--- Detects whether backup.koplugin has saved credentials or OAuth tokens.
function Settings.detectBackupPluginAccounts()
    local creds_path = getDataDir() .. "/settings/backup_cloud_creds.lua"
    local oauth_path = getDataDir() .. "/settings/backup_cloud_oauth.lua"
    local creds = Settings.readLuaTable(creds_path) or {}
    local oauth = Settings.readLuaTable(oauth_path) or {}
    local available = {}
    for _, p in ipairs({ "gdrive", "onedrive", "dropbox" }) do
        if type(oauth[p]) == "table" and (oauth[p].refresh_token or oauth[p].access_token) then
            table.insert(available, p)
        end
    end
    if type(creds.webdav) == "table" and creds.webdav.url and creds.webdav.url ~= "" then
        table.insert(available, "webdav")
    end
    return available, creds, oauth
end

return Settings
