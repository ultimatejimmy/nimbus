--[[--
nimbus_logger.lua
Dedicated file logger for nimbus.koplugin troubleshooting.
Modeled after storefront_logger.lua and xray_logger.lua with a compact 64 KB cap
before rotating nimbus.log to nimbus.log.old, subprocess-safe direct appends,
and WARN/ERROR mirroring to KOReader's built-in logger.
--]]

local ok_ds, DataStorage = pcall(require, "datastorage")
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs or not lfs then
    ok_lfs, lfs = pcall(require, "lfs")
end
local ok_klog, klogger = pcall(require, "logger")

local Logger = {
    max_size = 64 * 1024, -- 64 KB per file (~128 KB max total with .old)
    debug_enabled = false,
    dedup_window_sec = 10,
}

local plugin_dir_override = nil
local last_log_msg = nil
local last_log_time = 0

local function getFileSize(path)
    if ok_lfs and lfs and lfs.attributes then
        local size = lfs.attributes(path, "size")
        if type(size) == "number" then
            return size
        end
    end
    local f = io.open(path, "r")
    if f then
        local size = f:seek("end")
        f:close()
        return size
    end
    return nil
end

local function getLogFilePath()
    if plugin_dir_override and plugin_dir_override ~= "" then
        local clean = plugin_dir_override:gsub("[/\\]+$", "")
        return clean .. "/nimbus.log"
    end
    local data_dir = (ok_ds and DataStorage and DataStorage.getDataDir and DataStorage:getDataDir()) or "."
    local dir = data_dir .. "/plugins/nimbus.koplugin"
    local attr = (ok_lfs and lfs and lfs.attributes) and lfs.attributes(dir, "mode") or nil
    if attr ~= "directory" then
        dir = (ok_ds and DataStorage and DataStorage.getSettingsDir and DataStorage:getSettingsDir()) or data_dir
    end
    return dir .. "/nimbus.log"
end

local function rotateIfNeeded(path)
    local current_size = getFileSize(path)
    if current_size and current_size >= Logger.max_size then
        os.remove(path .. ".old")
        os.rename(path, path .. ".old")
    end
end

local function mirrorToKOReader(level, msg_str)
    if not ok_klog or not klogger then return end
    if level == "WARN" and klogger.warn then
        pcall(klogger.warn, "Nimbus: " .. msg_str)
    elseif level == "ERROR" then
        local fn = klogger.err or klogger.error or klogger.warn
        if fn then
            pcall(fn, "Nimbus: " .. msg_str)
        end
    end
end

local function writeLog(level, msg)
    pcall(function()
        local msg_str = tostring(msg)
        local now = os.time()
        if level == "INFO" and msg_str == last_log_msg and (now - last_log_time) < Logger.dedup_window_sec then
            return
        end
        if level == "INFO" then
            last_log_msg = msg_str
            last_log_time = now
        end

        local path = getLogFilePath()
        rotateIfNeeded(path)

        local f = io.open(path, "a")
        if f then
            f:write(os.date("%Y-%m-%d %H:%M:%S") .. " [" .. level .. "] " .. msg_str .. "\n")
            f:close()
        end

        mirrorToKOReader(level, msg_str)
    end)
end

function Logger.init(plugin_dir)
    if type(plugin_dir) == "string" and plugin_dir ~= "" then
        plugin_dir_override = plugin_dir:gsub("[/\\]+$", "")
    else
        plugin_dir_override = nil
    end
end

function Logger.getPath()
    return getLogFilePath()
end

function Logger.getOldPath()
    return getLogFilePath() .. ".old"
end

function Logger.sanitizeUrl(url)
    if type(url) ~= "string" then return tostring(url or "") end
    local sanitized = url:gsub("([%?%&])([%w_%-]*[Tt][Oo][Kk][Ee][Nn])=[^%&]*", "%1%2=REDACTED")
    sanitized = sanitized:gsub("([%?%&])([%w_%-]*[Kk][Ee][Yy])=[^%&]*", "%1%2=REDACTED")
    sanitized = sanitized:gsub("([%?%&])([Cc][Oo][Dd][Ee])=[^%&]*", "%1%2=REDACTED")
    sanitized = sanitized:gsub("([%?%&])([Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd])=[^%&]*", "%1%2=REDACTED")
    return sanitized
end

function Logger.log(msg)
    writeLog("INFO", msg)
end

function Logger.info(msg)
    writeLog("INFO", msg)
end

function Logger.action(msg)
    writeLog("ACTION", msg)
end

function Logger.warn(msg)
    writeLog("WARN", msg)
end

function Logger.err(msg)
    writeLog("ERROR", msg)
end

function Logger.debug(msg)
    if Logger.debug_enabled then
        writeLog("DEBUG", msg)
    end
end

function Logger.startSession(version)
    pcall(function()
        local path = getLogFilePath()
        rotateIfNeeded(path)
        local ver_suffix = (version and tostring(version) ~= "") and (" (v" .. tostring(version) .. ")") or ""
        local f = io.open(path, "a")
        if f then
            f:write("\n" .. string.rep("=", 40) .. "\n")
            f:write("--- Nimbus Session Started: " .. os.date("%Y-%m-%d %H:%M:%S") .. ver_suffix .. " ---\n")
            f:close()
        end
    end)
end

function Logger.reset(version)
    Logger.startSession(version)
end

function Logger.clear()
    last_log_msg = nil
    last_log_time = 0
    pcall(function()
        local path = getLogFilePath()
        os.remove(path)
        os.remove(path .. ".old")
    end)
end

return Logger
