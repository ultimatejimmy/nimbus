--[[--
nimbus_cloud_gdrive.lua
Google Drive v3 hierarchical CloudFS driver for nimbus.koplugin.
--]]

local ok_ltn, ltn12 = pcall(require, "ltn12")
local _ = require("gettext")
local Constants = require("nimbus_constants")
local OAuth = require("nimbus_cloud_oauth")
local Http = require("nimbus_http")

local GDrive = {}

local DRIVE_API = "https://www.googleapis.com/drive/v3"
local DRIVE_UPLOAD = "https://www.googleapis.com/upload/drive/v3"

local _folder_cache = {} -- normalized_path -> file_id

function GDrive.clearFolderCache()
    _folder_cache = {}
end

local function normalizePath(path)
    if not path or path == "" or path == "/" then return "" end
    local p = tostring(path):gsub("\\", "/"):gsub("^/+", ""):gsub("/+$", ""):gsub("/+", "/")
    return p
end

local function splitPath(path)
    local p = normalizePath(path)
    if p == "" then return "", "" end
    local dir, name = p:match("^(.*)/([^/]+)$")
    if not dir then return "", p end
    return dir, name
end

local function escapeQuery(str)
    return tostring(str or ""):gsub("\\", "\\\\"):gsub("'", "\\'")
end

local function withToken(cb)
    OAuth.getValidAccessToken(Constants.CLOUD_PROVIDERS.GDRIVE, nil, cb)
end

local function findItemInParent(token, parent_id, name, is_dir)
    local mime_clause = ""
    if is_dir == true then
        mime_clause = " and mimeType = 'application/vnd.google-apps.folder'"
    elseif is_dir == false then
        mime_clause = " and mimeType != 'application/vnd.google-apps.folder'"
    end
    local q = string.format("name = '%s' and '%s' in parents and trashed = false%s",
        escapeQuery(name), escapeQuery(parent_id), mime_clause)
    local url = DRIVE_API .. "/files?q=" .. Http.urlEncode(q) .. "&fields=files(id,name,mimeType,size,modifiedTime)&pageSize=5"
    local _, code, _, _, body = Http.request({
        url = url,
        method = "GET",
        headers = { ["Authorization"] = "Bearer " .. token },
    })
    if code == 200 then
        local data = Http.jsonDecode(body)
        if data and data.files and data.files[1] then
            return data.files[1]
        end
    end
    return nil, code, body
end

local function ensureDirSync(token, remote_dir)
    local norm = normalizePath(remote_dir)
    if norm == "" then return "root" end
    if _folder_cache[norm] then return _folder_cache[norm] end

    local parent_id = "root"
    local acc = ""
    for part in norm:gmatch("[^/]+") do
        acc = (acc == "") and part or (acc .. "/" .. part)
        if _folder_cache[acc] then
            parent_id = _folder_cache[acc]
        else
            local existing = findItemInParent(token, parent_id, part, true)
            if existing and existing.id then
                parent_id = existing.id
                _folder_cache[acc] = parent_id
            else
                local meta_json = Http.jsonEncode({
                    name = part,
                    mimeType = "application/vnd.google-apps.folder",
                    parents = { parent_id },
                })
                local _, code, _, _, body = Http.request({
                    url = DRIVE_API .. "/files?fields=id",
                    method = "POST",
                    headers = {
                        ["Authorization"] = "Bearer " .. token,
                        ["Content-Type"] = "application/json; charset=UTF-8",
                    },
                    body = meta_json,
                })
                local created = Http.jsonDecode(body)
                if (code == 200 or code == 201) and created and created.id then
                    parent_id = created.id
                    _folder_cache[acc] = parent_id
                else
                    return nil, "Failed to create folder '" .. acc .. "' (HTTP " .. tostring(code) .. ")"
                end
            end
        end
    end
    return parent_id
end

local function resolveFileSync(token, remote_path)
    local dir, name = splitPath(remote_path)
    if name == "" then return nil, "Invalid remote path" end
    local parent_id = "root"
    if dir ~= "" then
        local acc = ""
        for part in dir:gmatch("[^/]+") do
            acc = (acc == "") and part or (acc .. "/" .. part)
            if _folder_cache[acc] then
                parent_id = _folder_cache[acc]
            else
                local folder = findItemInParent(token, parent_id, part, true)
                if not folder or not folder.id then
                    return nil, "not_found"
                end
                parent_id = folder.id
                _folder_cache[acc] = parent_id
            end
        end
    end
    local item = findItemInParent(token, parent_id, name, nil)
    if not item or not item.id then
        return nil, "not_found"
    end
    return item, nil, parent_id
end

function GDrive.testConnection(creds, cb)
    withToken(function(ok, token_or_err)
        if not ok then return cb(false, token_or_err) end
        local _, code, _, _, body = Http.request({
            url = DRIVE_API .. "/about?fields=user(displayName,emailAddress)",
            method = "GET",
            headers = { ["Authorization"] = "Bearer " .. token_or_err },
        })
        if code == 200 then
            local data = Http.jsonDecode(body)
            local email = data and data.user and (data.user.emailAddress or data.user.displayName) or "Google Drive"
            return cb(true, email)
        end
        cb(false, "Google Drive connection failed (HTTP " .. tostring(code) .. ")")
    end)
end

function GDrive.ensurePath(remote_dir, creds, cb)
    withToken(function(ok, token_or_err)
        if not ok then return cb(false, token_or_err) end
        local id, err = ensureDirSync(token_or_err, remote_dir)
        if id then cb(true, id) else cb(false, err) end
    end)
end

function GDrive.uploadString(remote_path, content_str, content_type, creds, cb)
    withToken(function(ok, token_or_err)
        if not ok then return cb(false, token_or_err) end
        local dir, name = splitPath(remote_path)
        local parent_id, err = ensureDirSync(token_or_err, dir)
        if not parent_id then return cb(false, err) end

        local existing = findItemInParent(token_or_err, parent_id, name, false)
        local payload = tostring(content_str or "")
        local ctype = content_type or "application/octet-stream"

        if existing and existing.id then
            local _, code, _, _, body = Http.request({
                url = DRIVE_UPLOAD .. "/files/" .. existing.id .. "?uploadType=media",
                method = "PATCH",
                headers = {
                    ["Authorization"] = "Bearer " .. token_or_err,
                    ["Content-Type"] = ctype,
                },
                body = payload,
            })
            if code == 200 or code == 201 then return cb(true) end
            return cb(false, "Upload failed (HTTP " .. tostring(code) .. "): " .. tostring(body))
        else
            local boundary = "nimbus_boundary_" .. tostring(os.time())
            local meta_json = Http.jsonEncode({ name = name, parents = { parent_id } })
            local multipart = "--" .. boundary .. "\r\n"
                .. "Content-Type: application/json; charset=UTF-8\r\n\r\n"
                .. meta_json .. "\r\n"
                .. "--" .. boundary .. "\r\n"
                .. "Content-Type: " .. ctype .. "\r\n\r\n"
                .. payload .. "\r\n"
                .. "--" .. boundary .. "--"
            local _, code, _, _, body = Http.request({
                url = DRIVE_UPLOAD .. "/files?uploadType=multipart",
                method = "POST",
                headers = {
                    ["Authorization"] = "Bearer " .. token_or_err,
                    ["Content-Type"] = "multipart/related; boundary=" .. boundary,
                },
                body = multipart,
            })
            if code == 200 or code == 201 then return cb(true) end
            return cb(false, "Upload failed (HTTP " .. tostring(code) .. "): " .. tostring(body))
        end
    end)
end

function GDrive.uploadFile(remote_path, local_path, creds, cb, opts)
    withToken(function(ok, token_or_err)
        if not ok then return cb(false, token_or_err) end
        local dir, name = splitPath(remote_path)
        local parent_id, err = ensureDirSync(token_or_err, dir)
        if not parent_id then return cb(false, err) end

        local f = io.open(local_path, "rb")
        if not f then return cb(false, "Cannot open local file: " .. tostring(local_path)) end
        local size = f:seek("end") or 0
        f:seek("set", 0)

        local existing = findItemInParent(token_or_err, parent_id, name, false)
        local init_url, init_method, meta_tbl
        if existing and existing.id then
            init_url = DRIVE_UPLOAD .. "/files/" .. existing.id .. "?uploadType=resumable"
            init_method = "PATCH"
            meta_tbl = { name = name }
        else
            init_url = DRIVE_UPLOAD .. "/files?uploadType=resumable"
            init_method = "POST"
            meta_tbl = { name = name, parents = { parent_id } }
        end

        local _, code, resp_headers, _, body = Http.request({
            url = init_url,
            method = init_method,
            headers = {
                ["Authorization"] = "Bearer " .. token_or_err,
                ["Content-Type"] = "application/json; charset=UTF-8",
                ["X-Upload-Content-Length"] = tostring(size),
            },
            body = Http.jsonEncode(meta_tbl),
        })

        local upload_url = resp_headers and (resp_headers["location"] or resp_headers["Location"])
        if (code ~= 200 and code ~= 201) or not upload_url then
            f:close()
            return cb(false, "Failed to initiate resumable upload (HTTP " .. tostring(code) .. "): " .. tostring(body))
        end

        opts = opts or {}
        local source = Http.makeFileProgressSource(f, size, opts.on_progress, opts.is_canceled)
        local _, up_code, _, _, up_body = Http.request({
            url = upload_url,
            method = "PUT",
            headers = {
                ["Content-Length"] = tostring(size),
                ["Content-Type"] = "application/octet-stream",
            },
            source = source,
            total_timeout = 300,
        })
        pcall(function() f:close() end)
        if opts.is_canceled and opts.is_canceled() then
            return cb(false, "canceled")
        end
        if up_code == 200 or up_code == 201 then
            return cb(true)
        end
        cb(false, "File upload failed (HTTP " .. tostring(up_code) .. "): " .. tostring(up_body))
    end)
end

function GDrive.downloadString(remote_path, creds, cb)
    withToken(function(ok, token_or_err)
        if not ok then return cb(false, token_or_err) end
        local item, err = resolveFileSync(token_or_err, remote_path)
        if not item then return cb(false, err) end
        local _, code, _, _, body = Http.request({
            url = DRIVE_API .. "/files/" .. item.id .. "?alt=media",
            method = "GET",
            headers = { ["Authorization"] = "Bearer " .. token_or_err },
        })
        if code == 200 then
            return cb(true, body, { modifiedTime = item.modifiedTime, size = tonumber(item.size) })
        end
        cb(false, "Download failed (HTTP " .. tostring(code) .. ")")
    end)
end

function GDrive.downloadFile(remote_path, local_dest_path, creds, cb, opts)
    opts = opts or {}
    withToken(function(ok, token_or_err)
        if not ok then return cb(false, token_or_err) end
        local item, err = resolveFileSync(token_or_err, remote_path)
        if not item then return cb(false, err) end
        local f = io.open(local_dest_path, "wb")
        if not f then return cb(false, "Cannot write local file: " .. tostring(local_dest_path)) end
        local total_size = tonumber(item.size) or opts.expected_size or 0
        local _, code = Http.request({
            url = DRIVE_API .. "/files/" .. item.id .. "?alt=media",
            method = "GET",
            headers = { ["Authorization"] = "Bearer " .. token_or_err },
            sink = Http.makeFileProgressSink(f, total_size, opts.on_progress, opts.is_canceled),
            total_timeout = 300,
        })
        pcall(function() f:close() end)
        if opts.is_canceled and opts.is_canceled() then
            os.remove(local_dest_path)
            return cb(false, "canceled")
        end
        if code == 200 then return cb(true) end
        os.remove(local_dest_path)
        cb(false, "Download failed (HTTP " .. tostring(code) .. ")")
    end)
end

function GDrive.listDir(remote_dir, creds, cb)
    withToken(function(ok, token_or_err)
        if not ok then return cb(false, token_or_err) end
        local norm = normalizePath(remote_dir)
        local parent_id = "root"
        if norm ~= "" then
            parent_id = _folder_cache[norm]
            if not parent_id then
                local cur = "root"
                local acc = ""
                for part in norm:gmatch("[^/]+") do
                    acc = (acc == "") and part or (acc .. "/" .. part)
                    if _folder_cache[acc] then
                        cur = _folder_cache[acc]
                    else
                        local f = findItemInParent(token_or_err, cur, part, true)
                        if not f or not f.id then
                            return cb(true, {}) -- Non-existent directory returns empty list cleanly
                        end
                        cur = f.id
                        _folder_cache[acc] = cur
                    end
                end
                parent_id = cur
            end
        end

        local entries = {}
        local page_token = nil
        repeat
            local q = string.format("'%s' in parents and trashed = false", escapeQuery(parent_id))
            local url = DRIVE_API .. "/files?q=" .. Http.urlEncode(q)
                .. "&fields=nextPageToken,files(id,name,mimeType,size,modifiedTime)&pageSize=200"
            if page_token then
                url = url .. "&pageToken=" .. Http.urlEncode(page_token)
            end
            local _, code, _, _, body = Http.request({
                url = url,
                method = "GET",
                headers = { ["Authorization"] = "Bearer " .. token_or_err },
            })
            if code ~= 200 then
                return cb(false, "List failed (HTTP " .. tostring(code) .. ")")
            end
            local data = Http.jsonDecode(body) or {}
            for _, f in ipairs(data.files or {}) do
                local is_dir = (f.mimeType == "application/vnd.google-apps.folder")
                local full_path = (norm == "") and f.name or (norm .. "/" .. f.name)
                table.insert(entries, {
                    name = f.name,
                    path = full_path,
                    is_dir = is_dir,
                    size = tonumber(f.size) or 0,
                    mtime = f.modifiedTime,
                    file_id = f.id,
                })
            end
            page_token = data.nextPageToken
        until not page_token

        cb(true, entries)
    end)
end

function GDrive.deletePath(remote_path, creds, cb)
    withToken(function(ok, token_or_err)
        if not ok then return cb(false, token_or_err) end
        local item, err = resolveFileSync(token_or_err, remote_path)
        if not item then
            if err == "not_found" then return cb(true) end
            return cb(false, err)
        end
        local _, code = Http.request({
            url = DRIVE_API .. "/files/" .. item.id,
            method = "DELETE",
            headers = { ["Authorization"] = "Bearer " .. token_or_err },
        })
        if code == 200 or code == 204 or code == 404 then
            _folder_cache = {}
            return cb(true)
        end
        cb(false, "Delete failed (HTTP " .. tostring(code) .. ")")
    end)
end

return GDrive
