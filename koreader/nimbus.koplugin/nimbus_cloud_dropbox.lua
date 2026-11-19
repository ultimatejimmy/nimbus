--[[--
nimbus_cloud_dropbox.lua
Dropbox API v2 hierarchical CloudFS driver for nimbus.koplugin.
--]]

local ok_ltn, ltn12 = pcall(require, "ltn12")
local Constants = require("nimbus_constants")
local OAuth = require("nimbus_cloud_oauth")
local Http = require("nimbus_http")

local Dropbox = {}

local RPC_API = "https://api.dropboxapi.com/2"
local CONTENT_API = "https://content.dropboxapi.com/2"

local function normalizePath(path)
    if not path or path == "" or path == "/" then return "" end
    local p = tostring(path):gsub("\\", "/"):gsub("^/+", ""):gsub("/+$", ""):gsub("/+", "/")
    if p == "" then return "" end
    return "/" .. p
end

local function withToken(cb)
    OAuth.getValidAccessToken(Constants.CLOUD_PROVIDERS.DROPBOX, nil, cb)
end

function Dropbox.testConnection(creds, cb)
    withToken(function(ok, token_or_err)
        if not ok then return cb(false, token_or_err) end
        local _, code, _, _, body = Http.request({
            url = RPC_API .. "/users/get_current_account",
            method = "POST",
            headers = { ["Authorization"] = "Bearer " .. token_or_err },
        })
        if code == 200 then
            local data = Http.jsonDecode(body)
            local label = data and (data.email or (data.name and data.name.display_name)) or "Dropbox"
            return cb(true, label)
        end
        cb(false, "Dropbox connection failed (HTTP " .. tostring(code) .. ")")
    end)
end

function Dropbox.ensurePath(remote_dir, creds, cb)
    withToken(function(ok, token_or_err)
        if not ok then return cb(false, token_or_err) end
        local norm = normalizePath(remote_dir)
        if norm == "" then return cb(true, "") end
        local _, code, _, _, body = Http.request({
            url = RPC_API .. "/files/create_folder_v2",
            method = "POST",
            headers = {
                ["Authorization"] = "Bearer " .. token_or_err,
                ["Content-Type"] = "application/json",
            },
            body = Http.jsonEncode({ path = norm, autorename = false }),
        })
        -- 409 folder/conflict means it already exists
        if code == 200 or code == 409 then
            return cb(true, norm)
        end
        cb(false, "Dropbox create folder failed (HTTP " .. tostring(code) .. "): " .. tostring(body))
    end)
end

function Dropbox.uploadString(remote_path, content_str, content_type, creds, cb)
    withToken(function(ok, token_or_err)
        if not ok then return cb(false, token_or_err) end
        local norm = normalizePath(remote_path)
        local _, code, _, _, body = Http.request({
            url = CONTENT_API .. "/files/upload",
            method = "POST",
            headers = {
                ["Authorization"] = "Bearer " .. token_or_err,
                ["Content-Type"] = "application/octet-stream",
                ["Dropbox-API-Arg"] = Http.jsonEncode({
                    path = norm,
                    mode = "overwrite",
                    mute = true,
                }),
            },
            body = tostring(content_str or ""),
        })
        if code == 200 then return cb(true) end
        cb(false, "Dropbox upload failed (HTTP " .. tostring(code) .. "): " .. tostring(body))
    end)
end

function Dropbox.uploadFile(remote_path, local_path, creds, cb)
    withToken(function(ok, token_or_err)
        if not ok then return cb(false, token_or_err) end
        local norm = normalizePath(remote_path)
        local f = io.open(local_path, "rb")
        if not f then return cb(false, "Cannot open local file: " .. tostring(local_path)) end
        local size = f:seek("end") or 0
        f:seek("set", 0)

        local _, code, _, _, body = Http.request({
            url = CONTENT_API .. "/files/upload",
            method = "POST",
            headers = {
                ["Authorization"] = "Bearer " .. token_or_err,
                ["Content-Type"] = "application/octet-stream",
                ["Content-Length"] = tostring(size),
                ["Dropbox-API-Arg"] = Http.jsonEncode({
                    path = norm,
                    mode = "overwrite",
                    mute = true,
                }),
            },
            source = ltn12.source.file(f),
            total_timeout = 300,
        })
        if code == 200 then return cb(true) end
        cb(false, "Dropbox file upload failed (HTTP " .. tostring(code) .. "): " .. tostring(body))
    end)
end

function Dropbox.downloadString(remote_path, creds, cb)
    withToken(function(ok, token_or_err)
        if not ok then return cb(false, token_or_err) end
        local norm = normalizePath(remote_path)
        local _, code, _, _, body = Http.request({
            url = CONTENT_API .. "/files/download",
            method = "POST",
            headers = {
                ["Authorization"] = "Bearer " .. token_or_err,
                ["Dropbox-API-Arg"] = Http.jsonEncode({ path = norm }),
            },
        })
        if code == 200 then return cb(true, body) end
        if code == 409 then return cb(false, "not_found") end
        cb(false, "Dropbox download failed (HTTP " .. tostring(code) .. ")")
    end)
end

function Dropbox.downloadFile(remote_path, local_dest_path, creds, cb)
    withToken(function(ok, token_or_err)
        if not ok then return cb(false, token_or_err) end
        local norm = normalizePath(remote_path)
        local f = io.open(local_dest_path, "wb")
        if not f then return cb(false, "Cannot write local file: " .. tostring(local_dest_path)) end
        local _, code = Http.request({
            url = CONTENT_API .. "/files/download",
            method = "POST",
            headers = {
                ["Authorization"] = "Bearer " .. token_or_err,
                ["Dropbox-API-Arg"] = Http.jsonEncode({ path = norm }),
            },
            sink = ltn12.sink.file(f),
            total_timeout = 300,
        })
        if code == 200 then return cb(true) end
        os.remove(local_dest_path)
        cb(false, "Dropbox download failed (HTTP " .. tostring(code) .. ")")
    end)
end

function Dropbox.listDir(remote_dir, creds, cb)
    withToken(function(ok, token_or_err)
        if not ok then return cb(false, token_or_err) end
        local norm = normalizePath(remote_dir)
        local entries = {}
        local url = RPC_API .. "/files/list_folder"
        local payload = { path = norm, recursive = false }

        while true do
            local _, code, _, _, body = Http.request({
                url = url,
                method = "POST",
                headers = {
                    ["Authorization"] = "Bearer " .. token_or_err,
                    ["Content-Type"] = "application/json",
                },
                body = Http.jsonEncode(payload),
            })
            if code == 409 then return cb(true, {}) end
            if code ~= 200 then return cb(false, "Dropbox list failed (HTTP " .. tostring(code) .. ")") end
            local data = Http.jsonDecode(body) or {}
            for _, item in ipairs(data.entries or {}) do
                local rel = (item.path_display or item.path_lower or ""):gsub("^/+", "")
                table.insert(entries, {
                    name = item.name,
                    path = rel,
                    is_dir = (item[".tag"] == "folder"),
                    size = tonumber(item.size) or 0,
                    mtime = item.server_modified,
                    file_id = item.id,
                })
            end
            if not data.has_more or not data.cursor then break end
            url = RPC_API .. "/files/list_folder/continue"
            payload = { cursor = data.cursor }
        end
        cb(true, entries)
    end)
end

function Dropbox.deletePath(remote_path, creds, cb)
    withToken(function(ok, token_or_err)
        if not ok then return cb(false, token_or_err) end
        local norm = normalizePath(remote_path)
        local _, code = Http.request({
            url = RPC_API .. "/files/delete_v2",
            method = "POST",
            headers = {
                ["Authorization"] = "Bearer " .. token_or_err,
                ["Content-Type"] = "application/json",
            },
            body = Http.jsonEncode({ path = norm }),
        })
        if code == 200 or code == 409 then return cb(true) end
        cb(false, "Dropbox delete failed (HTTP " .. tostring(code) .. ")")
    end)
end

return Dropbox
