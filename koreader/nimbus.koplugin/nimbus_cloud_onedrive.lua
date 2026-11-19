--[[--
nimbus_cloud_onedrive.lua
Microsoft Graph OneDrive hierarchical CloudFS driver for nimbus.koplugin.
--]]

local ok_ltn, ltn12 = pcall(require, "ltn12")
local Constants = require("nimbus_constants")
local OAuth = require("nimbus_cloud_oauth")
local Http = require("nimbus_http")

local OneDrive = {}

local GRAPH_API = "https://graph.microsoft.com/v1.0/me/drive"

local function normalizePath(path)
    if not path or path == "" or path == "/" then return "" end
    return tostring(path):gsub("\\", "/"):gsub("^/+", ""):gsub("/+$", ""):gsub("/+", "/")
end

local function splitPath(path)
    local p = normalizePath(path)
    if p == "" then return "", "" end
    local dir, name = p:match("^(.*)/([^/]+)$")
    if not dir then return "", p end
    return dir, name
end

local function withToken(cb)
    OAuth.getValidAccessToken(Constants.CLOUD_PROVIDERS.ONEDRIVE, nil, cb)
end

local function ensureDirSync(token, remote_dir)
    local norm = normalizePath(remote_dir)
    if norm == "" then return true end
    local acc = ""
    for part in norm:gmatch("[^/]+") do
        local parent_url = (acc == "")
            and (GRAPH_API .. "/root/children")
            or (GRAPH_API .. "/root:/" .. Http.urlEncodePath(acc) .. ":/children")
        acc = (acc == "") and part or (acc .. "/" .. part)
        local check_url = GRAPH_API .. "/root:/" .. Http.urlEncodePath(acc)
        local _, check_code = Http.request({
            url = check_url,
            method = "GET",
            headers = { ["Authorization"] = "Bearer " .. token },
        })
        if check_code ~= 200 then
            local _, mk_code, _, _, mk_body = Http.request({
                url = parent_url,
                method = "POST",
                headers = {
                    ["Authorization"] = "Bearer " .. token,
                    ["Content-Type"] = "application/json",
                },
                body = Http.jsonEncode({
                    name = part,
                    folder = {},
                    ["@microsoft.graph.conflictBehavior"] = "replace",
                }),
            })
            if mk_code ~= 200 and mk_code ~= 201 and mk_code ~= 409 then
                return false, "Failed to create OneDrive folder '" .. acc .. "' (HTTP " .. tostring(mk_code) .. "): " .. tostring(mk_body)
            end
        end
    end
    return true
end

function OneDrive.testConnection(creds, cb)
    withToken(function(ok, token_or_err)
        if not ok then return cb(false, token_or_err) end
        local _, code, _, _, body = Http.request({
            url = GRAPH_API,
            method = "GET",
            headers = { ["Authorization"] = "Bearer " .. token_or_err },
        })
        if code == 200 then
            local data = Http.jsonDecode(body)
            local owner = data and data.owner and data.owner.user and data.owner.user.displayName or "OneDrive"
            return cb(true, owner)
        end
        cb(false, "OneDrive connection failed (HTTP " .. tostring(code) .. ")")
    end)
end

function OneDrive.ensurePath(remote_dir, creds, cb)
    withToken(function(ok, token_or_err)
        if not ok then return cb(false, token_or_err) end
        local ok_dir, err = ensureDirSync(token_or_err, remote_dir)
        if ok_dir then cb(true, normalizePath(remote_dir)) else cb(false, err) end
    end)
end

function OneDrive.uploadString(remote_path, content_str, content_type, creds, cb)
    withToken(function(ok, token_or_err)
        if not ok then return cb(false, token_or_err) end
        local norm = normalizePath(remote_path)
        local dir = splitPath(norm)
        local ok_dir, err = ensureDirSync(token_or_err, dir)
        if not ok_dir then return cb(false, err) end

        local url = GRAPH_API .. "/root:/" .. Http.urlEncodePath(norm) .. ":/content"
        local _, code, _, _, body = Http.request({
            url = url,
            method = "PUT",
            headers = {
                ["Authorization"] = "Bearer " .. token_or_err,
                ["Content-Type"] = content_type or "application/octet-stream",
            },
            body = tostring(content_str or ""),
        })
        if code == 200 or code == 201 then return cb(true) end
        cb(false, "OneDrive upload failed (HTTP " .. tostring(code) .. "): " .. tostring(body))
    end)
end

function OneDrive.uploadFile(remote_path, local_path, creds, cb, opts)
    opts = opts or {}
    withToken(function(ok, token_or_err)
        if not ok then return cb(false, token_or_err) end
        local norm = normalizePath(remote_path)
        local dir = splitPath(norm)
        local ok_dir, err = ensureDirSync(token_or_err, dir)
        if not ok_dir then return cb(false, err) end

        local f = io.open(local_path, "rb")
        if not f then return cb(false, "Cannot open local file: " .. tostring(local_path)) end
        local size = f:seek("end") or 0
        f:seek("set", 0)

        -- For files <= 4MB use simple PUT; larger files use upload session
        if size <= 4 * 1024 * 1024 then
            local _, code, _, _, body = Http.request({
                url = GRAPH_API .. "/root:/" .. Http.urlEncodePath(norm) .. ":/content",
                method = "PUT",
                headers = {
                    ["Authorization"] = "Bearer " .. token_or_err,
                    ["Content-Type"] = "application/octet-stream",
                    ["Content-Length"] = tostring(size),
                },
                source = Http.makeFileProgressSource(f, size, opts.on_progress, opts.is_canceled),
                total_timeout = 300,
            })
            pcall(function() f:close() end)
            if opts.is_canceled and opts.is_canceled() then return cb(false, "canceled") end
            if code == 200 or code == 201 then return cb(true) end
            return cb(false, "OneDrive upload failed (HTTP " .. tostring(code) .. "): " .. tostring(body))
        end

        local _, s_code, _, _, s_body = Http.request({
            url = GRAPH_API .. "/root:/" .. Http.urlEncodePath(norm) .. ":/createUploadSession",
            method = "POST",
            headers = {
                ["Authorization"] = "Bearer " .. token_or_err,
                ["Content-Type"] = "application/json",
            },
            body = Http.jsonEncode({ item = { ["@microsoft.graph.conflictBehavior"] = "replace" } }),
        })
        local s_data = Http.jsonDecode(s_body)
        if (s_code ~= 200 and s_code ~= 201) or not s_data or not s_data.uploadUrl then
            f:close()
            return cb(false, "OneDrive upload session failed (HTTP " .. tostring(s_code) .. ")")
        end

        local chunk_size = 5 * 1024 * 1024
        local offset = 0
        while offset < size do
            local chunk = f:read(chunk_size)
            if not chunk or #chunk == 0 then break end
            local end_byte = offset + #chunk - 1
            local _, c_code, _, _, c_body = Http.request({
                url = s_data.uploadUrl,
                method = "PUT",
                headers = {
                    ["Content-Length"] = tostring(#chunk),
                    ["Content-Range"] = string.format("bytes %d-%d/%d", offset, end_byte, size),
                },
                body = chunk,
                total_timeout = 300,
            })
            if c_code ~= 200 and c_code ~= 201 and c_code ~= 202 then
                f:close()
                return cb(false, "OneDrive chunk upload failed (HTTP " .. tostring(c_code) .. "): " .. tostring(c_body))
            end
            offset = offset + #chunk
        end
        f:close()
        cb(true)
    end)
end

function OneDrive.downloadString(remote_path, creds, cb)
    withToken(function(ok, token_or_err)
        if not ok then return cb(false, token_or_err) end
        local norm = normalizePath(remote_path)
        local _, code, _, _, body = Http.request({
            url = GRAPH_API .. "/root:/" .. Http.urlEncodePath(norm) .. ":/content",
            method = "GET",
            headers = { ["Authorization"] = "Bearer " .. token_or_err },
        })
        if code == 200 then return cb(true, body) end
        if code == 404 then return cb(false, "not_found") end
        cb(false, "OneDrive download failed (HTTP " .. tostring(code) .. ")")
    end)
end

function OneDrive.downloadFile(remote_path, local_dest_path, creds, cb, opts)
    opts = opts or {}
    withToken(function(ok, token_or_err)
        if not ok then return cb(false, token_or_err) end
        local norm = normalizePath(remote_path)
        local f = io.open(local_dest_path, "wb")
        if not f then return cb(false, "Cannot write local file: " .. tostring(local_dest_path)) end
        local _, code = Http.request({
            url = GRAPH_API .. "/root:/" .. Http.urlEncodePath(norm) .. ":/content",
            method = "GET",
            headers = { ["Authorization"] = "Bearer " .. token_or_err },
            sink = Http.makeFileProgressSink(f, opts.expected_size or 0, opts.on_progress, opts.is_canceled),
            total_timeout = 300,
        })
        pcall(function() f:close() end)
        if opts.is_canceled and opts.is_canceled() then
            os.remove(local_dest_path)
            return cb(false, "canceled")
        end
        if code == 200 then return cb(true) end
        os.remove(local_dest_path)
        cb(false, "OneDrive download failed (HTTP " .. tostring(code) .. ")")
    end)
end

function OneDrive.listDir(remote_dir, creds, cb)
    withToken(function(ok, token_or_err)
        if not ok then return cb(false, token_or_err) end
        local norm = normalizePath(remote_dir)
        local url = (norm == "")
            and (GRAPH_API .. "/root/children")
            or (GRAPH_API .. "/root:/" .. Http.urlEncodePath(norm) .. ":/children")
        local entries = {}
        while url do
            local _, code, _, _, body = Http.request({
                url = url,
                method = "GET",
                headers = { ["Authorization"] = "Bearer " .. token_or_err },
            })
            if code == 404 then return cb(true, {}) end
            if code ~= 200 then return cb(false, "OneDrive list failed (HTTP " .. tostring(code) .. ")") end
            local data = Http.jsonDecode(body) or {}
            for _, item in ipairs(data.value or {}) do
                local full_path = (norm == "") and item.name or (norm .. "/" .. item.name)
                table.insert(entries, {
                    name = item.name,
                    path = full_path,
                    is_dir = item.folder ~= nil,
                    size = tonumber(item.size) or 0,
                    mtime = item.lastModifiedDateTime,
                    file_id = item.id,
                })
            end
            url = data["@odata.nextLink"]
        end
        cb(true, entries)
    end)
end

function OneDrive.deletePath(remote_path, creds, cb)
    withToken(function(ok, token_or_err)
        if not ok then return cb(false, token_or_err) end
        local norm = normalizePath(remote_path)
        local _, code = Http.request({
            url = GRAPH_API .. "/root:/" .. Http.urlEncodePath(norm),
            method = "DELETE",
            headers = { ["Authorization"] = "Bearer " .. token_or_err },
        })
        if code == 200 or code == 204 or code == 404 then return cb(true) end
        cb(false, "OneDrive delete failed (HTTP " .. tostring(code) .. ")")
    end)
end

return OneDrive
